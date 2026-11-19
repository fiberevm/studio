import AppKit
import SQLite3

/// An image in the conversation (pasted into a prompt, or returned by a tool such as a screenshot).
/// Compared by id; the bytes are decoded into an NSImage only when drawn.
struct ChatImage: Identifiable, Equatable {
    let id: String
    let data: Data
    static func == (a: ChatImage, b: ChatImage) -> Bool { a.id == b.id }

    private static let cache = NSCache<NSString, NSImage>()
    var image: NSImage? {
        if let i = Self.cache.object(forKey: id as NSString) { return i }
        guard let i = NSImage(data: data) else { return nil }
        Self.cache.setObject(i, forKey: id as NSString)
        return i
    }

    /// Images in a message's content blocks ({"type":"image","source":{"type":"base64","data":…}}).
    static func all(in content: Any?, prefix: String) -> [ChatImage] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { n, b in
            guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
                  src["type"] as? String == "base64", let s = src["data"] as? String,
                  let d = Data(base64Encoded: s) else { return nil }
            return ChatImage(id: "\(prefix)#img\(n)", data: d)
        }
    }
}

/// One entry in a native (non-TUI) conversation view.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case text(String)                                   // Claude's prose (markdown)
        case tool(id: String, name: String, summary: String)
        case permission(requestId: String, tool: String, summary: String, input: String)
        case note(String)                                   // "Done in 4.2s · $0.12", errors, interruptions
    }
    let id: String
    var kind: Kind
    // tool results attach to their tool item
    var output: String? = nil
    var duration: Double? = nil                            // note: how long the turn took
    var isError = false
    var decided: Bool? = nil                                // permission: nil = pending, true = allowed
    var images: [ChatImage] = []                            // a prompt's pasted images, a tool's returned ones
}

