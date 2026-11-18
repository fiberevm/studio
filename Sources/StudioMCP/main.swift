import Foundation

// studio-mcp: a stdio MCP server that lets the Claude session it runs in drive the Studio editor.
// Studio launches every session with `--mcp-config <this>` and sets STUDIO_TAB (the session's tab) and
// STUDIO_CONTROL_FILE (port + token of the app's local control server). Each tool call becomes one JSON
// line to that server.

setvbuf(stdout, nil, _IOLBF, 0)

struct Tool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]
}

let direction: [String: Any] = ["type": "string", "enum": ["right", "left", "up", "down"]]
let tools: [Tool] = [
    Tool(name: "get_state",
         description: "Describe Studio: windows (one per project folder), their split layout (splits with split_id and sizes, groups with group ids), each tab (id, kind claude|terminal, title, status, which one is you), the sessions in the sidebar, the theme and font size. Call this first to get tab and group ids.",
         properties: [:], required: []),
    Tool(name: "list_themes", description: "List the available color themes.", properties: [:], required: []),
    Tool(name: "set_theme",
         description: "Change the color theme of the whole app and all terminals (e.g. dark-modern, dark-plus, light-plus, monokai, solarized-dark, one-dark-pro, github-dark, dracula, clear-dark).",
         properties: ["theme": ["type": "string", "description": "theme id or name"]], required: ["theme"]),
    Tool(name: "set_font_size", description: "Set the terminal font size (8–28 pt).",
         properties: ["size": ["type": "number"]], required: ["size"]),
    Tool(name: "new_session",
         description: "Start a new Claude Code session in a tab. By default it opens beside you in your group; pass split to open it in a new pane on that side. Optionally give it a first prompt.",
         properties: ["prompt": ["type": "string", "description": "first message for the new session"],
                      "split": direction,
                      "folder": ["type": "string", "description": "working directory (default: this project)"]],
         required: []),
    Tool(name: "new_terminal",
         description: "Open a plain shell tab (no Claude), optionally in a new split pane, optionally running a command (e.g. a dev server or tests) so the user can watch it.",
         properties: ["command": ["type": "string"], "split": direction,
                      "folder": ["type": "string", "description": "working directory (default: this project)"]],
         required: []),
    Tool(name: "run_in_terminal",
         description: "Type a command into an existing plain terminal tab (not a Claude session).",
         properties: ["tab": ["type": "string"], "command": ["type": "string"],
                      "press_enter": ["type": "boolean", "description": "default true"]],
         required: ["tab", "command"]),
    Tool(name: "open_url",
         description: "Open a web page in a Studio web panel for the user to see (split beside you by default; split=center opens it as a tab). Use for local dev servers (http://localhost:3000), sandbox URLs, docs, PRs. Pass tab to navigate an existing web panel instead.",
         properties: ["url": ["type": "string"], "split": ["type": "string", "enum": ["right", "left", "up", "down", "center"]],
                      "tab": ["type": "string", "description": "an existing web tab to navigate"]],
         required: ["url"]),
    // Web panels (after open_url). tab defaults to the newest web panel in this window.
    Tool(name: "web_read",
         description: "Read a web panel: URL, title, visible text, and numbered interactive elements (ref) for web_click / web_type.",
         properties: ["tab": ["type": "string"], "max_chars": ["type": "integer", "description": "text limit, default 6000"]], required: []),
    Tool(name: "web_click",
         description: "Click an element in a web panel by ref (from web_read), CSS selector, or visible text.",
         properties: ["tab": ["type": "string"], "ref": ["type": "integer"], "selector": ["type": "string"], "text": ["type": "string"]], required: []),
    Tool(name: "web_type",
         description: "Type into an input/textarea/contenteditable (by ref, selector or text label); clear replaces (default true); submit presses Enter / submits the form.",
         properties: ["tab": ["type": "string"], "ref": ["type": "integer"], "selector": ["type": "string"], "text": ["type": "string"],
                      "value": ["type": "string"], "submit": ["type": "boolean"], "clear": ["type": "boolean"]],
         required: ["value"]),
    Tool(name: "web_wait",
         description: "Wait until an element (ref/selector) or some text appears in a web panel. timeout in seconds, default 10.",
         properties: ["tab": ["type": "string"], "selector": ["type": "string"], "text": ["type": "string"], "timeout": ["type": "integer"]], required: []),
    Tool(name: "web_nav", description: "Back, forward or reload a web panel.",
         properties: ["tab": ["type": "string"], "action": ["type": "string", "enum": ["back", "forward", "reload"]]], required: ["action"]),
    Tool(name: "web_screenshot", description: "Snapshot a web panel to a PNG file and return its path (Read it to see the page).",
         properties: ["tab": ["type": "string"]], required: []),
    Tool(name: "web_eval", description: "Run JavaScript in a web panel's page (async function body; use return). For anything the other web_* tools don't cover.",
         properties: ["tab": ["type": "string"], "script": ["type": "string"]], required: ["script"]),
    Tool(name: "send_to_session",
         description: "Send a message to another Claude session's prompt (as if the user typed it and pressed Return). Use get_state for tab ids. Use sparingly: it starts real work in that session.",
         properties: ["tab": ["type": "string"], "text": ["type": "string"]],
         required: ["tab", "text"]),
    // Sandboxes (boat.dev). Default policy: use them when helpful; delete only when the user asks.
    Tool(name: "sandbox_list",
         description: "List this session's sandboxes (and every account sandbox with scope=all). Check this before creating one.",
         properties: ["scope": ["type": "string", "enum": ["session", "all"]]], required: []),
    Tool(name: "sandbox_create",
         description: "Create a remote sandbox (Linux VM) for this session and push the project into it (/home/user/<project>). Follow the policy from sandbox_list (default: create one when it helps — builds, tests, servers, risky or long work). Stop it when done. Returns its id.",
         properties: ["provider": ["type": "string", "enum": ["boat", "aws"], "description": "boat (boat.dev) or aws (Lambda MicroVMs); default from Settings"],
                      "type": ["type": "string", "enum": ["small", "default", "large", "xlarge"], "description": "boat machine size"],
                      "ttl_minutes": ["type": "integer", "description": "auto-stop after this many minutes"],
                      "environment": ["type": "string", "description": "named Boat environment (repos, secrets)"],
                      "push": ["type": "boolean", "description": "copy the project in (default true)"]],
         required: []),
    Tool(name: "sandbox_exec",
         description: "Run a shell command in a sandbox (default: this session's latest). Returns stdout/stderr/exit code. Set background=true for servers and long jobs.",
         properties: ["id": ["type": "string"], "command": ["type": "string"],
                      "cwd": ["type": "string", "description": "relative to /home/user"],
                      "timeout": ["type": "integer", "description": "seconds, default 120, 0 = none"],
                      "background": ["type": "boolean"]],
         required: ["command"]),
    Tool(name: "sandbox_push",
         description: "Copy a local directory (default: this project) into the sandbox, git-tracked files only. Re-run after local edits.",
         properties: ["id": ["type": "string"], "dir": ["type": "string"], "to": ["type": "string"]], required: []),
    Tool(name: "sandbox_url",
         description: "Expose a port in the sandbox on an HTTPS URL (token-gated unless public=true).",
         properties: ["id": ["type": "string"], "port": ["type": "integer"], "public": ["type": "boolean"]], required: ["port"]),
    Tool(name: "sandbox_terminal",
         description: "Open a Studio terminal tab with an interactive shell in the sandbox, split beside this session, for the user.",
         properties: ["id": ["type": "string"]], required: []),
    Tool(name: "sandbox_attach", description: "Show an existing sandbox in this session's status bar and make it the default target.",
         properties: ["id": ["type": "string"]], required: ["id"]),
    Tool(name: "sandbox_detach", description: "Stop tracking a sandbox in this session (it keeps running).",
         properties: ["id": ["type": "string"]], required: []),
    Tool(name: "sandbox_stop", description: "Stop a sandbox and snapshot it (resumable). Only when the user asks.",
         properties: ["id": ["type": "string"]], required: []),
    Tool(name: "sandbox_resume", description: "Resume a stopped sandbox.",
         properties: ["id": ["type": "string"]], required: []),
    Tool(name: "sandbox_delete", description: "Permanently delete a sandbox and its data. Only when the user explicitly asks.",
         properties: ["id": ["type": "string"]], required: []),
    Tool(name: "set_view",
         description: "Show a Claude session (default: your own) in Studio's native view (Studio renders the conversation itself, monospace, with inline permission buttons) or in Claude Code's terminal UI. Switching restarts the session's claude process on the same conversation.",
         properties: ["tab": ["type": "string"], "view": ["type": "string", "enum": ["native", "terminal"]]], required: ["view"]),
    Tool(name: "fork_session",
         description: "Fork a Claude session (default: your own) into a new session with the same conversation so far, opened in a split beside it (default right). Useful to try an alternative approach in parallel.",
         properties: ["tab": ["type": "string"], "split": direction], required: []),
    Tool(name: "split_tab",
         description: "Split the editor: move a tab (default: your own) into a new pane on the given side. If it's the only tab in its pane, a new session opens there instead.",
         properties: ["tab": ["type": "string"], "direction": direction], required: ["direction"]),
    Tool(name: "move_tab",
         description: "Move a tab (default: yours) into another group, as a tab (zone center) or splitting that group (right/left/up/down).",
         properties: ["tab": ["type": "string"], "to_group": ["type": "string"],
                      "zone": ["type": "string", "enum": ["center", "right", "left", "up", "down"]]],
         required: ["to_group"]),
    Tool(name: "resize_pane",
         description: "Resize a pane (group) within its split: size is its share of the split, 0–1 (e.g. 0.7 makes it take 70%; siblings share the rest proportionally). Identify it by group id or by a tab in it; default is your own pane.",
         properties: ["group": ["type": "string"], "tab": ["type": "string"], "size": ["type": "number"]],
         required: ["size"]),
    Tool(name: "set_split_sizes",
         description: "Set every child size of one split at once (relative numbers, normalized), e.g. [2,1] for a 2:1 split. get_state gives split ids.",
         properties: ["split": ["type": "string"], "sizes": ["type": "array", "items": ["type": "number"]]],
         required: ["split", "sizes"]),
    Tool(name: "equalize_layout", description: "Make every split's panes equal size.", properties: [:], required: []),
    Tool(name: "set_layout",
         description: "Rearrange all open tabs into a preset: single (one pane), columns or rows (panes = how many, default 2), or grid (2×2). Tabs keep their order.",
         properties: ["preset": ["type": "string", "enum": ["single", "columns", "rows", "grid"]],
                      "panes": ["type": "integer", "minimum": 1, "maximum": 6]],
         required: ["preset"]),
    Tool(name: "merge_pane",
         description: "Close a pane by folding its tabs into the neighbouring pane (sessions keep running). Default: your pane.",
         properties: ["group": ["type": "string"], "tab": ["type": "string"]], required: []),
    Tool(name: "focus_pane", description: "Make a pane the active one (by group id or a tab in it).",
         properties: ["group": ["type": "string"], "tab": ["type": "string"]], required: []),
    Tool(name: "reorder_tab", description: "Move a tab (default: yours) to a position in its pane's tab bar (0 = first).",
         properties: ["tab": ["type": "string"], "index": ["type": "integer", "minimum": 0]], required: ["index"]),
    Tool(name: "set_sidebar", description: "Show/hide the session sidebar and/or set its width (160–520 pt).",
         properties: ["visible": ["type": "boolean"], "width": ["type": "number"]], required: []),
    Tool(name: "focus_tab", description: "Bring a tab to the front and focus it.",
         properties: ["tab": ["type": "string"]], required: ["tab"]),
    Tool(name: "close_tab",
         description: "Close a tab. This ends the session (or terminal) unless keep_running is true; an ended Claude conversation can still be resumed later.",
         properties: ["tab": ["type": "string"], "keep_running": ["type": "boolean", "description": "keep a Claude session running in the background"]],
         required: ["tab"]),
    Tool(name: "open_palette", description: "Open the command palette for the user, optionally pre-filled (start with '>' for commands).",
         properties: ["text": ["type": "string"]], required: []),
    Tool(name: "open_project", description: "Open (or bring forward) the Studio window for a project folder.",
         properties: ["folder": ["type": "string"]], required: ["folder"]),
]

