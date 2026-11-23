import Foundation

/// Settings → Sessions → "Give each new session its own worktree" (on by default): a new agent session in a git
/// repo starts in a fresh `git worktree` at <repo>/.claude/worktrees/<name> on branch studio/<name>, branched from
/// the current HEAD, so parallel agents never edit the same checkout. That path is where `claude --worktree` puts
/// them too, and `projectRoot` folds it back into the repo, so the session still lists under the project.
/// Ending the session removes the worktree and its branch only if nothing happened there (no commits, no changes);
/// otherwise both stay for you to review, merge or delete.
enum Worktrees {
    static let pref = "sessionWorktrees"
    private static let basesKey = "worktreeBases"     // [worktree path: commit it started from]

    static var enabled: Bool { Pref.bool(pref, default: true) }

    /// The folder a new session in `folder` should start in: a new worktree (same subfolder inside it), or
    /// `folder` itself when the setting is off, it isn't a git repo, it's already a worktree, or git fails.
    static func folder(for folder: String, name: String) -> String {
        guard enabled, !folder.contains("/.claude/worktrees/"),
              let top = git(["rev-parse", "--show-toplevel"], in: folder),
              let head = git(["rev-parse", "--verify", "-q", startRef(top) + "^{commit}"], in: top)
                ?? git(["rev-parse", "HEAD"], in: folder) else { return folder }
        let path = top + "/.claude/worktrees/" + name
        guard git(["worktree", "add", "-q", "-b", "studio/" + name, path, head], in: top) != nil else { return folder }
        ignore(top)
        var bases = UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String] ?? [:]
        bases[path] = head
        UserDefaults.standard.set(bases, forKey: basesKey)
        remember(repo: top)
        let rel = folder.count > top.count ? String(folder.dropFirst(top.count)) : ""
        let dir = path + rel
        return FileManager.default.fileExists(atPath: dir) ? dir : path
    }

    // MARK: Start branch (per project)

    /// Settings → Sessions → Start branch, per repo: [repo root: branch]. Missing or "" = the repo's default branch;
    /// `currentBranch` = whatever the main checkout has checked out when the session starts.
    static let startBranchesKey = "worktreeStartBranch"
    static let currentBranch = "HEAD"

    static func startBranch(_ repo: String) -> String {
        (UserDefaults.standard.dictionary(forKey: startBranchesKey) as? [String: String])?[repo] ?? ""
    }
    static func setStartBranch(_ branch: String, for repo: String) {
        var d = UserDefaults.standard.dictionary(forKey: startBranchesKey) as? [String: String] ?? [:]
        d[repo] = branch.isEmpty ? nil : branch
        UserDefaults.standard.set(d, forKey: startBranchesKey)
    }

    /// The ref a new worktree in `repo` branches from.
    static func startRef(_ repo: String) -> String {
        let b = startBranch(repo)
        return b.isEmpty ? (defaultBranch(repo) ?? currentBranch) : b
    }

    /// The repo's default branch: origin's HEAD (as a local branch if there is one), else main or master.
    static func defaultBranch(_ repo: String) -> String? {
        let local = Set(branches(repo))
        if let r = git(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: repo) {
            let name = r.hasPrefix("origin/") ? String(r.dropFirst(7)) : r
            return local.contains(name) ? name : r
        }
        return ["main", "master"].first { local.contains($0) }
    }

    /// Local branches, most recently committed first (studio/ worktree branches left out).
    static func branches(_ repo: String) -> [String] {
        (git(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], in: repo) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("studio/") }
    }

    // MARK: Every worktree, for Settings → Worktrees

    /// A linked worktree of a repo Studio knows: where it is, what is in it, and how much disk it takes.
    struct Info: Identifiable, Equatable {
        let path: String
        let repo: String
        let branch: String?
        /// Studio made it for a session (as opposed to `git worktree add` or `claude --worktree` by hand).
        let byStudio: Bool
        /// Files changed or untracked right now.
        let dirty: Bool
        /// Commits on it that its start point (or the repo's default branch) doesn't have.
        let ahead: Int
        let modified: Date?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        /// Nothing in it would be lost by deleting it.
        var untouched: Bool { !dirty && ahead == 0 }
    }

    private static let reposKey = "worktreeRepos"     // repo roots Studio has made worktrees in

    private static func remember(repo: String) {
        var l = UserDefaults.standard.stringArray(forKey: reposKey) ?? []
        if !l.contains(repo) { l.append(repo); UserDefaults.standard.set(l, forKey: reposKey) }
    }

    /// The repos to look in: every one Studio made a worktree in, plus the recent projects.
    static func knownRepos() -> [String] {
        let bases = UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String] ?? [:]
        var roots = UserDefaults.standard.stringArray(forKey: reposKey) ?? []
        roots += bases.keys.map(projectRoot)
        roots += RecentProjects.list().map(projectRoot)
        var seen: Set<String> = [], out: [String] = []
        for r in roots where FileManager.default.fileExists(atPath: r) {
            let top = repoRoot(r) ?? r
            if seen.insert(top).inserted, FileManager.default.fileExists(atPath: top + "/.git") { out.append(top) }
        }
        return out
    }

    /// Every linked worktree of the known repos (not their main checkouts). Runs git: call off the main thread.
    static func all() -> [Info] {
        let bases = UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String] ?? [:]
        var out: [Info] = []
        for repo in knownRepos() {
            let main = defaultBranch(repo)
            for c in checkouts(of: repo).dropFirst() {
                let dirty = !(git(["status", "--porcelain"], in: c.path) ?? "").isEmpty
                let from = bases[c.path] ?? main
                let ahead = from.flatMap { Int(git(["rev-list", "--count", "\($0)..HEAD"], in: c.path) ?? "") } ?? 0
                let modified = (try? FileManager.default.attributesOfItem(atPath: c.path))?[.modificationDate] as? Date
                out.append(Info(path: c.path, repo: repo, branch: c.branch, byStudio: bases[c.path] != nil,
                                dirty: dirty, ahead: ahead, modified: modified))
            }
        }
        return out
    }

    /// Disk space a folder takes, in bytes (`du`). Slow on big trees: call off the main thread.
    static func size(of path: String) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let kb = Int64(String(decoding: data, as: UTF8.self).split(separator: "\t").first ?? "") else { return nil }
        return kb * 1024
    }

    /// Remove a worktree and its folder, changes included, and its `studio/` branch. Returns git's message on failure.
    static func delete(_ w: Info) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", w.repo, "worktree", "remove", "--force", w.path]
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice; p.standardError = err
        do { try p.run() } catch { return error.localizedDescription }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return msg.isEmpty ? "git worktree remove failed" : msg }
        if let b = w.branch, b.hasPrefix("studio/") { _ = git(["branch", "-D", b], in: w.repo) }
        var bases = UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String] ?? [:]
        bases[w.path] = nil
        UserDefaults.standard.set(bases, forKey: basesKey)
        return nil
    }

    /// One checkout of a repo: the main one or a linked worktree.
    struct Checkout: Identifiable, Equatable {
        let path: String
        /// The branch checked out there; nil when HEAD is detached.
        let branch: String?
        var id: String { path }
    }

    /// Every checkout of the repo `folder` is in (`git worktree list`), the main one first. Paths under `folder`
    /// are spelled like `folder` (git prints them with symlinks resolved). Empty outside a git repo.
    static func checkouts(of folder: String) -> [Checkout] {
        guard let out = git(["worktree", "list", "--porcelain"], in: folder) else { return [] }
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var list: [Checkout] = []
        for block in out.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, skip = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
                else if line == "bare" || line.hasPrefix("prunable") { skip = true }
            }
            guard var p = path, !skip, FileManager.default.fileExists(atPath: p) else { continue }
            if p == real { p = folder } else if p.hasPrefix(real + "/") { p = folder + p.dropFirst(real.count) }
            list.append(Checkout(path: p, branch: branch))
        }
        return list
    }

    /// The git repo root for `folder`, if it is in one.
    static func repoRoot(_ folder: String) -> String? { git(["rev-parse", "--show-toplevel"], in: folder) }

    /// After a session ends: drop the worktree Studio made for it if it is untouched. Off the main thread.
    static func cleanUp(_ cwd: String) {
        guard let r = cwd.range(of: "/.claude/worktrees/") else { return }
        let name = cwd[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        let path = String(cwd[..<r.upperBound]) + name
        guard let base = (UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String])?[path] else { return }
        let repo = String(cwd[..<r.lowerBound])
        DispatchQueue.global(qos: .utility).async {
            guard let head = git(["rev-parse", "HEAD"], in: path), head == base,
                  let status = git(["status", "--porcelain"], in: path), status.isEmpty,
                  let branch = git(["branch", "--show-current"], in: path),
                  git(["worktree", "remove", path], in: repo) != nil else { return }
            if branch.hasPrefix("studio/") { _ = git(["branch", "-D", branch], in: repo) }
            DispatchQueue.main.async {
                var bases = UserDefaults.standard.dictionary(forKey: basesKey) as? [String: String] ?? [:]
                bases[path] = nil
                UserDefaults.standard.set(bases, forKey: basesKey)
            }
        }
    }

    /// A short, readable worktree name: "<adjective>-<noun>-<4 hex>".
    static func newName() -> String {
        let a = ["amber", "brisk", "calm", "deft", "eager", "fleet", "keen", "lucid", "nimble", "quiet", "swift", "vivid"]
        let n = ["cedar", "comet", "falcon", "harbor", "lynx", "maple", "otter", "pine", "quartz", "river", "sparrow", "willow"]
        return "\(a.randomElement()!)-\(n.randomElement()!)-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// Keep .claude/worktrees/ out of the repo's `git status` without touching its .gitignore.
    private static func ignore(_ top: String) {
        guard git(["check-ignore", "-q", ".claude/worktrees/x"], in: top) == nil,
              let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: top) else { return }
        let file = common + "/info/exclude"
        try? FileManager.default.createDirectory(atPath: common + "/info", withIntermediateDirectories: true)
        let old = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let line = "/.claude/worktrees/\n"
        guard !old.contains("/.claude/worktrees/") else { return }
        try? (old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + line).write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Runs git; trimmed stdout on success, nil on failure.
    @discardableResult
    private static func git(_ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
