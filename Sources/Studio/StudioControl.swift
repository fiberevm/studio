import AppKit
import Network
import WebKit

/// Lets an AI drive the editor. Studio listens on 127.0.0.1 (random port, random token, both in a 0600 file);
/// the bundled `studio-mcp` binary — injected into every Claude session via --mcp-config — forwards MCP tool
/// calls here as one JSON line per request: {"token","tab","method","params"} → {"ok","result"|"error"}.
@MainActor
final class StudioControl {
    static let shared = StudioControl()

    static let supportDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Studio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// Per app build (bundle id), so a second copy of Studio never overwrites another's control file.
    nonisolated static var controlFilePath: String { supportDirPath + "/control-\(bundleKey).json" }
    nonisolated static var bundleKey: String { Bundle.main.bundleIdentifier ?? "dev" }
    nonisolated static let supportDirPath: String =
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path as NSString)
            .appendingPathComponent("Studio")

    /// Path of the MCP config handed to `claude --mcp-config`, if the studio-mcp binary is available.
    nonisolated(unsafe) static var mcpConfigPath: String?
    /// The studio-mcp binary (Codex takes it as `-c mcp_servers.studio.command=…`).
    nonisolated(unsafe) static var mcpExecutable: String?
    /// Studio's Claude plugin (Studio + Sandbox skills) bundled in the app, if present.
    static let pluginDir: String? = {
        guard let r = Bundle.main.resourcePath else { return nil }
        let p = r + "/StudioPlugin"
        return FileManager.default.fileExists(atPath: p + "/.claude-plugin/plugin.json") ? p : nil
    }()

    private let token = UUID().uuidString
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "studio.control")
    private weak var store: SessionStore?
    private var windows: [UUID: WeakModel] = [:]
    private weak var lastActive: ProjectModel?
    /// Set by a window so the AI can open project windows.
    var openWindow: ((String) -> Void)?

    private struct WeakModel { weak var model: ProjectModel? }

    // MARK: Setup

    func start(store: SessionStore) {
        guard listener == nil else { return }
        self.store = store
        writeMCPConfig()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = l.port?.rawValue {
                    Task { @MainActor in self?.writeControlFile(port: port) }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            debugLog("control server failed: \(error)")
        }
    }

    private func writeControlFile(port: UInt16) {
        let info: [String: Any] = ["port": Int(port), "token": token, "pid": Int(getpid())]
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
        let url = URL(fileURLWithPath: Self.controlFilePath)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? data.write(to: url)
    }

    private func writeMCPConfig() {
        // studio-mcp lives next to the app executable (Contents/MacOS) or, in a dev build, next to the binary.
        let exe = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent } ?? "") + "/studio-mcp"
        guard FileManager.default.isExecutableFile(atPath: exe) else { Self.mcpConfigPath = nil; return }
        Self.mcpExecutable = exe
        let cfg: [String: Any] = ["mcpServers": ["studio": ["type": "stdio", "command": exe, "args": [] as [String]]]]
        let url = Self.supportDir.appendingPathComponent("mcp-\(Self.bundleKey).json")
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) else { return }
        try? data.write(to: url)
        Self.mcpConfigPath = url.path
    }

    // MARK: Windows

    func register(_ m: ProjectModel) { windows[m.windowId] = WeakModel(model: m); lastActive = m }
    func unregister(_ m: ProjectModel) { windows.removeValue(forKey: m.windowId) }
    func noteActive(_ m: ProjectModel) { lastActive = m }
    private var models: [ProjectModel] { windows.values.compactMap(\.model) }

    // MARK: Connection handling

    private nonisolated func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private nonisolated func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf = Data(buf[buf.index(after: nl)...])
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                Task { @MainActor in
                    let reply = await self.handle(request)
                    var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
                    out.append(0x0A)
                    conn.send(content: out, completion: .contentProcessed { _ in })
                }
            }
            if done || error != nil { conn.cancel() } else { self.receive(conn, buffer: buf) }
        }
    }

    private func handle(_ req: [String: Any]) async -> [String: Any] {
        guard req["token"] as? String == token else { return ["ok": false, "error": "bad token"] }
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? [String: Any] ?? [:]
        let tab = (req["tab"] as? String).flatMap(UUID.init(uuidString:))
        do {
            if method.hasPrefix("sandbox_") {
                return ["ok": true, "result": try await sandbox(method, params, callerTab: tab)]
            }
            if method.hasPrefix("web_") {
                return ["ok": true, "result": try await web(method, params, callerTab: tab)]
            }
            return ["ok": true, "result": try dispatch(method, params, callerTab: tab)]
        } catch let e as ControlError {
            return ["ok": false, "error": e.message]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    struct ControlError: Error { let message: String }

    // MARK: Web panels

    /// web_* tools: read and drive a web panel's page (WKWebView) for the agent.
    private func web(_ method: String, _ p: [String: Any], callerTab: UUID?) async throws -> Any {
        guard let store else { throw ControlError(message: "Studio isn't ready") }
        let model = callerTab.flatMap { id in models.first { $0.terminal(id) != nil } } ?? lastActive ?? models.first
        // the named web tab, else the newest web panel in the caller's window
        let tab: TerminalSession
        if let s = p["tab"] as? String, let id = UUID(uuidString: s), let t = store.terminals.first(where: { $0.id == id }), t.isWeb {
            tab = t
        } else if let model, let t = store.terminals.last(where: { t in t.isWeb && model.group(containing: t.id) != nil }) {
            tab = t
        } else {
            throw ControlError(message: "No web panel open: use open_url first.")
        }
        let w = tab.webView
        if w.frame.isEmpty { w.frame = NSRect(x: 0, y: 0, width: 1280, height: 860) }   // never shown yet

        func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
            do {
                return try await w.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
            } catch {
                throw ControlError(message: "page script failed: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)")
            }
        }
        /// JSON-safe copy of whatever the page returned
        func clean(_ v: Any?) -> Any {
            guard let v, !(v is NSNull) else { return NSNull() }
            if JSONSerialization.isValidJSONObject(["v": v]) { return v }
            return "\(v)"
        }
        // shared helper: resolve {ref | selector | text} to an element
        let find = """
        const pick = (ref, selector, text) => {
          if (ref !== undefined && ref !== null) return document.querySelector(`[data-studio-ref="${ref}"]`);
          if (selector) return document.querySelector(selector);
          if (text) {
            const t = text.toLowerCase();
            const all = [...document.querySelectorAll('a,button,input,textarea,select,label,summary,[role=button],[role=link],[role=tab],[onclick]')];
            return all.find(e => (e.innerText || e.value || e.getAttribute('aria-label') || '').toLowerCase().includes(t)) || null;
          }
          return null;
        };
        """
        let target: [String: Any] = ["ref": p["ref"] ?? NSNull(), "selector": p["selector"] ?? NSNull(), "text": p["text"] ?? NSNull()]

        switch method {
        case "web_read":
            let max = p["max_chars"] as? Int ?? 6000
            let r = try await js("""
            const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; };
            const els = [...document.querySelectorAll('a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[contenteditable=true]')].filter(vis).slice(0, 200);
            els.forEach((e, i) => e.setAttribute('data-studio-ref', i));
            return { url: location.href, title: document.title,
              text: (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, max),
              elements: els.map((e, i) => ({ ref: i, tag: e.tagName.toLowerCase(),
                text: (e.innerText || e.value || e.placeholder || e.getAttribute('aria-label') || e.title || '').trim().replace(/\\s+/g, ' ').slice(0, 80),
                href: e.href || undefined, type: e.type || undefined })) };
            """, ["max": max])
            return clean(r)

        case "web_click":
            let r = try await js(find + """
            const e = pick(ref, selector, text);
            if (!e) return { ok: false, error: 'no matching element' };
            e.scrollIntoView({ block: 'center' });
            e.focus && e.focus();
            e.click();
            return { ok: true, clicked: (e.innerText || e.value || e.tagName).trim().slice(0, 80) };
            """, target)
            try? await Task.sleep(nanoseconds: 600_000_000)   // let navigation/rendering start
            var out = clean(r) as? [String: Any] ?? [:]
            out["url"] = w.url?.absoluteString
            return out

        case "web_type":
            guard let value = p["value"] as? String else { throw ControlError(message: "value is required") }
            var args = target
            args["value"] = value
            args["submit"] = p["submit"] as? Bool ?? false
            args["clear"] = p["clear"] as? Bool ?? true
            let r = try await js(find + """
            const e = pick(ref, selector, text) || document.activeElement;
            if (!e) return { ok: false, error: 'no matching element' };
            e.scrollIntoView({ block: 'center' }); e.focus();
            if (e.isContentEditable) { e.textContent = clear ? value : e.textContent + value; }
            else {
              const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
                          : e instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
              const set = Object.getOwnPropertyDescriptor(proto, 'value').set;   // React-friendly
              set.call(e, clear ? value : (e.value || '') + value);
            }
            e.dispatchEvent(new Event('input', { bubbles: true }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
            if (submit) {
              if (e.form && e.form.requestSubmit) e.form.requestSubmit();
              else ['keydown', 'keypress', 'keyup'].forEach(t => e.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true })));
            }
            return { ok: true };
            """, args)
            if p["submit"] as? Bool == true { try? await Task.sleep(nanoseconds: 800_000_000) }
            var out = clean(r) as? [String: Any] ?? [:]
            out["url"] = w.url?.absoluteString
            return out

        case "web_wait":
            let timeout = Double(p["timeout"] as? Int ?? 10)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let found = try await js(find + "return !!pick(ref, selector, text) || (text ? document.body.innerText.toLowerCase().includes(text.toLowerCase()) : false);", target)
                if found as? Bool == true { return ["ok": true, "url": w.url?.absoluteString ?? ""] }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return ["ok": false, "error": "timed out after \(Int(timeout))s"]

        case "web_nav":
            switch p["action"] as? String {
            case "back": w.goBack()
            case "forward": w.goForward()
            default: w.reload()
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            return ["url": w.url?.absoluteString ?? "", "title": w.title ?? ""]

        case "web_eval":
            guard let code = p["script"] as? String else { throw ControlError(message: "script is required") }
            return ["result": clean(try await js(code))]

        case "web_screenshot":
            let cfg = WKSnapshotConfiguration()
            let image: NSImage = try await withCheckedThrowingContinuation { cont in
                w.takeSnapshot(with: cfg) { img, err in
                    if let img { cont.resume(returning: img) } else { cont.resume(throwing: err ?? ControlError(message: "snapshot failed")) }
                }
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { throw ControlError(message: "couldn't encode the snapshot") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StudioWeb")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("web-\(tab.id.uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970)).png")
            try png.write(to: file)
            return ["path": file.path, "url": w.url?.absoluteString ?? "", "note": "Read this PNG to see the page."]

        default:
            throw ControlError(message: "unknown method \(method)")
        }
    }

    // MARK: Sandboxes

    /// sandbox_* tools. They run the provider's CLI off the main thread, and record which sandboxes the
    /// calling session uses so its status bar can show them.
    private func sandbox(_ method: String, _ p: [String: Any], callerTab: UUID?) async throws -> Any {
        guard let store else { throw ControlError(message: "Studio isn't ready") }
        let reg = store.sandboxes
        guard !reg.available.isEmpty else {
            throw ControlError(message: "No sandbox provider is set up: install and sign in to the boat CLI (https://boat.dev), or set up AWS Lambda MicroVMs in Settings (⌘, → Sandboxes).")
        }
        let policy = Pref.string(Pref.sandboxPolicy) ?? "auto"   // default: use sandboxes when helpful
        let model = callerTab.flatMap { id in models.first { $0.terminal(id) != nil } } ?? lastActive ?? models.first
        let me = callerTab.flatMap { id in store.terminals.first { $0.id == id } }

        /// The sandbox to act on: the one named, else this session's most recent.
        func target() throws -> String {
            if let id = p["id"] as? String, !id.isEmpty { return id }
            if let me, let last = reg.ids(for: me).last { return last }
            throw ControlError(message: "No sandbox given and this session has none yet (sandbox_list / sandbox_create).")
        }
        func use(_ id: String) { if let me { reg.attach(id, to: me) } }

        do {
            switch method {
            case "sandbox_list":
                var all: [SandboxInfo] = []
                for prov in reg.available { all += try await prov.list() }
                all.forEach(reg.note)
                let mine = me.map { reg.ids(for: $0) } ?? []
                func row(_ s: SandboxInfo) -> [String: Any] { ["id": s.id, "name": s.name ?? "", "state": s.state, "type": s.type ?? "", "provider": s.provider] }
                var out: [String: Any] = ["providers": reg.available.map(\.id), "default_provider": reg.provider.id,
                                          "policy": policy == "auto"
                                            ? "auto: you may create a sandbox when it helps; stop it when done"
                                            : "ask: use this session's sandboxes; create one only when the user asks",
                                          "this_session": all.filter { mine.contains($0.id) }.map(row)]
                if p["scope"] as? String == "all" { out["all"] = all.map(row) }
                return out

            case "sandbox_create":
                // Settings → Sandboxes supplies the defaults
                let ttlPref = UserDefaults.standard.object(forKey: Pref.sandboxTTL) as? Int ?? 60
                let provider = reg.provider(named: p["provider"] as? String).flatMap { reg.usable($0) ? $0 : nil } ?? reg.provider
                let s = try await provider.create(type: p["type"] as? String ?? Pref.string(Pref.sandboxType) ?? "small",
                                                  ttlMinutes: p["ttl_minutes"] as? Int ?? (ttlPref > 0 ? ttlPref : nil),
                                                  environment: p["environment"] as? String ?? Pref.string(Pref.sandboxEnvironment))
                reg.note(s)
                use(s.id)
                var out: [String: Any] = ["id": s.id, "state": s.state]
                if p["push"] as? Bool ?? true, let dir = me?.cwd ?? model?.folder {
                    out["pushed"] = try await provider.push(s.id, dir: dir, to: nil)
                    out["workdir"] = "/home/user/" + (dir as NSString).lastPathComponent
                }
                return out

            case "sandbox_exec":
                guard let cmd = p["command"] as? String, !cmd.isEmpty else { throw ControlError(message: "command is required") }
                let id = try target(); use(id)
                return try await reg.provider(for: id).exec(id, command: cmd, cwd: p["cwd"] as? String,
                                               timeout: p["timeout"] as? Int ?? 120, background: p["background"] as? Bool ?? false)

            case "sandbox_push":
                let id = try target(); use(id)
                guard let dir = (p["dir"] as? String).map({ ($0 as NSString).expandingTildeInPath }) ?? me?.cwd ?? model?.folder
                else { throw ControlError(message: "dir is required") }
                return try await reg.provider(for: id).push(id, dir: dir, to: p["to"] as? String)

            case "sandbox_url":
                guard let port = p["port"] as? Int else { throw ControlError(message: "port is required") }
                let id = try target(); use(id)
                return try await reg.provider(for: id).url(id, port: port, isPublic: p["public"] as? Bool ?? false)

            case "sandbox_terminal":
                let id = try target(); use(id)
                guard let model else { throw ControlError(message: "no Studio window is open") }
                let t = store.newShell(in: me?.cwd ?? model.folder)
                let g = me.flatMap { model.group(containing: $0.id) } ?? model.activeGroup
                model.place(t, beside: g, zone: .right)
                let ssh = reg.provider(for: id).sshCommand(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { t.type(ssh + "\r") }
                return ["tab": t.id.uuidString]

            case "sandbox_attach":
                let id = try target(); use(id); return "attached \(id)"
            case "sandbox_detach":
                let id = try target(); if let me { reg.detach(id, from: me) }; return "detached \(id)"
            case "sandbox_stop":
                let id = try target(); return try await reg.provider(for: id).stop(id)
            case "sandbox_resume":
                let id = try target(); use(id); return try await reg.provider(for: id).resume(id)
            case "sandbox_delete":
                let id = try target()
                let r = try await reg.provider(for: id).delete(id)
                reg.forget(id)
                return r
            default:
                throw ControlError(message: "unknown method \(method)")
            }
        } catch let e as SandboxError {
            throw ControlError(message: e.message)
        }
    }

    // MARK: Commands

    private func dispatch(_ method: String, _ p: [String: Any], callerTab: UUID?) throws -> Any {
        guard let store else { throw ControlError(message: "Studio isn't ready") }
        let caller = callerTab.flatMap { id in models.first { $0.group(containing: id) != nil || $0.tabs.contains { $0.id == id } } }
        guard let model = caller ?? lastActive ?? models.first else { throw ControlError(message: "no Studio window is open") }
        let callerGroup = callerTab.flatMap { model.group(containing: $0) } ?? model.activeGroup

        func tab(_ key: String = "tab", defaultToCaller: Bool = true) throws -> TerminalSession {
            if let s = p[key] as? String, let id = UUID(uuidString: s), let t = model.terminal(id) { return t }
            if defaultToCaller, let id = callerTab, let t = model.terminal(id) { return t }
            throw ControlError(message: "unknown tab — call get_state for tab ids")
        }
        func zone(_ key: String) throws -> DropZone? {
            guard let s = p[key] as? String else { return nil }
            switch s.lowercased() {
            case "right": return .right
            case "left": return .left
            case "down", "bottom": return .bottom
            case "up", "top": return .top
            case "center", "here", "tab": return .center
            default: throw ControlError(message: "\(key) must be right, left, up, down or center")
            }
        }

        switch method {
        case "get_state":
            return state(store: store, focus: model, callerTab: callerTab)

        case "list_themes":
            return AppTheme.all.map { ["id": $0.id, "name": $0.name, "light": $0.isLight, "current": $0 == Theme.current] }

        case "set_theme":
            let q = (p["theme"] as? String ?? "").lowercased()
            guard let t = AppTheme.all.first(where: { $0.id == q || $0.name.lowercased() == q })
                    ?? AppTheme.all.first(where: { $0.name.lowercased().contains(q) && !q.isEmpty })
            else { throw ControlError(message: "unknown theme; options: " + AppTheme.all.map(\.id).joined(separator: ", ")) }
            store.setTheme(t)
            return "theme set to \(t.name)"

        case "set_font_size":
            guard let size = (p["size"] as? NSNumber)?.doubleValue, (8...28).contains(size) else {
                throw ControlError(message: "size must be 8–28")
            }
            store.fontSize = CGFloat(size)
            return "font size \(Int(size))"

        case "new_session":
            let folder = (p["folder"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? model.folder
            let t = store.newSession(in: folder, prompt: p["prompt"] as? String,
                                     agent: (p["agent"] as? String).flatMap(Agent.init(rawValue:)))
            model.place(t, beside: callerGroup, zone: try zone("split"))
            return ["tab": t.id.uuidString]

        case "new_terminal":
            let folder = (p["folder"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? model.folder
            let t = store.newShell(in: folder)
            model.place(t, beside: callerGroup, zone: try zone("split"))
            if let cmd = p["command"] as? String, !cmd.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { t.type(cmd + "\r") }
            }
            return ["tab": t.id.uuidString]

        case "run_in_terminal":
            let t = try tab(defaultToCaller: false)
            guard t.isShell else { throw ControlError(message: "run_in_terminal only works on plain terminal tabs, not Claude sessions") }
            guard let cmd = p["command"] as? String, !cmd.isEmpty else { throw ControlError(message: "command is required") }
            t.type(cmd + ((p["press_enter"] as? Bool ?? true) ? "\r" : ""))
            return "sent"

        case "open_url":
            guard let s = p["url"] as? String, let url = URL(string: s.contains("://") ? s : "https://" + s)
            else { throw ControlError(message: "url is required") }
            // navigate an existing web tab, or open a new web panel (split beside the caller by default)
            if let id = (p["tab"] as? String).flatMap(UUID.init(uuidString:)), let t = model.terminal(id), t.isWeb {
                t.navigate(url)
                model.select(t)
                return ["tab": t.id.uuidString]
            }
            let t = model.openWeb(url, beside: callerGroup, zone: try zone("split") ?? .right)
            return ["tab": t.id.uuidString]

        case "send_to_session":
            let t = try tab(defaultToCaller: false)
            guard t.isClaude else { throw ControlError(message: "send_to_session is for Claude sessions; use run_in_terminal for terminals") }
            guard let text = p["text"] as? String, !text.isEmpty else { throw ControlError(message: "text is required") }
            t.submit(text)
            return "sent"

        case "set_view":
            let t = try tab()
            guard t.isClaude else { throw ControlError(message: "terminals have no native view") }
            guard t.sessionId != nil else { throw ControlError(message: "the session needs a first message before switching views") }
            let wantNative = (p["view"] as? String ?? "native") == "native"
            if wantNative != t.isNative { t.toggleNative() }
            return wantNative ? "switching to native view" : "switching to terminal view"

        case "fork_session":
            let t = try tab()
            guard t.isClaude, let sid = t.sessionId else { throw ControlError(message: "that tab isn't a Claude session with a conversation yet") }
            let f = store.fork(sid, cwd: t.cwd)
            model.place(f, beside: model.group(containing: t.id) ?? callerGroup, zone: try zone("split") ?? .right)
            return ["tab": f.id.uuidString]

        case "split_tab":
            let t = try tab()
            guard let z = try zone("direction"), z != .center else { throw ControlError(message: "direction must be right, left, up or down") }
            model.split(t, z)
            return "split \(p["direction"] ?? "")"

        case "move_tab":
            let t = try tab()
            guard let gs = p["to_group"] as? String, let gid = UUID(uuidString: gs),
                  let g = model.groups.first(where: { $0.id == gid }) else { throw ControlError(message: "unknown to_group") }
            model.move(t.id, to: g, zone: try zone("zone") ?? .center)
            return "moved"

        case "focus_tab":
            let t = try tab(defaultToCaller: false)
            model.select(t)
            model.focusTerminal()
            return "focused"

        case "close_tab":
            let t = try tab(defaultToCaller: false)
            let keep = (p["keep_running"] as? Bool == true || !Pref.bool(Pref.closeTabEndsSession, default: true)) && t.isClaude
            if keep { model.closeKeepingRunning(t) } else { model.endSession(t) }
            return keep ? "tab closed (session keeps running)" : "tab closed (session ended)"

        case "resize_pane":
            let g = try group(p, model, fallback: callerGroup)
            guard let share = (p["size"] as? NSNumber)?.doubleValue, share > 0, share < 1 else {
                throw ControlError(message: "size is the pane's share of its split, between 0 and 1 (e.g. 0.7)")
            }
            guard model.resize(g, share: CGFloat(share)) else { throw ControlError(message: "that pane isn't in a split") }
            return "resized"

        case "set_split_sizes":
            guard let sid = p["split"] as? String, let id = UUID(uuidString: sid), let box = model.split(byId: id) else {
                throw ControlError(message: "unknown split — get_state lists split ids")
            }
            guard let sizes = (p["sizes"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), sizes.count == box.children.count else {
                throw ControlError(message: "sizes needs \(box.children.count) numbers (relative; they're normalized)")
            }
            model.setSizes(box, sizes)
            return "sizes set"

        case "equalize_layout":
            model.equalize()
            return "all splits equalized"

        case "set_layout":
            guard let name = p["preset"] as? String, let preset = ProjectModel.Preset(rawValue: name) else {
                throw ControlError(message: "preset must be single, columns, rows or grid")
            }
            model.applyPreset(preset, panes: (p["panes"] as? NSNumber)?.intValue ?? 2)
            return "layout: \(name)"

        case "merge_pane":
            let g = try group(p, model, fallback: callerGroup)
            guard model.groups.count > 1 else { throw ControlError(message: "there's only one pane") }
            model.merge(g)
            return "merged"

        case "focus_pane":
            model.focus(try group(p, model, fallback: nil))
            return "focused"

        case "reorder_tab":
            let t = try tab()
            guard let i = (p["index"] as? NSNumber)?.intValue else { throw ControlError(message: "index is required (0 = first)") }
            model.reorder(t, to: i)
            return "moved to position \(i)"

        case "set_sidebar":
            if let v = p["visible"] as? Bool { model.sidebarVisible = v }
            if let w = (p["width"] as? NSNumber)?.doubleValue { model.sidebarWidth = CGFloat(min(max(w, 160), 520)) }
            return ["visible": model.sidebarVisible, "width": Int(model.sidebarWidth)]

                case "open_palette":
            model.palette = p["text"] as? String ?? ""
            return "palette open"

        case "open_project":
            guard let f = p["folder"] as? String else { throw ControlError(message: "folder is required") }
            let path = (f as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw ControlError(message: "no such folder") }
            guard let open = openWindow else { throw ControlError(message: "can't open windows right now") }
            open(path)
            return "opened \(path)"

        default:
            throw ControlError(message: "unknown method \(method)")
        }
    }

    private func group(_ p: [String: Any], _ m: ProjectModel, fallback: GroupNode?) throws -> GroupNode {
        if let s = p["group"] as? String, let id = UUID(uuidString: s), let g = m.groups.first(where: { $0.id == id }) { return g }
        if let s = p["tab"] as? String, let id = UUID(uuidString: s), let g = m.group(containing: id) { return g }
        if let fallback { return fallback }
        throw ControlError(message: "unknown group — get_state lists group ids")
    }

    private func state(store: SessionStore, focus: ProjectModel, callerTab: UUID?) -> [String: Any] {
        func describe(_ m: ProjectModel) -> [String: Any] {
            func layout(_ n: LayoutNode) -> [String: Any] {
                switch n {
                case .group(let g):
                    return [
                        "group": g.id.uuidString,
                        "active": g.id == m.activeGroupId,
                        "tabs": m.tabs(in: g).map { t -> [String: Any] in
                            let item = m.item(for: t)
                            var d: [String: Any] = [
                                "tab": t.id.uuidString,
                                "kind": t.isWeb ? "web" : t.isShell ? "terminal" : t.isCodex ? "codex" : "claude",
                                "title": t.isWeb ? (t.webTitle.isEmpty ? (t.url?.absoluteString ?? "web") : t.webTitle) : t.isCodex ? (t.terminalTitle.isEmpty ? "Codex" : t.terminalTitle) : t.isShell ? (t.terminalTitle.isEmpty ? "terminal" : t.terminalTitle) : (item?.title ?? "New session"),
                                "selected": g.selection == "t:\(t.id)",
                                "running": t.running,
                            ]
                            if let s = item?.status.label { d["status"] = s }
                            if let sid = t.sessionId { d["session_id"] = sid }
                            if t.id == callerTab { d["is_you"] = true }
                            return d
                        },
                    ]
                case .split(let box):
                    return ["split": box.axis == .horizontal ? "side-by-side" : "stacked",
                            "split_id": box.id.uuidString,
                            "sizes": box.fractions.map { Double(($0 * 100).rounded()) / 100 },
                            "children": box.children.map(layout)]
                }
            }
            return [
                "project": m.folder,
                "focused": m === focus,
                "sidebar": ["visible": m.sidebarVisible, "width": Int(m.sidebarWidth)],
                "layout": layout(m.root),
                "sessions_in_sidebar": m.items.map { ["title": $0.title, "status": $0.status.label, "in_studio": $0.inApp] },
            ]
        }
        return [
            "theme": Theme.current.id,
            "themes": AppTheme.all.map(\.id),
            "font_size": Int(store.fontSize),
            "windows": models.map(describe),
        ]
    }
}
