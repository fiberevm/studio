import Foundation

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
    var pid: Int32 { process?.processIdentifier ?? 0 }
    var onSessionId: ((String) -> Void)?

    init(cwd: String, tab: UUID, resume sid: String?) {
        self.cwd = cwd
        self.tab = tab
        self.sessionId = sid
        if let sid { loadHistory(sid) }
        start(resume: sid, mode: lastMode)
    }

    // MARK: Process

    /// The permission mode the session last ran in (from its transcript), so native mode behaves the same.
    private var lastMode: String?

    private func start(resume sid: String?, mode: String?) {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        if let mode { args += ["--permission-mode", mode] }
        if let sid { args += ["--resume", sid] }
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
        write(["type": "user", "message": ["role": "user", "content": t]])
        busy = true
        turnStartedAt = Date()
    }

    /// Supervised (ask), auto-accept edits, or full access — changes the running session's permission mode.
    func setPermissionMode(_ mode: String) {
        permissionMode = mode
        write(["type": "control_request", "request_id": UUID().uuidString,
               "request": ["subtype": "set_permission_mode", "mode": mode]])
    }

    func interrupt() {
        guard busy else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func answer(_ item: ChatItem, allow: Bool) {
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
            handle(obj)
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
    }

    private func note(_ s: String) { items.append(ChatItem(id: UUID().uuidString, kind: .note(s))) }

    // MARK: History

    /// Show the conversation so far from its transcript, so switching modes keeps the context on screen.
    private func loadHistory(_ sid: String) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.projects.path) else { return }
        for d in dirs {
            let path = Paths.projects.appendingPathComponent(d).appendingPathComponent("\(sid).jsonl").path
            guard let data = fm.contents(atPath: path) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true else { continue }
                if o["type"] as? String == "permission-mode", let m = o["permissionMode"] as? String { lastMode = m; continue }
                guard let msg = o["message"] as? [String: Any] else { continue }
                switch o["type"] as? String {
                case "user":
                    if let s = msg["content"] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") {
                            items.append(ChatItem(id: o["uuid"] as? String ?? UUID().uuidString, kind: .user(t)))
                        }
                    } else if let blocks = msg["content"] as? [[String: Any]] {
                        for b in blocks {
                            if b["type"] as? String == "tool_result" { attachResult(b) }
                            else if b["type"] as? String == "text", let t = b["text"] as? String, !t.hasPrefix("<") {
                                items.append(ChatItem(id: UUID().uuidString, kind: .user(t)))
                            }
                        }
                    }
                case "assistant":
                    let mid = msg["id"] as? String ?? UUID().uuidString
                    for (n, b) in (msg["content"] as? [[String: Any]] ?? []).enumerated() { addAssistantBlock(b, id: "\(mid)#\(n)") }
                default: break
                }
            }
            break
        }
        // keep the view light: the last 400 entries are plenty of context
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
