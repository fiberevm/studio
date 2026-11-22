import SwiftUI
import Darwin

/// A shell an agent started that is still running: a dev server, a watcher, a long build.
struct BackgroundTask: Identifiable, Equatable {
    /// The shell the agent spawned for the command (the leader of its process group).
    let pid: Int32
    /// What the agent ran.
    let command: String
    let started: Date
    /// TCP ports the command (or anything it started) is listening on.
    let ports: [Int]
    /// Process groups to signal to stop it: its own and those of whatever it started.
    let groups: [Int32]
    var id: Int32 { pid }
    var isServer: Bool { !ports.isEmpty }

    /// One line for the status bar: the command without its setup (`cd … &&`), cut short.
    var label: String {
        var c = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        while let r = c.range(of: "&& "), c.hasPrefix("cd ") || c.hasPrefix("export ") || c.hasPrefix("source ") {
            c = String(c[r.upperBound...])
        }
        c = c.trimmingCharacters(in: .whitespaces)
        return c.count > 26 ? c.prefix(25) + "…" : c
    }

    /// Stop it: SIGTERM to every process group it owns, SIGKILL a few seconds later to whatever is left.
    func stop() {
        let groups = groups
        groups.forEach { _ = killpg($0, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { groups.forEach { _ = killpg($0, SIGKILL) } }
    }
}

/// Finds the shells each session's agent has running, from the process table.
/// An agent (Claude Code, Codex, agy) runs every command in a process group of its own, while its helpers
/// (MCP servers, language servers) stay in the agent's group. So a session's tasks are the agent's children
/// that lead another group. Commands that finish within a few seconds are never shown.
final class BackgroundTaskScanner {
    private struct Proc { let pid, ppid, pgid: Int32; let start: Date }
    /// Commands already read, by pid and start time (a pid can be reused).
    private var commands: [Int32: (start: Date, command: String)] = [:]
    private static let minAge: TimeInterval = 4

    /// `roots`: tab → the pid of its agent. Call from one queue at a time.
    func scan(_ roots: [UUID: Int32]) -> [UUID: [BackgroundTask]] {
        guard !roots.isEmpty else { commands = [:]; return [:] }
        let procs = Self.processes()
        var children: [Int32: [Proc]] = [:], byGroup: [Int32: [Proc]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p); byGroup[p.pgid, default: []].append(p) }
        var result: [UUID: [BackgroundTask]] = [:]
        var seen: Set<Int32> = []
        let now = Date()
        for (tab, rootPid) in roots {
            guard let root = procs[rootPid] else { continue }
            var tasks: [BackgroundTask] = []
            for c in children[rootPid] ?? [] where c.pgid == c.pid && c.pgid != root.pgid && now.timeIntervalSince(c.start) >= Self.minAge {
                // everything it started: its descendants, plus the rest of their groups (a daemonized child
                // is re-parented to launchd but stays in its group)
                var members: [Int32: Proc] = [c.pid: c], stack = [c.pid]
                while let p = stack.popLast() {
                    for k in children[p] ?? [] where members[k.pid] == nil { members[k.pid] = k; stack.append(k.pid) }
                }
                let groups = Set(members.values.map(\.pgid)).subtracting([root.pgid, 0, 1])
                for g in groups { for p in byGroup[g] ?? [] { members[p.pid] = p } }
                let ports = Set(members.keys.flatMap(Self.listeningPorts)).sorted()
                let command: String
                if let known = commands[c.pid], known.start == c.start { command = known.command }
                else { command = Self.command(of: c.pid); commands[c.pid] = (c.start, command) }
                seen.insert(c.pid)
                tasks.append(BackgroundTask(pid: c.pid, command: command, started: c.start, ports: ports, groups: groups.sorted()))
            }
            if !tasks.isEmpty { result[tab] = tasks.sorted { $0.started < $1.started } }
        }
        commands = commands.filter { seen.contains($0.key) }
        return result
    }

    private static func processes() -> [Int32: Proc] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var out: [Int32: Proc] = [:]
        out.reserveCapacity(max(n, 0))
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }   // other users' processes
            out[pid] = Proc(pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid),
                            start: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6))
        }
        return out
    }

    /// TCP ports `pid` has sockets listening on.
    private static func listeningPorts(_ pid: Int32) -> [Int] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var ports: [Int] = []
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var s = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &s, size) == size,
                  s.psi.soi_kind == Int32(SOCKINFO_TCP),
                  s.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: s.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.append(port) }
        }
        return ports
    }

    /// The command the agent ran in the shell `pid`. Claude Code wraps it (`bash -c "source snapshot … && eval
    /// '<command>' < /dev/null && pwd …"`); other agents pass it to `sh -c` as is.
    private static func command(of pid: Int32) -> String {
        let args = arguments(of: pid)
        guard !args.isEmpty else { return "pid \(pid)" }
        let isShell = ["sh", "bash", "zsh", "fish", "dash"].contains((args[0] as NSString).lastPathComponent.trimmingCharacters(in: ["-"]))
        guard isShell, let i = args.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              i + 1 < args.count, let script = args[(i + 1)...].first(where: { !$0.hasPrefix("-") }) else {
            return args.joined(separator: " ")
        }
        guard let open = script.range(of: "&& eval '") ?? (script.hasPrefix("eval '") ? script.range(of: "eval '") : nil) else { return script }
        // the single-quoted word after eval; a quote inside it is written '"'"'
        var out = "", rest = script[open.upperBound...]
        while let q = rest.firstIndex(of: "'") {
            out += rest[..<q]
            let after = rest[q...]
            if after.hasPrefix("'\"'\"'") { out += "'"; rest = after.dropFirst(5) } else { return out }
        }
        return out.isEmpty ? script : out
    }

    private static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }      // the executable's path
        while i < size, buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while i < size, args.count < argc {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}

