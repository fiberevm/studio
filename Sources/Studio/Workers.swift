import Foundation

/// A machine running `studio-worker` (usually an always-on Linux box on Tailscale or Cloudflare Zero Trust):
/// Studio can start agent sessions there, show them in tabs, and its AIs can hand work to them.
struct Worker: Codable, Identifiable, Hashable {
    var id: String            // stable, local
    var name: String
    var url: String           // http://100.x.y.z:7420
    var folder: String?       // where new sessions start (default: the worker's home)
}

/// What a worker reports about itself.
struct WorkerInfo: Decodable, Equatable {
    struct AgentInfo: Decodable, Equatable { let installed: Bool; let version: String? }
    let name: String
    let hostname: String
    let os: String
    let arch: String
    let version: String
    let home: String
    let agents: [String: AgentInfo]
}

/// A session running on a worker.
struct WorkerSession: Decodable, Equatable, Identifiable {
    let id: String
    let agent: String
    let cwd: String
    let created: Date
    let running: Bool
    let status: String          // working | idle | waiting | starting | running | exited
    let title: String?
    let lastReply: String?
    let prompt: String?
    let waitingFor: String?
    let conversation: String?

    var sessionStatus: SessionStatus {
        switch status {
        case "working": return .working
        case "waiting": return .waiting
        case "starting": return .starting
        case "exited": return .exited
        default: return .idle
        }
    }
}

struct WorkerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The paired workers, their tokens and what they're running. Polled every few seconds while
/// any worker is paired; nothing runs otherwise.
@MainActor
final class WorkerRegistry: ObservableObject {
    static let shared = WorkerRegistry()

    @Published private(set) var workers: [Worker] = []
    @Published private(set) var info: [String: WorkerInfo] = [:]          // by worker id, while reachable
    @Published private(set) var sessions: [String: [WorkerSession]] = [:]  // by worker id
    @Published private(set) var lastError: [String: String] = [:]

