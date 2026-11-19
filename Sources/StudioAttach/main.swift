// studio-attach: a Studio tab's terminal for a session on a worker. Connects to the worker's WebSocket and
// passes the terminal through, raw: keys up, screen down, size changes as they happen. Reconnects on its own
// when the network drops (sleep, VPN), and stops when the session is gone.
// Usage: STUDIO_WORKER_TOKEN=… studio-attach <worker url> <session id>
import Foundation
import Darwin

let args = CommandLine.arguments
guard args.count == 3, let base = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: STUDIO_WORKER_TOKEN=… studio-attach <worker url> <session id>\n".data(using: .utf8)!)
    exit(2)
}
let session = args[2]
let token = ProcessInfo.processInfo.environment["STUDIO_WORKER_TOKEN"] ?? ""

func say(_ s: String) { FileHandle.standardOutput.write(("\r\n\u{1b}[2m" + s + "\u{1b}[0m\r\n").data(using: .utf8)!) }

// raw mode: every key goes to the worker as typed
var saved = termios()
tcgetattr(STDIN_FILENO, &saved)
var raw = saved
cfmakeraw(&raw)
tcsetattr(STDIN_FILENO, TCSANOW, &raw)
func restore() { var t = saved; tcsetattr(STDIN_FILENO, TCSANOW, &t) }
atexit { restore() }

func size() -> (Int, Int) {
    var w = winsize()
    return ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 ? (Int(w.ws_col), Int(w.ws_row)) : (120, 40)
}

final class Link: NSObject, URLSessionWebSocketDelegate {
    var task: URLSessionWebSocketTask?
    let lock = NSLock()
    var open = false
    var urlSession: URLSession!
    let base: URL, session: String, token: String

    init(base: URL, session: String, token: String) {
        self.base = base; self.session = session; self.token = token
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        var comps = URLComponents(url: base.appendingPathComponent("v1/sessions/\(session)/attach"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = urlSession.webSocketTask(with: req)
        t.maximumMessageSize = 16 << 20
        lock.lock(); task = t; lock.unlock()
        t.resume()
        receive(t)
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        lock.lock(); open = true; lock.unlock()
        if retries > 0 { say("Reconnected.") }
        retries = 0
        sendSize()
    }

    func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            switch result {
            case .success(.data(let d)):
                FileHandle.standardOutput.write(d)
                self?.receive(t)
            case .success(.string(let s)):
                if s.contains("\"error\"") { say("worker: " + s) }
                self?.receive(t)
            case .success: self?.receive(t)
            case .failure: self?.dropped()
            }
        }
    }

    func send(_ d: Data) {
        lock.lock(); let t = open ? task : nil; lock.unlock()
        t?.send(.data(d)) { _ in }
    }

    func sendSize() {
        let (c, r) = size()
        lock.lock(); let t = open ? task : nil; lock.unlock()
        t?.send(.string("{\"cols\":\(c),\"rows\":\(r)}")) { _ in }
    }

    private var retries = 0
    func dropped() {
        lock.lock(); open = false; lock.unlock()
        // gone for good, or just unreachable for now?
        switch status() {
        case 404:
            say("The session on the worker has ended.")
            exit(0)
        case 401:
            say("The worker refused Studio's token. Pair it again in Settings → Workers.")
            exit(1)
        default:
            retries += 1
            if retries == 1 { say("Lost the connection to the worker; reconnecting…") }
            DispatchQueue.global().asyncAfter(deadline: .now() + min(Double(retries), 5)) { self.connect() }
        }
    }

    /// HTTP status of GET /v1/sessions/<id> (0 when the worker can't be reached).
    func status() -> Int {
        var req = URLRequest(url: base.appendingPathComponent("v1/sessions/\(session)"), timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var code = 0
        URLSession.shared.dataTask(with: req) { _, r, _ in code = (r as? HTTPURLResponse)?.statusCode ?? 0; sem.signal() }.resume()
        sem.wait()
        return code
    }
}

let link = Link(base: base, session: session, token: token)
link.connect()

signal(SIGWINCH, SIG_IGN)
let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
winch.setEventHandler { link.sendSize() }
winch.resume()
for s in [SIGTERM, SIGHUP, SIGINT] {
    signal(s) { _ in restore(); exit(0) }
}

// keys → worker
DispatchQueue.global().async {
    var buf = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 { restore(); exit(0) }
        link.send(Data(buf[0..<n]))
    }
}
dispatchMain()