/// The shells and servers this session's agent has running: one chip each (a server shows its port).
/// Click for the full command, opening the port, or stopping it.
struct BackgroundTaskChips: View {
    let tasks: [BackgroundTask]
    @ObservedObject var terminal: TerminalSession
    @EnvironmentObject var model: ProjectModel
    private static let shown = 3

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tasks.prefix(tasks.count > Self.shown ? Self.shown - 1 : Self.shown)) { t in
                Menu { items(t) } label: { chip(t) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(help(t))
            }
            if tasks.count > Self.shown {
                let rest = Array(tasks.dropFirst(Self.shown - 1))
                Menu {
                    ForEach(rest) { t in
                        Menu((t.ports.first.map { ":\($0)  " } ?? "") + t.label) { items(t) }
                    }
                } label: {
                    Text("+\(rest.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("\(rest.count) more running:\n" + rest.map(\.label).joined(separator: "\n"))
            }
        }
    }

    private func chip(_ t: BackgroundTask) -> some View {
        HStack(spacing: 4) {
            Image(systemName: t.isServer ? "dot.radiowaves.left.and.right" : "terminal").font(.system(size: 10))
            if let p = t.ports.first {
                Text(":\(p)" + (t.ports.count > 1 ? "+" : "")).font(.system(size: 11)).monospacedDigit()
            }
            Text(t.label).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func items(_ t: BackgroundTask) -> some View {
        Text(t.command.count > 90 ? t.command.prefix(89).replacingOccurrences(of: "\n", with: " ") + "…" : t.command.replacingOccurrences(of: "\n", with: " "))
        Text("\(age(t)) · pid \(t.pid)")
        Divider()
        ForEach(t.ports, id: \.self) { p in
            Button("Open localhost:\(p)") {
                model.openWeb(URL(string: "http://localhost:\(p)"), beside: model.group(containing: terminal.id), zone: .right)
            }
            Button("Open localhost:\(p) in Browser") { NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!) }
        }
        Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.command, forType: .string) }
        Divider()
        Button("Stop") { t.stop(); model.store.refreshTasks(after: 0.5) }
    }

    private func age(_ t: BackgroundTask) -> String {
        let a = relativeTime(t.started)
        return a == "now" ? "Started just now" : "Running for \(a)"
    }

    private func help(_ t: BackgroundTask) -> String {
        var lines = [t.command, age(t)]
        if !t.ports.isEmpty { lines.append("Listening on " + t.ports.map { ":\($0)" }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
