import Foundation
import Combine

/// A remote sandbox as Studio shows it.
struct SandboxInfo: Hashable {
    let id: String
    var name: String?
    var state: String            // running, stopped, pending, stopping, error…
    var type: String?
    var provider: String
    var label: String { name?.isEmpty == false ? name! : id }
}

/// Something that can create and drive sandboxes. Boat (boat.dev) is the first; the protocol keeps the
/// MCP tools and the UI provider-agnostic.
protocol SandboxProvider: Sendable {
    var id: String { get }                         // "boat"
    /// The CLI is installed (sign-in is checked lazily by the first call that fails).
    var installed: Bool { get }
    func list() async throws -> [SandboxInfo]
    func create(type: String?, ttlMinutes: Int?, environment: String?) async throws -> SandboxInfo
    func exec(_ id: String, command: String, cwd: String?, timeout: Int, background: Bool) async throws -> Any
    func push(_ id: String, dir: String, to: String?) async throws -> Any
    func url(_ id: String, port: Int, isPublic: Bool) async throws -> Any
    func stop(_ id: String) async throws -> Any
    func resume(_ id: String) async throws -> Any
    func delete(_ id: String) async throws -> Any
    /// Shell command that opens an interactive session in the sandbox (run in a Studio terminal tab).
    func sshCommand(_ id: String) -> String
    func openDesktop(_ id: String) async throws -> Any
    /// Account status for Settings: {"account": {...}, "creditHours": Double}.
    func status() async -> [String: Any]?
}

struct SandboxError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// boat.dev, through its CLI (`boat … --json`).
struct BoatProvider: SandboxProvider {
    let id = "boat"
    let binary: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.ascii/bin/boat", "/opt/homebrew/bin/boat", "/usr/local/bin/boat", "\(home)/.local/bin/boat"]
        binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? Self.which("boat")
    }

    var installed: Bool { binary != nil }

    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Run `boat <args> --json --no-update`; returns parsed JSON (or text), throws with Boat's error message.
    private func run(_ args: [String], timeout: TimeInterval = 180) async throws -> Any {
        guard let binary else { throw SandboxError(message: "The boat CLI isn't installed (https://boat.dev).") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = args + ["--json", "--no-update"]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let text = String(data: o, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let json = try? JSONSerialization.jsonObject(with: o)
                if p.terminationStatus != 0 && args.first != "exec" {
                    let msg = (json as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
                        ?? String(data: e, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: SandboxError(message: (msg?.isEmpty == false ? msg! : text.isEmpty ? "boat \(args.first ?? "") failed" : text)))
                    return
                }
                cont.resume(returning: json ?? text)
            }
        }
    }

    private static func info(_ o: [String: Any]) -> SandboxInfo? {
        guard let id = o["id"] as? String else { return nil }
        return SandboxInfo(id: id, name: o["name"] as? String, state: o["state"] as? String ?? "unknown",
                           type: o["type"] as? String, provider: "boat")
    }

    func list() async throws -> [SandboxInfo] {
        let r = try await run(["list", "--all"], timeout: 30)
        let arr = (r as? [String: Any])?["sandboxes"] as? [[String: Any]] ?? (r as? [[String: Any]] ?? [])
        return arr.compactMap(Self.info)
    }

    func create(type: String?, ttlMinutes: Int?, environment: String?) async throws -> SandboxInfo {
        var args = ["new"]
        if let type { args += ["--type", type] }
        if let ttlMinutes { args += ["--ttl", String(ttlMinutes * 60)] }
        if let environment { args += ["--environment", environment] }
        let r = try await run(args, timeout: 600)
        let o = (r as? [String: Any]).map { ($0["sandbox"] as? [String: Any]) ?? $0 } ?? [:]
        guard let info = Self.info(o) else { throw SandboxError(message: "boat new returned no sandbox id: \(r)") }
        return info
    }

    func exec(_ id: String, command: String, cwd: String?, timeout: Int, background: Bool) async throws -> Any {
        var args = ["exec", id, "--timeout", String(timeout)]
        if let cwd { args += ["--cwd", cwd] }
        if background { args.append("--detach") }
        args += ["--", "bash", "-lc", command]
        return try await run(args, timeout: TimeInterval(timeout == 0 ? 3600 : timeout + 30))
    }

    func push(_ id: String, dir: String, to: String?) async throws -> Any {
        var args = ["push", id, dir]
        if let to { args += ["--to", to] }
        return try await run(args, timeout: 900)
    }

    func url(_ id: String, port: Int, isPublic: Bool) async throws -> Any {
        try await run(["host", id, String(port)] + (isPublic ? ["--public"] : []), timeout: 60)
    }

    func stop(_ id: String) async throws -> Any { try await run(["stop", id], timeout: 300) }
    func resume(_ id: String) async throws -> Any { try await run(["resume", id], timeout: 600) }
    func delete(_ id: String) async throws -> Any { try await run(["delete", id, "--yes"], timeout: 120) }
    func openDesktop(_ id: String) async throws -> Any { try await run(["desktop", id], timeout: 60) }
    func sshCommand(_ id: String) -> String { "\(shellQuote(binary ?? "boat")) ssh \(shellQuote(id))" }

    func status() async -> [String: Any]? {
        guard var out = (try? await run(["status"], timeout: 20)) as? [String: Any] else { return nil }
        if let limits = (try? await run(["limits"], timeout: 20)) as? [String: Any],
           let h = limits["creditBalanceHours"] as? Double { out["creditHours"] = h }
        return out
    }
}

/// Which sandboxes each session uses (shown in its status bar), plus their latest state.
@MainActor
final class SandboxRegistry: ObservableObject {
    let provider: SandboxProvider = BoatProvider()
    /// session key (Claude session id, or "tab:<uuid>" before it has one) → sandbox ids, newest last
    @Published private(set) var bySession: [String: [String]] =
        (UserDefaults.standard.dictionary(forKey: "sessionSandboxes") as? [String: [String]]) ?? [:]
    @Published private(set) var info: [String: SandboxInfo] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    static func key(_ t: TerminalSession) -> String { t.sessionId ?? "tab:\(t.id)" }

    func ids(for t: TerminalSession) -> [String] {
        let a = bySession[Self.key(t)] ?? []
        let b = t.sessionId != nil ? (bySession["tab:\(t.id)"] ?? []) : []
        return a + b.filter { !a.contains($0) }
    }

    func attach(_ id: String, to t: TerminalSession) {
        var l = bySession[Self.key(t), default: []].filter { $0 != id }
        l.append(id)
        bySession[Self.key(t)] = l
        save()
    }

    func detach(_ id: String, from t: TerminalSession) {
        for k in [Self.key(t), "tab:\(t.id)"] { bySession[k]?.removeAll { $0 == id } }
        save()
    }

    func forget(_ id: String) {
        for k in bySession.keys { bySession[k]?.removeAll { $0 == id } }
        info.removeValue(forKey: id)
        save()
    }

    func note(_ s: SandboxInfo) { info[s.id] = s }

    private func save() {
        bySession = bySession.filter { !$0.value.isEmpty }
        UserDefaults.standard.set(bySession, forKey: "sessionSandboxes")
    }

    /// Refresh states of the sandboxes sessions use; drop ones that no longer exist.
    func refresh() async {
        let tracked = Set(bySession.values.flatMap { $0 })
        guard provider.installed, !tracked.isEmpty, let all = try? await provider.list() else { return }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in tracked {
            if let s = byId[id] { if info[id] != s { info[id] = s } } else { forget(id) }
        }
    }
}