/// Drives `claude -p` with streaming JSON in and out, so Studio can draw the conversation itself.
/// Protocol: we write {"type":"user",…} lines to stdin; Claude streams system/assistant/user/result lines,
/// `stream_event` deltas (with --include-partial-messages), and `control_request` can_use_tool permission
/// asks, which we answer with a `control_response`.
@MainActor
final class NativeChat: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var busy = false
    @Published private(set) var exited = false
    @Published var sessionId: String?
    /// Text streaming in for the current assistant block.
    @Published private(set) var streaming = ""
    @Published private(set) var model: String?
    @Published private(set) var permissionMode = "default"
    @Published private(set) var turnStartedAt: Date?

    var pendingPermission: Bool { items.contains { if case .permission = $0.kind { return $0.decided == nil }; return false } }
    /// What Claude is doing right now (for the tab icon).
    var activity: Activity? {
        guard busy else { return nil }
        if !streaming.isEmpty { return .writing }
        if let last = items.last, case .tool(_, let name, _) = last.kind, last.output == nil { return .tool(name) }
        return .thinking
    }

    var status: SessionStatus { exited ? .exited : pendingPermission ? .waiting : busy ? .working : .idle }

    let cwd: String
    private let tab: UUID
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pendingInputs: [String: [String: Any]] = [:]   // permission request id → tool input
    var pid: Int32 { (process ?? codexTurn)?.processIdentifier ?? 0 }
    /// Which CLI draws this conversation: Claude Code (`claude -p` streaming JSON), agy (its own stream-json),
    /// or Codex (one `codex exec --json` per turn).
    let agent: Agent

    // agy: rules allowed for this session (approved in the view), and a restart in progress
    var agyAllow: [String] = []
    var agyRestarting = false
    var agyText: [Int: String] = [:]          // agent_response text by step index, as it streams
    var agyDenyTarget: [String: String] = [:] // permission action → what it was for (the last denied tool's target)
    // Codex: the process running the current turn
    var codexTurn: Process?
    var codexTurnNo = 0
    /// Tokens this conversation used in the native view (agy and Codex report them per turn).
    @Published var tokensIn = 0
    @Published var tokensOut = 0
    /// The composer's text view, so selecting the tab can put the cursor in it.
    weak var inputView: NSView?
    var onSessionId: ((String) -> Void)?

    init(cwd: String, tab: UUID, resume sid: String?, agent: Agent = .claude) {
        self.cwd = cwd
        self.tab = tab
        self.sessionId = sid
        self.agent = agent
        switch agent {
        case .claude:
            if let sid { loadHistory(sid) }
            start(resume: sid, mode: Pref.string(Pref.nativePermissionMode) ?? lastMode)
        case .agy:
            permissionMode = "auto"
            if let sid { loadAgyHistory(sid) }
            startAgy()
        case .codex:
            permissionMode = "workspace-write"   // each turn runs as its own process, with this sandbox
            if let sid { loadCodexHistory(sid) }
        }
    }

    /// The permission modes this agent offers in the native view: id, label, SF Symbol.
    var modes: [(id: String, label: String, icon: String)] {
        switch agent {
        case .claude: return [("default", "Supervised", "hand.raised"), ("acceptEdits", "Auto-accept edits", "checkmark.shield"),
                              ("plan", "Plan only", "list.bullet.clipboard"), ("bypassPermissions", "Full access", "lock.open")]
        case .agy: return [("auto", "Auto", "checkmark.shield"), ("accept-edits", "Accept edits", "pencil"),
                           ("plan", "Plan only", "list.bullet.clipboard"), ("full", "Full access", "lock.open")]
        case .codex: return [("read-only", "Read only", "eye"), ("workspace-write", "Workspace", "checkmark.shield"),
                             ("full", "Full access", "lock.open")]
        }
    }

    // MARK: Process

    /// The permission mode the session last ran in (from its transcript), so native mode behaves the same.
    private var lastMode: String?

    private func start(resume sid: String?, mode: String?) {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        if let mode { args += ["--permission-mode", mode] }
        if let sid { args += ["--resume", sid] }
        if let plugin = StudioControl.pluginDir { args += ["--plugin-dir", plugin] }
        if let cfg = StudioControl.mcpConfigPath { args += ["--mcp-config", cfg] }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // login shell so `claude` resolves like in Terminal; exec keeps the pid
        p.arguments = ["-l", "-c", (["exec", "claude"] + args).map(shellQuote).joined(separator: " ")]
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        var env: [String: String] = [:]
        for kv in TerminalSession.childEnvironment(tab: tab) {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.exited = true
                self.busy = false
                if code != 0 && code != 15 && code != 1 { self.note("Claude exited (code \(code))") }
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
        } catch {
            note("Couldn't start claude: \(error.localizedDescription)")
            exited = true
        }
    }

    func stop() {
        codexTurn?.terminate()
        guard let p = process, p.isRunning else { return }
        try? stdin?.close()
        p.terminate()
    }

    private func write(_ obj: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? stdin.write(contentsOf: data + Data([0x0A]))
    }

    // MARK: Input

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !exited else { return }
        items.append(ChatItem(id: UUID().uuidString, kind: .user(t)))
        busy = true
        turnStartedAt = Date()
        switch agent {
        case .claude: write(["type": "user", "message": ["role": "user", "content": t]])
        case .agy: write(["event": "user", "message": ["role": "user", "content": t]])
        case .codex: runCodexTurn(t)
        }
    }

    /// Supervised (ask), auto-accept edits, or full access — changes the running session's permission mode.
    func setPermissionMode(_ mode: String) {
        permissionMode = mode
        switch agent {
        case .claude:
            write(["type": "control_request", "request_id": UUID().uuidString,
                   "request": ["subtype": "set_permission_mode", "mode": mode]])
        case .agy: restartAgy()          // agy takes its mode at start
        case .codex: break               // applies from the next turn
        }
    }

    func interrupt() {
        guard busy else { return }
        switch agent {
        case .claude: write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
        case .agy: restartAgy(); busy = false; streaming = ""; note("stopped")
        case .codex: codexTurn?.terminate()
        }
    }

    func answer(_ item: ChatItem, allow: Bool) {
        if agent == .agy { answerAgy(item, allow: allow); return }
        guard case .permission(let rid, _, _, _) = item.kind, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].decided = allow
        let input = pendingInputs.removeValue(forKey: rid) ?? [:]
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "The user declined this action."]
        write(["type": "control_response", "response": ["subtype": "success", "request_id": rid, "response": response]])
    }

    // MARK: Output

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch agent {
            case .claude: handle(obj)
            case .agy: handleAgy(obj)
            case .codex: handleCodex(obj)
            }
        }
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                if let m = o["model"] as? String { model = m }
                if let pm = o["permissionMode"] as? String { permissionMode = pm }
                if let sid = o["session_id"] as? String, sid != sessionId {
                    sessionId = sid
                    onSessionId?(sid)
                }
            }
        case "stream_event":
            guard let ev = o["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta", let d = ev["delta"] as? [String: Any],
               d["type"] as? String == "text_delta", let t = d["text"] as? String {
                streaming += t
            }
        case "assistant":
            guard let msg = o["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return }
            let mid = msg["id"] as? String ?? UUID().uuidString
            for (n, b) in blocks.enumerated() { addAssistantBlock(b, id: "\(mid)#\(n)") }
            streaming = ""
        case "user":
            guard let msg = o["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return }
            for b in blocks where b["type"] as? String == "tool_result" { attachResult(b) }
        case "result":
            busy = false
            streaming = ""
            let secs = (o["duration_ms"] as? Double).map { $0 / 1000 } ?? turnStartedAt.map { Date().timeIntervalSince($0) }
            turnStartedAt = nil
            var item = ChatItem(id: UUID().uuidString, kind: .note(o["subtype"] as? String == "success" ? "done" : (o["subtype"] as? String ?? "stopped")))
            item.duration = secs
            items.append(item)
        case "control_request":
            guard let req = o["request"] as? [String: Any], req["subtype"] as? String == "can_use_tool",
                  let rid = o["request_id"] as? String else { return }
            let name = req["display_name"] as? String ?? req["tool_name"] as? String ?? "tool"
            let input = req["input"] as? [String: Any] ?? [:]
            pendingInputs[rid] = input
            items.append(ChatItem(id: "perm-\(rid)", kind: .permission(
                requestId: rid, tool: name, summary: Self.summary(tool: name, input: input, cwd: cwd),
                input: Self.pretty(input))))
        default: break
        }
    }

    private func addAssistantBlock(_ b: [String: Any], id: String) {
        switch b["type"] as? String {
        case "text":
            guard !items.contains(where: { $0.id == id }) else { return }
            if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(ChatItem(id: id, kind: .text(t)))
            }
        case "tool_use":
            let name = b["name"] as? String ?? "tool"
            let tid = b["id"] as? String ?? id
            guard !items.contains(where: { $0.id == tid }) else { return }
            items.append(ChatItem(id: tid, kind: .tool(id: tid, name: name,
                                                        summary: Self.summary(tool: name, input: b["input"] as? [String: Any] ?? [:], cwd: cwd))))
        default: break   // thinking etc.
        }
    }

    private func attachResult(_ b: [String: Any]) {
        guard let tid = b["tool_use_id"] as? String, let i = items.firstIndex(where: { $0.id == tid }) else { return }
        items[i].output = Self.text(of: b["content"])
        items[i].isError = b["is_error"] as? Bool ?? false
        items[i].images = ChatImage.all(in: b["content"], prefix: tid)
    }

    private func note(_ s: String) { items.append(ChatItem(id: UUID().uuidString, kind: .note(s))) }

    // MARK: History

    /// Show the conversation so far from its transcript, so switching modes keeps the context on screen.
    private func loadHistory(_ sid: String) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.projects.path) else { return }
        for d in dirs {
            let path = Paths.projects.appendingPathComponent(d).appendingPathComponent("\(sid).jsonl").path
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            // streamed (transcripts reach hundreds of MB); the view keeps only the last 400 entries anyway
            _ = forEachLine(fh, from: 0) { line in
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true else { return }
                if o["type"] as? String == "permission-mode", let m = o["permissionMode"] as? String { lastMode = m; return }
                guard let msg = o["message"] as? [String: Any] else { return }
                switch o["type"] as? String {
                case "user":
                    if let s = msg["content"] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") {
                            items.append(ChatItem(id: o["uuid"] as? String ?? UUID().uuidString, kind: .user(t)))
                        }
                    } else if let blocks = msg["content"] as? [[String: Any]] {
                        for b in blocks where b["type"] as? String == "tool_result" { attachResult(b) }
                        // a prompt with pasted images: its text blocks and images as one message
                        let texts = blocks.compactMap { b -> String? in
                            guard b["type"] as? String == "text", let t = b["text"] as? String, !t.hasPrefix("<") else { return nil }
                            return t
                        }
                        let id = o["uuid"] as? String ?? UUID().uuidString
                        let imgs = ChatImage.all(in: blocks, prefix: id)
                        if !texts.isEmpty || !imgs.isEmpty {
                            var item = ChatItem(id: id, kind: .user(texts.joined(separator: "\n")))
                            item.images = imgs
                            items.append(item)
                        }
                    }
                case "assistant":
                    let mid = msg["id"] as? String ?? UUID().uuidString
                    for (n, b) in (msg["content"] as? [[String: Any]] ?? []).enumerated() { addAssistantBlock(b, id: "\(mid)#\(n)") }
                default: break
                }
                // keep the view light: the last 400 entries are plenty of context
                if items.count > 800 { items.removeFirst(items.count - 400) }
            }
            break
        }
        if items.count > 400 { items = Array(items.suffix(400)) }
    }

    // MARK: Formatting

    static func summary(tool: String, input: [String: Any], cwd: String) -> String {
        func rel(_ p: String) -> String { p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : abbreviatePath(p) }
        let s: String
        switch tool {
        case "Bash": s = input["command"] as? String ?? ""
        case "Read", "Write", "Edit", "NotebookEdit": s = rel(input["file_path"] as? String ?? input["notebook_path"] as? String ?? "")
        case "Grep", "Glob": s = input["pattern"] as? String ?? ""
        case "WebFetch": s = input["url"] as? String ?? ""
        case "WebSearch": s = input["query"] as? String ?? ""
        case "Task", "Agent": s = input["description"] as? String ?? ""
        default: s = input.values.compactMap { $0 as? String }.first ?? ""
        }
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 160 ? String(one.prefix(159)) + "…" : one
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    static func pretty(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s.count > 2000 ? String(s.prefix(2000)) + "\n…" : s
    }
}

