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
         description: "Describe Studio: windows (one per project folder), their split layout of tab groups, each tab (id, kind claude|terminal, title, status, which one is you), the sessions in the sidebar, the theme and font size. Call this first to get tab and group ids.",
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
    Tool(name: "split_tab",
         description: "Split the editor: move a tab (default: your own) into a new pane on the given side. If it's the only tab in its pane, a new session opens there instead.",
         properties: ["tab": ["type": "string"], "direction": direction], required: ["direction"]),
    Tool(name: "move_tab",
         description: "Move a tab (default: yours) into another group, as a tab (zone center) or splitting that group (right/left/up/down).",
         properties: ["tab": ["type": "string"], "to_group": ["type": "string"],
                      "zone": ["type": "string", "enum": ["center", "right", "left", "up", "down"]]],
         required: ["to_group"]),
    Tool(name: "focus_tab", description: "Bring a tab to the front and focus it.",
         properties: ["tab": ["type": "string"]], required: ["tab"]),
    Tool(name: "close_tab",
         description: "Close a tab. A Claude session keeps running in the sidebar; a plain terminal is ended.",
         properties: ["tab": ["type": "string"]], required: ["tab"]),
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
    var tv = timeval(tv_sec: 10, tv_usec: 0)
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

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue }   // notifications (e.g. notifications/initialized) need no reply
    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        reply(id, result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "studio", "version": "0.1"],
            "instructions": "You are running inside Studio, a Claude Code session manager. These tools control its UI: tabs, split panes, plain terminals, themes and the command palette. Call get_state first; the tab marked is_you is this session.",
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