// MARK: Talking to Studio

func callStudio(_ method: String, _ params: [String: Any]) -> (ok: Bool, text: String) {
    let env = ProcessInfo.processInfo.environment
    let file = env["STUDIO_CONTROL_FILE"]
        ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
            + "/Studio/control-dev.local.studio.json")
    guard let data = FileManager.default.contents(atPath: file),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = info["port"] as? Int, let token = info["token"] as? String
    else { return (false, "Studio isn't running (no control file at \(file)).") }

    var req: [String: Any] = ["token": token, "method": method, "params": params]
    if let tab = env["STUDIO_TAB"] { req["tab"] = tab }
    guard var line = try? JSONSerialization.data(withJSONObject: req) else { return (false, "bad request") }
    line.append(0x0A)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return (false, "socket failed") }
    defer { close(fd) }
    // sandbox calls run real remote work (create, exec, push), so they get far longer than UI calls
    var tv = timeval(tv_sec: method.hasPrefix("sandbox_") ? 3700 : method.hasPrefix("web_") ? 120 : 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return (false, "Studio isn't reachable on port \(port); is it running?") }
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }

    var reply = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while !reply.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        reply.append(contentsOf: buf[0..<n])
    }
    guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        return (false, "no reply from Studio")
    }
    if obj["ok"] as? Bool == true {
        let result = obj["result"] ?? "ok"
        if let s = result as? String { return (true, s) }
        let pretty = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(result)"
        return (true, pretty)
    }
    return (false, obj["error"] as? String ?? "error")
}

