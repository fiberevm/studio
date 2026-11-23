import SwiftUI

/// Settings → Worktrees: every worktree in the projects Studio knows, what is in it, how much disk it takes
/// and which sessions are in it right now, with Delete for one and Clean Up for all the untouched ones.
struct WorktreeSettings: View {
    @EnvironmentObject var store: SessionStore
    @State private var items: [Worktrees.Info] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var loading = true
    @State private var confirm: Worktrees.Info?
    @State private var confirmCleanUp = false
    @State private var error: String?
    @State private var generation = 0
    @AppStorage(Worktrees.pref) private var worktrees = true
    /// Worktrees being deleted right now, and how a Clean Up is going.
    @State private var deleting: Set<String> = []
    @State private var progress: (done: Int, total: Int)?

    var body: some View {
        let total = items.compactMap { sizes[$0.path] }.reduce(0, +)
        let idle = items.filter { $0.untouched && users(of: $0).isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: "Give each new session its own worktree",
                detail: "In a git repo, a new session starts in a fresh worktree (.claude/worktrees/<name>, branch studio/<name>) so agents working in parallel don't edit the same files. If a session ends without changes, its worktree and branch are removed; otherwise they stay for you to review.", isOn: $worktrees)
            if worktrees { StartBranchSettings() }
            HStack(spacing: 10) {
                if loading || progress != nil { ProgressView().controlSize(.small) }
                Text(summary(total))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Spacer()
                Button("Refresh") { load() }.disabled(loading || progress != nil)
                Button("Clean Up \(idle.count) Unused…") { confirmCleanUp = true }.disabled(idle.isEmpty || progress != nil)
                    .help("Delete the worktrees with no changes, no new commits and no session in them")
            }
            .padding(.top, 22).padding(.bottom, 4)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 4) }
            ForEach(groups, id: \.repo) { g in
                Text(abbreviatePath(g.repo)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .padding(.top, 18).padding(.bottom, 6)
                Hairline()
                ForEach(g.items) { w in row(w) }
            }
            if !loading && items.isEmpty {
                Text("No worktrees. Sessions you start in a git repo get one each while the setting is on.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
        .onAppear { load() }
        .alert("Delete the worktree \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Delete", role: .destructive) { if let w = confirm { delete([w]) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm.map(warning) ?? "") }
        .alert("Delete \(idle.count) unused worktree\(idle.count == 1 ? "" : "s")?", isPresented: $confirmCleanUp) {
            Button("Delete", role: .destructive) { delete(idle) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("They have no changes, no new commits and no session in them. Their folders and studio/ branches are removed.") }
    }

    private func summary(_ total: Int64) -> String {
        if let p = progress { return "Deleting \(min(p.done + 1, p.total)) of \(p.total)…" }
        let n = "\(items.count) worktree\(items.count == 1 ? "" : "s")"
        if loading { return items.isEmpty ? "Looking for worktrees…" : n + " so far, still looking…" }
        if items.isEmpty { return "No worktrees" }
        return n + (sizes.count < items.count ? ", measuring…" : ", \(bytes(total)) on disk")
    }

    private var groups: [(repo: String, items: [Worktrees.Info])] {
        var order: [String] = [], by: [String: [Worktrees.Info]] = [:]
        for w in items { if by[w.repo] == nil { order.append(w.repo) }; by[w.repo, default: []].append(w) }
        return order.map { ($0, by[$0] ?? []) }
    }

    private func row(_ w: Worktrees.Info) -> some View {
        let using = users(of: w)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(w.branch ?? w.name).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if !w.byStudio { tag("not made by Studio", .secondary) }
                if !using.isEmpty { tag("in use", .green) }
                Spacer(minLength: 8)
                Text(sizes[w.path].map(bytes) ?? "…").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                if deleting.contains(w.path) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Deleting…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(width: 110, alignment: .trailing)
                } else {
                    Button("Reveal") { NSWorkspace.shared.open(URL(fileURLWithPath: w.path)) }.buttonStyle(.borderless).font(.system(size: 12))
                    Button("Delete…") { confirm = w }.buttonStyle(.borderless).font(.system(size: 12))
                        .disabled(!using.isEmpty || progress != nil)
                        .help(using.isEmpty ? "Delete this worktree" : "End the session using it first")
                }
            }
            Text(detail(w, using)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .padding(.leading, 19)
        }
        .padding(.vertical, 9)
        .opacity(deleting.contains(w.path) ? 0.55 : 1)
        .overlay(alignment: .bottom) { Hairline() }
        .help(w.path)
    }

    private func tag(_ text: String, _ color: SwiftUI.Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 1))
    }

    private func detail(_ w: Worktrees.Info, _ using: [String]) -> String {
        var parts: [String] = []
        if w.untouched { parts.append("No changes") }
        else {
            if w.ahead > 0 { parts.append("\(w.ahead) new commit\(w.ahead == 1 ? "" : "s")") }
            if w.dirty { parts.append("uncommitted changes") }
        }
        if let m = w.modified { parts.append("touched \(relativeTime(m)) ago".replacingOccurrences(of: "now ago", with: "just now")) }
        if !using.isEmpty { parts.append("used by " + using.prefix(2).joined(separator: ", ") + (using.count > 2 ? " and \(using.count - 2) more" : "")) }
        return parts.joined(separator: " · ")
    }

    private func warning(_ w: Worktrees.Info) -> String {
        var lost: [String] = []
        if w.dirty { lost.append("uncommitted changes") }
        if w.ahead > 0 { lost.append("\(w.ahead) commit\(w.ahead == 1 ? "" : "s") that \(w.ahead == 1 ? "is" : "are") only on this branch") }
        let branch = (w.branch?.hasPrefix("studio/") ?? false) ? " and its branch \(w.branch!)" : ""
        return (lost.isEmpty ? "It has no changes. " : "It has " + lost.joined(separator: " and ") + ", which will be lost. ")
            + "The folder\(branch) \(branch.isEmpty ? "is" : "are") removed for good."
    }

    /// Titles of the sessions running in this worktree right now: tabs in Studio and sessions started elsewhere.
    private func users(of w: Worktrees.Info) -> [String] {
        func inside(_ cwd: String) -> Bool { cwd == w.path || cwd.hasPrefix(w.path + "/") }
        var names: [String] = [], seen: Set<String> = []
        for t in store.terminals where t.running && !t.isFile && !t.isWeb && inside(t.cwd) {
            let title = t.sessionId.flatMap { store.records[$0]?.title } ?? (t.isShell ? "a terminal" : "a session")
            if let sid = t.sessionId { seen.insert(sid) }
            names.append(title)
        }
        for (sid, info) in store.live where !seen.contains(sid) && inside(info.cwd) {
            names.append(store.records[sid]?.title ?? "a session outside Studio")
        }
        return names
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// Find the worktrees, listing each as soon as git reports it, then measure each one's size.
    private func load() {
        loading = true
        generation += 1
        let gen = generation
        var found: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            Worktrees.scan { w in
                found.append(w.path)
                DispatchQueue.main.async {
                    guard gen == generation else { return }
                    if let i = items.firstIndex(where: { $0.path == w.path }) { items[i] = w } else { items.append(w) }
                }
            }
            DispatchQueue.main.async {
                guard gen == generation else { return }
                items.removeAll { !found.contains($0.path) }     // deleted since the last look
                sizes = sizes.filter { found.contains($0.key) }
                loading = false
            }
            for path in found {
                let s = Worktrees.size(of: path)
                DispatchQueue.main.async { if gen == generation, let s { sizes[path] = s } }
            }
        }
    }

    /// Delete one at a time, each row showing it, and drop each from the list as soon as it is gone.
    private func delete(_ list: [Worktrees.Info]) {
        error = nil
        // never one a session is in, whatever the list said when the dialog opened
        let safe = list.filter { users(of: $0).isEmpty }
        guard !safe.isEmpty else { return }
        generation += 1          // a scan still running must not put deleted rows back
        loading = false
        progress = (0, safe.count)
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for (i, w) in safe.enumerated() {
                DispatchQueue.main.async { deleting.insert(w.path); progress = (i, safe.count) }
                let msg = Worktrees.delete(w)
                DispatchQueue.main.async {
                    deleting.remove(w.path)
                    if msg == nil { items.removeAll { $0.path == w.path }; sizes[w.path] = nil }
                }
                if let msg { failures.append("\(w.name): \(msg)") }
            }
            DispatchQueue.main.async {
                progress = nil
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
            }
        }
    }
}