    private var timer: Timer?
    private var polling = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: "workers"), let w = try? JSONDecoder().decode([Worker].self, from: d) { workers = w }
        // scripting/testing aid: --pair-worker <studio://worker link>
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--pair-worker"), i + 1 < a.count { _ = try? pair(a[i + 1]) }
        updateTimer()
    }

    func worker(_ id: String) -> Worker? { workers.first { $0.id == id } }
    /// By id or name (what an AI passes to the MCP tools).
    func find(_ key: String) -> Worker? {
        workers.first { $0.id == key } ?? workers.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }
    func isOnline(_ id: String) -> Bool { info[id] != nil }
    func session(_ worker: String, _ id: String) -> WorkerSession? { sessions[worker]?.first { $0.id == id } }

    // MARK: Pairing

    /// Add (or update) a worker from the link `studio-worker serve` prints: studio://worker?url=…&token=…&name=…
    @discardableResult
    func pair(_ link: String) throws -> Worker {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: s), comps.scheme == "studio",
              let q = comps.queryItems, let url = q.first(where: { $0.name == "url" })?.value,
              let token = q.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              URL(string: url) != nil else {
            throw WorkerError(message: "That isn't a worker link. Run `studio-worker pair` on the machine and paste what it prints.")
        }
        let name = q.first(where: { $0.name == "name" })?.value ?? URL(string: url)?.host ?? "worker"
        var w = workers.first { $0.url == url } ?? Worker(id: UUID().uuidString, name: name, url: url)
        w.name = name
        TokenStore.set(token, for: w.id)
        if let i = workers.firstIndex(where: { $0.id == w.id }) { workers[i] = w } else { workers.append(w) }
        save()
        poll()
        return w
    }

    func remove(_ id: String) {
        workers.removeAll { $0.id == id }
        TokenStore.delete(id)
        info[id] = nil; sessions[id] = nil; lastError[id] = nil
        save()
    }

    func setFolder(_ id: String, _ folder: String?) {
        guard let i = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[i].folder = folder?.isEmpty == true ? nil : folder
        save()
    }

    func token(_ id: String) -> String { TokenStore.get(id) ?? "" }

    private func save() {
        if let d = try? JSONEncoder().encode(workers) { UserDefaults.standard.set(d, forKey: "workers") }
        updateTimer()
    }

    // MARK: Polling

    private func updateTimer() {
        if workers.isEmpty { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let list = workers
        Task {
            await withTaskGroup(of: (String, WorkerInfo?, [WorkerSession]?, String?).self) { group in
                for w in list {
                    group.addTask {
                        do {
                            // info once per connection is enough; sessions every poll
                            let infoNeeded = await MainActor.run { self.info[w.id] == nil }
                            let i: WorkerInfo? = infoNeeded ? try await self.get(w, "v1/info") : nil
                            let s: [WorkerSession] = try await self.get(w, "v1/sessions")
                            return (w.id, i, s, nil)
                        } catch {
                            return (w.id, nil, nil, error.localizedDescription)
                        }
                    }
                }
                for await (id, i, s, err) in group {
                    if let err {
                        if self.info[id] != nil { self.info[id] = nil }
                        if self.lastError[id] != err { self.lastError[id] = err }
                        continue
                    }
                    if let i { self.info[id] = i }
                    if let s, self.sessions[id] != s { self.sessions[id] = s }
                    if self.lastError[id] != nil { self.lastError[id] = nil }
                }
            }
            self.polling = false
        }
    }

    // MARK: API

    nonisolated private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            return Date()
        }
        return d
    }()

    nonisolated func request(_ w: Worker, _ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        let base = w.url.hasSuffix("/") ? String(w.url.dropLast()) : w.url
        guard let url = URL(string: base + "/" + path) else { throw WorkerError(message: "bad worker URL") }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = method
        let token = await MainActor.run { self.token(w.id) }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw WorkerError(message: code == 401 ? "\(w.name) refused the token: pair it again" : msg ?? "\(w.name) answered \(code)")
        }
        return data
    }

    nonisolated func get<T: Decodable>(_ w: Worker, _ path: String) async throws -> T {
        try Self.decoder.decode(T.self, from: try await request(w, "GET", path))
    }

    func start(on w: Worker, agent: Agent, folder: String?, prompt: String?) async throws -> WorkerSession {
        var body: [String: Any] = ["agent": agent.rawValue]
        if let f = folder ?? w.folder { body["cwd"] = f }
        if let prompt, !prompt.isEmpty { body["prompt"] = prompt }
        let data = try await request(w, "POST", "v1/sessions", body: body)
        let s = try Self.decoder.decode(WorkerSession.self, from: data)
        poll()
        return s
    }

    func send(on w: Worker, session: String, text: String) async throws {
        _ = try await request(w, "POST", "v1/sessions/\(session)/send", body: ["text": text])
    }

    func stop(on w: Worker, session: String) async throws {
        _ = try await request(w, "DELETE", "v1/sessions/\(session)")
        poll()
    }

    func status(on w: Worker, session: String) async throws -> WorkerSession {
        try await get(w, "v1/sessions/\(session)")
    }

    func screen(on w: Worker, session: String) async throws -> String {
        let d = try await request(w, "GET", "v1/sessions/\(session)/screen")
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["screen"] as? String ?? ""
    }

    func dirs(on w: Worker, path: String?) async throws -> Any {
        let q = path.map { "?path=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
        return try JSONSerialization.jsonObject(with: try await request(w, "GET", "v1/dirs" + q))
    }
}

/// Worker tokens, one file each in Application Support readable only by you (like Studio's control token).
/// Not the Keychain: Studio is ad hoc signed, so every rebuild would count as a new app and ask again.
enum TokenStore {
    private static var dir: URL {
        URL(fileURLWithPath: StudioControl.supportDirPath).appendingPathComponent("workers", isDirectory: true)
    }
    private static func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".token") }
    static func set(_ value: String, for id: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file(id).path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    }
    static func get(_ id: String) -> String? {
        (try? String(contentsOf: file(id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func delete(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }
}