// MARK: MCP (JSON-RPC 2.0 over stdio, one message per line)

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
    print(s)
}

func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

// MARK: Live updates
//
// Sessions now outlive Studio restarts, so this server can be far older than the app. When Studio's build
// replaces this binary, swap the new one in place (exec keeps stdin/stdout, so the MCP connection survives)
// and tell Claude the tool list changed, so new tools appear in sessions that are already running.

setvbuf(stdin, nil, _IONBF, 0)    // read byte by byte: nothing sits in a buffer that exec would drop
setvbuf(stdout, nil, _IONBF, 0)

let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
func modified(_ p: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
let startedFrom = modified(selfPath)
nonisolated(unsafe) var busy = false

if CommandLine.arguments.contains("--reexec") {
    send(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
}

Thread.detachNewThread {
    while true {
        sleep(5)
        guard !busy, let now = modified(selfPath), let then = startedFrom, now > then,
              FileManager.default.isExecutableFile(atPath: selfPath) else { continue }
        sleep(1)   // let the build finish writing
        guard !busy else { continue }
        let args = [selfPath, "--reexec"]
        var cargs = args.map { strdup($0) } + [nil]
        execv(selfPath, &cargs)   // only returns on failure; keep serving with this version
    }
}

while let line = readLine(strippingNewline: true) {
    busy = true
    defer { busy = false }
    guard !line.isEmpty, let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue }   // notifications (e.g. notifications/initialized) need no reply
    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        reply(id, result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": "studio", "version": "0.1"],
            "instructions": "You are running inside Studio, a Claude Code session manager. These tools control its UI (tabs, splits, terminals, themes, palette), its web panels, and remote sandboxes (sandbox_*). For any browsing, use the web panel by default (open_url, then web_*), so the user sees it beside you. See the studio:studio and studio:sandbox skills.",
        ])
    case "ping":
        reply(id, result: [:])
    case "tools/list":
        reply(id, result: ["tools": tools.map { t in
            ["name": t.name, "description": t.description,
             "inputSchema": ["type": "object", "properties": t.properties, "required": t.required] as [String: Any]]
        }])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        guard tools.contains(where: { $0.name == name }) else { fail(id, -32602, "unknown tool \(name)"); continue }
        let r = callStudio(name, params["arguments"] as? [String: Any] ?? [:])
        reply(id, result: ["content": [["type": "text", "text": r.text]], "isError": !r.ok])
    default:
        fail(id, -32601, "method not found: \(method)")
    }
}