// MARK: - agy and Codex

extension NativeChat {
    /// Run an agent CLI through the login shell (so it resolves like in Terminal), streaming its stdout to
    /// receive(). `onExit` gets the exit code.
    private func spawn(_ words: [String], stdin wantsInput: Bool, onExit: @escaping (Int32) -> Void) -> Process? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", (["exec"] + words).map(shellQuote).joined(separator: " ")]
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        var env: [String: String] = [:]
        for kv in TerminalSession.childEnvironment(tab: tab) {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        let inPipe = wantsInput ? Pipe() : nil
        p.standardInput = inPipe ?? FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in onExit(code) }
        }
        do { try p.run() } catch {
            note("Couldn't start \(words.first ?? "the agent"): \(error.localizedDescription)")
            return nil
        }
        if let inPipe { stdin = inPipe.fileHandleForWriting }
        return p
    }

    // MARK: agy

    /// agy's headless stream-json mode: one process for the conversation, a turn per `{"event":"user"}` line.
    /// It can't ask for permission (it denies and reports it), so approvals restart it with that one action
    /// allowed for the session (`--settings {"permissions":{"allow":[…]}}`).
    func startAgy() {
        var words = ["agy", "--input-format", "stream-json", "--output-format", "stream-json"]
        words += permissionMode == "full" ? ["--dangerously-skip-permissions"] : ["--mode", permissionMode]
        if let sid = sessionId { words += ["--conversation", sid] }
        if !agyAllow.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: ["permissions": ["allow": agyAllow]], options: [.withoutEscapingSlashes]),
           let json = String(data: d, encoding: .utf8) {
            words += ["--settings", json]
        }
        words.append("-p=")
        exited = false
        process = spawn(words, stdin: true) { [weak self] code in
            guard let self else { return }
            if self.agyRestarting { self.agyRestarting = false; self.startAgy(); return }
            self.exited = true
            self.busy = false
            if code != 0 && code != 15 { self.note("agy exited (code \(code))") }
        }
        if process == nil { exited = true }
    }

    /// New mode or newly allowed actions: start agy again on the same conversation.
    func restartAgy() {
        guard let p = process, p.isRunning else { startAgy(); return }
        agyRestarting = true
        try? stdin?.close()
        p.terminate()
    }

    func answerAgy(_ item: ChatItem, allow: Bool) {
        guard case .permission(_, let tool, _, let rule) = item.kind, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].decided = allow
        guard allow else { return }
        agyAllow.append(rule)
        restartAgy()
        // once it's back up, let it carry on with what it was blocked on
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.send("Go ahead: \(tool) is allowed now.")
        }
    }

    func handleAgy(_ o: [String: Any]) {
        switch o["event"] as? String {
        case "init":
            if let sid = o["conversation_id"] as? String, sid != sessionId { sessionId = sid; onSessionId?(sid) }
        case "step_update":
            guard let d = o["step_update"] as? [String: Any], let idx = d["step_index"] as? Int else { return }
            let state = d["state"] as? String ?? ""
            if let u = d["usage"] as? [String: Any] {
                tokensIn += (u["input_tokens"] as? Int ?? 0) + (u["cache_read_tokens"] as? Int ?? 0)
                tokensOut += (u["output_tokens"] as? Int ?? 0) + (u["thinking_tokens"] as? Int ?? 0)
            }
            switch d["step_type"] as? String {
            case "agent_response":
                agyText[idx, default: ""] += d["text_delta"] as? String ?? ""
                streaming = agyText[idx] ?? ""
                if state == "DONE" {
                    let t = (agyText.removeValue(forKey: idx) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    streaming = ""
                    if !t.isEmpty { items.append(ChatItem(id: "agy-\(sessionId ?? "")-\(idx)", kind: .text(t))) }
                }
            case "tool":
                let info = d["tool_info"] as? [String: Any] ?? [:]
                let raw = d["tool_name"] as? String ?? info["name"] as? String ?? "tool"
                let params = info["parameters"] as? [String: Any] ?? [:]
                let id = "agy-tool-\(sessionId ?? "")-\(idx)"
                if !items.contains(where: { $0.id == id }) {
                    items.append(ChatItem(id: id, kind: .tool(id: id, name: Self.agyToolName(raw), summary: Self.agyTarget(params))))
                }
                guard state == "DONE" || state == "ERROR", let i = items.firstIndex(where: { $0.id == id }) else { return }
                let err = (info["error"] as? [String: Any])?["message"] as? String
                items[i].output = err ?? Self.text(of: info["output"]) 
                if items[i].output?.isEmpty != false { items[i].output = state == "ERROR" ? "failed" : "done" }
                items[i].isError = state == "ERROR"
                if state == "ERROR" { agyDenyTarget[raw == "run_command" ? "command" : raw] = Self.agyTarget(params) }
            default: break
            }
        case "result":
            guard let r = o["result"] as? [String: Any] else { return }
            if !streaming.isEmpty { items.append(ChatItem(id: UUID().uuidString, kind: .text(streaming))); streaming = "" }
            agyText = [:]
            busy = false
            // anything it wasn't allowed to do: ask, like a permission prompt
            for (n, a) in (r["denied_actions"] as? [[String: Any]] ?? []).enumerated() {
                let action = a["action"] as? String ?? "command"
                let name = a["display_name"] as? String ?? action
                let target = agyDenyTarget[action]
                let rule = target.map { "\(action)(\($0))" } ?? action
                items.append(ChatItem(id: "agy-deny-\(UUID().uuidString)-\(n)", kind: .permission(
                    requestId: rule, tool: name, summary: target ?? "\(name) (any)", input: rule)))
            }
            agyDenyTarget = [:]
            if r["status"] as? String == "ERROR", let e = r["error"] as? String, !e.contains("cancel") { note(e) }
            var item = ChatItem(id: UUID().uuidString, kind: .note("done"))
            item.duration = r["duration_seconds"] as? Double ?? turnStartedAt.map { Date().timeIntervalSince($0) }
            turnStartedAt = nil
            items.append(item)
        default: break
        }
    }

    /// agy's tools under the names Claude Code uses (for the icons and the TUI-like rows).
    static func agyToolName(_ t: String) -> String {
        switch t {
        case "run_command", "send_command_input", "command_status": return "Bash"
        case "view_file": return "Read"
        case "write_to_file": return "Write"
        case "replace_file_content", "multi_replace_file_content", "sed_file": return "Edit"
        case "grep_search": return "Grep"
        case "find_by_name", "list_dir": return "Glob"
        case "read_url_content": return "WebFetch"
        case "search_web": return "WebSearch"
        case "call_mcp_tool": return "mcp__tool"
        default: return t
        }
    }

    static func agyTarget(_ p: [String: Any]) -> String {
        for k in ["CommandLine", "AbsolutePath", "TargetFile", "File", "Path", "DirectoryPath", "Query", "Url", "Pattern"] {
            if let v = p[k] as? String, !v.isEmpty { return v.replacingOccurrences(of: "\n", with: " ") }
        }
        return p.values.compactMap { $0 as? String }.first ?? ""
    }

    /// History from agy's conversation database: steps hold protobuf blobs, with the text as plain strings.
    /// History: the messages of agy's newest model call (each call records the conversation so far).
    func loadAgyHistory(_ sid: String) {
        let path = AgyPaths.conversations.appendingPathComponent(sid + ".db").path
        for (n, m) in AgyHistory.messages(path).enumerated() {
            items.append(ChatItem(id: "agyh-\(n)", kind: m.user ? .user(m.text) : .text(m.text)))
        }
        if items.count > 400 { items = Array(items.suffix(400)) }
    }

    // MARK: Codex

    /// `codex exec --json` runs one turn and exits; the next turn resumes the conversation. Approvals can't be
    /// asked headless, so the mode is Codex's sandbox: read only, the workspace, or full access.
    func runCodexTurn(_ text: String) {
        var words = ["codex", "exec", "--json", "--skip-git-repo-check"]
        words += permissionMode == "full" ? ["--dangerously-bypass-approvals-and-sandbox"] : ["-s", permissionMode]
        let exe = ((Bundle.main.executablePath ?? "") as NSString).deletingLastPathComponent + "/studio-mcp"
        if FileManager.default.isExecutableFile(atPath: exe) {
            words += ["-c", "mcp_servers.studio.command=\"\(exe)\"",
                      "-c", "mcp_servers.studio.env={STUDIO_TAB=\"\(tab.uuidString)\", STUDIO_CONTROL_FILE=\"\(StudioControl.controlFilePath)\"}"]
        }
        if let skill = StudioControl.skillTOML { words += ["-c", "developer_instructions=" + skill] }
        words += sessionId.map { ["resume", $0, text] } ?? ["--", text]
        codexTurnNo += 1
        codexTurn = spawn(words, stdin: false) { [weak self] code in
            guard let self else { return }
            self.codexTurn = nil
            if self.busy {   // ended without turn.completed: stopped, or failed
                self.busy = false
                self.note(code == 15 || code == 0 ? "stopped" : "Codex exited (code \(code))")
                self.turnStartedAt = nil
            }
        }
        if codexTurn == nil { busy = false }
    }

    func handleCodex(_ o: [String: Any]) {
        let turn = codexTurnNo
        switch o["type"] as? String {
        case "thread.started":
            if let sid = o["thread_id"] as? String, sid != sessionId { sessionId = sid; onSessionId?(sid) }
        case "item.started", "item.completed":
            guard let it = o["item"] as? [String: Any], let raw = it["id"] as? String else { return }
            let id = "cx-\(turn)-\(raw)"
            let done = o["type"] as? String == "item.completed"
            switch it["type"] as? String {
            case "agent_message":
                if done, let t = it["text"] as? String, !t.isEmpty { items.append(ChatItem(id: id, kind: .text(t))) }
            case "command_execution":
                upsertTool(id, "Bash", Self.codexCommand(it["command"] as? String ?? ""), done: done,
                           output: it["aggregated_output"] as? String, failed: (it["exit_code"] as? Int).map { $0 != 0 } ?? false)
            case "file_change":
                let paths = (it["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                upsertTool(id, "Edit", paths.map { Self.rel($0, cwd) }.joined(separator: ", "), done: done,
                           output: done ? "updated" : nil, failed: it["status"] as? String == "failed")
            case "mcp_tool_call":
                let name = "mcp__\(it["server"] as? String ?? "")__\(it["tool"] as? String ?? "")"
                upsertTool(id, name, "", done: done, output: done ? Self.text(of: (it["result"] as? [String: Any])?["content"]) : nil,
                           failed: it["status"] as? String == "failed")
            case "web_search":
                upsertTool(id, "WebSearch", it["query"] as? String ?? "", done: done, output: done ? "done" : nil, failed: false)
            default: break   // reasoning, todo lists, config warnings
            }
        case "turn.completed":
            if let u = o["usage"] as? [String: Any] {
                tokensIn += u["input_tokens"] as? Int ?? 0
                tokensOut += (u["output_tokens"] as? Int ?? 0) + (u["reasoning_output_tokens"] as? Int ?? 0)
            }
            busy = false
            var item = ChatItem(id: UUID().uuidString, kind: .note("done"))
            item.duration = turnStartedAt.map { Date().timeIntervalSince($0) }
            turnStartedAt = nil
            items.append(item)
        case "turn.failed", "error":
            let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? o["message"] as? String
            if let msg, !msg.contains("deprecated") { note(msg) }
        default: break
        }
    }

    private func upsertTool(_ id: String, _ name: String, _ summary: String, done: Bool, output: String?, failed: Bool) {
        if !items.contains(where: { $0.id == id }) { items.append(ChatItem(id: id, kind: .tool(id: id, name: name, summary: summary))) }
        guard done, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].output = (output?.isEmpty == false ? output : nil) ?? (failed ? "failed" : "done")
        items[i].isError = failed
    }

    /// `/bin/bash -lc 'rtk ls'` → `rtk ls`
    static func codexCommand(_ c: String) -> String {
        if let r = c.range(of: #"^\S*(ba|z)?sh -l?c '(.*)'$"#, options: .regularExpression), !r.isEmpty,
           let q = c.firstIndex(of: "'") {
            return String(c[c.index(after: q)..<c.index(before: c.endIndex)]).replacingOccurrences(of: "'\\''", with: "'")
        }
        return c
    }

    static func rel(_ p: String, _ cwd: String) -> String {
        p.hasPrefix(cwd + "/") ? String(p.dropFirst(cwd.count + 1)) : abbreviatePath(p)
    }

    /// History from the conversation's rollout: its completed items (prompts, replies, commands, edits, tools).
    func loadCodexHistory(_ sid: String) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: CodexPaths.sessions, includingPropertiesForKeys: nil),
              let url = (e.allObjects as? [URL])?.first(where: { $0.lastPathComponent.hasSuffix("\(sid).jsonl") }),
              let fh = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? fh.close() }
        _ = forEachLine(fh, from: 0) { line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["type"] as? String == "event_msg",
                  let p = o["payload"] as? [String: Any], p["type"] as? String == "item_completed",
                  let it = p["item"] as? [String: Any], let id = it["id"] as? String else { return }
            func texts(_ v: Any?) -> String {
                ((v as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            switch it["type"] as? String {
            case "UserMessage":
                let t = texts(it["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { items.append(ChatItem(id: id, kind: .user(t))) }
            case "AgentMessage":
                let t = texts(it["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { items.append(ChatItem(id: id, kind: .text(t))) }
            case "CommandExecution":
                let cmd = (it["command"] as? [String])?.last ?? it["command"] as? String ?? ""
                var item = ChatItem(id: id, kind: .tool(id: id, name: "Bash", summary: cmd))
                item.output = it["aggregated_output"] as? String ?? "done"
                item.isError = (it["exit_code"] as? Int).map { $0 != 0 } ?? false
                items.append(item)
            case "FileChange":
                let paths = ((it["changes"] as? [String: Any]) ?? [:]).keys.map { Self.rel($0, cwd) }
                var item = ChatItem(id: id, kind: .tool(id: id, name: "Edit", summary: paths.sorted().joined(separator: ", ")))
                item.output = it["stdout"] as? String ?? "updated"
                items.append(item)
            case "McpToolCall":
                var item = ChatItem(id: id, kind: .tool(id: id, name: "mcp__\(it["server"] as? String ?? "")__\(it["tool"] as? String ?? "")", summary: ""))
                item.output = "done"
                items.append(item)
            default: break
            }
            if items.count > 800 { items.removeFirst(items.count - 400) }
        }
        if items.count > 400 { items = Array(items.suffix(400)) }
    }
}

/// Reads an agy conversation's steps for history: each step's protobuf payload holds its text and, for tools,
/// the tool name and its JSON parameters, as plain strings.
enum AgyHistory {
    struct Step {
        let idx: Int
        let type: Int
        let strings: [String]
        var longestText: String? {
            // the message: the longest string that reads like prose, not an id
            strings.filter { $0.contains(" ") || $0.count > 40 }
                .filter { !$0.hasPrefix("{") && $0.range(of: #"^[0-9a-f-]{20,}$"#, options: .regularExpression) == nil }
                .max { $0.count < $1.count }
        }
        var toolName: String? {
            strings.first { $0.range(of: #"^[a-z][a-z_]{2,40}$"#, options: .regularExpression) != nil && $0.contains("_") }
        }
        var toolParams: [String: Any] {
            for s in strings where s.hasPrefix("{") {
                if let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { return o }
            }
            return [:]
        }
    }

    /// The conversation's messages, from its newest model call (agy records each call's whole conversation:
    /// protobuf field 1 → 2 → 3 holds the turns in order; yours are wrapped in <USER_REQUEST>).
    static func messages(_ path: String) -> [(user: Bool, text: String)] {
        guard let blob = blob(path, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 1") else { return [] }
        return protoStrings(blob, at: [1, 2, 3]).compactMap { s in
            if let r = s.range(of: "<USER_REQUEST>"), let e = s.range(of: "</USER_REQUEST>", range: r.upperBound..<s.endIndex) {
                return (true, String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.hasPrefix("<") ? nil : (false, t)   // skip the tool results and metadata it inserts
        }
    }

    /// The conversation's last reply.
    static func lastReply(_ path: String) -> String? { messages(path).last { !$0.user }?.text }

    private static func blob(_ path: String, _ sql: String) -> Data? {
        let live = FileManager.default.fileExists(atPath: path + "-shm")
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (live ? "?mode=ro" : "?mode=ro&immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
    }

    /// The string fields at a path of field numbers (every occurrence, in order).
    static func protoStrings(_ d: Data, at path: [Int]) -> [String] {
        guard let first = path.first else { return [] }
        var out: [String] = []
        let b = [UInt8](d)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let c = b[i]; i += 1
                v |= UInt64(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            switch key & 7 {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return out }
                let sub = Data(b[i..<(i + Int(n))])
                i += Int(n)
                guard Int(key >> 3) == first else { continue }
                if path.count == 1 { if let s = String(data: sub, encoding: .utf8) { out.append(s) } }
                else { out += protoStrings(sub, at: Array(path.dropFirst())) }
            default: return out
            }
        }
        return out
    }

    static func steps(_ path: String, where clause: String = "1 ORDER BY idx") -> [Step] {
        let live = FileManager.default.fileExists(atPath: path + "-shm")
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (live ? "?mode=ro" : "?mode=ro&immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT idx, step_type, step_payload FROM steps WHERE " + clause, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [Step] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int(st, 0)), type = Int(sqlite3_column_int(st, 1))
            var strings: [String] = []
            if let p = sqlite3_column_blob(st, 2) {
                strings = protoStrings(Data(bytes: p, count: Int(sqlite3_column_bytes(st, 2))))
            }
            out.append(Step(idx: idx, type: type, strings: strings))
        }
        return out
    }

    /// Every length-delimited field of a protobuf message (recursively) that is valid, printable UTF-8.
    static func protoStrings(_ d: Data, depth: Int = 0) -> [String] {
        var out: [String] = []
        let b = [UInt8](d)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let c = b[i]; i += 1
                v |= UInt64(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            switch key & 7 {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return out }
                let sub = Data(b[i..<(i + Int(n))])
                i += Int(n)
                if let s = String(data: sub, encoding: .utf8), !s.isEmpty,
                   s.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }) {
                    out.append(s)
                } else if depth < 8 {
                    out += protoStrings(sub, depth: depth + 1)
                }
            default: return out
            }
        }
        return out
    }
}
