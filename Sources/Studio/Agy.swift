import Foundation
import SQLite3

/// Google Antigravity's CLI (`agy`) keeps each conversation in its own SQLite database,
/// ~/.gemini/antigravity-cli/conversations/<id>.db, and every prompt in history.jsonl (with its folder).
/// The database's `steps` table says what the agent is doing; `trajectory_metadata_blob` names its folder.
enum AgyPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli")
    static var conversations: URL { home.appendingPathComponent("conversations") }
    static var history: URL { home.appendingPathComponent("history.jsonl") }
}

/// What an agy conversation is doing right now.
struct AgySession: Equatable {
    var record: SessionRecord
    var busy = false       // generating or running a command
    var waiting = false    // asking for permission
}

/// Reads agy's conversations cheaply: one small read-only query per open conversation per scan.
/// Not thread-safe: use it from one queue.
final class AgyScanner {
    private struct Meta { let cwd: String; let created: Date }
    private struct Prompt { let at: Date; let cwd: String; let text: String }

    private var metas: [String: Meta] = [:]       // by conversation id
    private var unreadable: Set<String> = []      // databases without a folder (yet)
    private var prompts: [Prompt] = []
    private var historySize: UInt64 = 0

    // Step statuses, from agy 1.5: 2 running a command, 8 generating, 9 waiting for permission, 3 done.
    private static let running: Set<Int32> = [2, 8]
    private static let asking: Int32 = 9

    // MARK: Discovery

    private func refresh() {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: AgyPaths.conversations.path) {
            for n in names where n.hasSuffix(".db") {
                let id = String(n.dropLast(3))
                guard metas[id] == nil else { continue }
                let path = AgyPaths.conversations.appendingPathComponent(n).path
                guard let cwd = Self.workspace(path) else { unreadable.insert(id); continue }
                unreadable.remove(id)
                let created = (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? Date()
                metas[id] = Meta(cwd: cwd, created: created)
            }
        }
        refreshHistory()
    }

    private func refreshHistory() {
        let path = AgyPaths.history.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size != historySize, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        historySize = size
        prompts = text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["type"] == nil,   // slash commands carry a type
                  let t = o["display"] as? String, let cwd = o["workspace"] as? String,
                  let ms = (o["timestamp"] as? NSNumber)?.doubleValue else { return nil }
            return Prompt(at: Date(timeIntervalSince1970: ms / 1000), cwd: cwd, text: t)
        }
    }

    // MARK: Queries

    func exists(_ id: String) -> Bool {
        if metas[id] == nil { refresh() }
        return metas[id] != nil
    }

    /// The conversation a tab started in `cwd` at `since` is running, once agy has written it:
    /// the earliest one begun there since then that no other tab has claimed.
    func started(in cwd: String, since: Date, excluding: Set<String>) -> String? {
        refresh()
        let want = canonicalPath(cwd)
        return metas.filter { $0.value.created >= since.addingTimeInterval(-3) && !excluding.contains($0.key)
            && canonicalPath($0.value.cwd) == want }
            .min { $0.value.created < $1.value.created }?.key
    }

    func scan(ids: Set<String>) -> [String: AgySession] {
        refresh()
        var out: [String: AgySession] = [:]
        for id in ids {
            guard let m = metas[id] else { continue }
            var s = AgySession(record: record(id, m))
            let path = AgyPaths.conversations.appendingPathComponent(id + ".db").path
            let statuses = Self.query(path, "SELECT status FROM steps WHERE status != 3").map { Set($0) } ?? []
            s.waiting = statuses.contains(Self.asking)
            // between steps every step reads done for a moment; a write in the last 3s still counts as working
            s.busy = !s.waiting && (!statuses.isDisjoint(with: Self.running) || s.record.lastActivity > Date().addingTimeInterval(-3))
            out[id] = s
        }
        return out
    }

    /// Every agy conversation on disk, for ⌘P history.
    func all() -> [SessionRecord] {
        refresh()
        return metas.map { record($0.key, $0.value) }
    }

    private func record(_ id: String, _ m: Meta) -> SessionRecord {
        let base = AgyPaths.conversations.appendingPathComponent(id + ".db").path
        let fm = FileManager.default
        let modified = [base, base + "-wal"].compactMap { try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max() ?? m.created
        // its messages: prompts typed in its folder since it began (agy logs them without the conversation id)
        let want = canonicalPath(m.cwd)
        let mine = prompts.filter { $0.at >= m.created.addingTimeInterval(-3) && canonicalPath($0.cwd) == want }
        return SessionRecord(id: id, cwd: m.cwd, firstPrompt: mine.first.map { String($0.text.prefix(200)) },
                             lastPrompt: mine.last.map { String($0.text.prefix(200)) },
                             lastActivity: modified, transcriptPath: base, agent: .agy)
    }

    // MARK: SQLite

    /// The folder in the conversation's metadata (a file:// URL inside a protobuf blob).
    private static func workspace(_ path: String) -> String? {
        guard let blob = queryBlob(path, "SELECT data FROM trajectory_metadata_blob LIMIT 1"),
              let r = blob.range(of: Data("file://".utf8)) else { return nil }
        let bytes = blob[r.lowerBound...].prefix { $0 >= 0x21 && $0 < 0x7F }
        return String(decoding: bytes, as: UTF8.self).removingPercentEncoding.flatMap { URL(string: $0)?.path }
            ?? URL(string: String(decoding: bytes, as: UTF8.self))?.path
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // Read-only opens of a WAL database need its -shm file, which exists only while agy has it open.
        // Without one nothing is writing, so it's safe to read as immutable.
        let live = FileManager.default.fileExists(atPath: path + "-shm")
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            + (live ? "?mode=ro" : "?mode=ro&immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        sqlite3_busy_timeout(db, 50)
        return db
    }

    private static func query(_ path: String, _ sql: String) -> [Int32]? {
        guard let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        var out: [Int32] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(sqlite3_column_int(st, 0)) }
        return out
    }

    private static func queryBlob(_ path: String, _ sql: String) -> Data? {
        guard let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
    }
}

/// A folder path as it compares: symlinks resolved, /private/tmp and /tmp alike.
func canonicalPath(_ p: String) -> String {
    let r = (p as NSString).resolvingSymlinksInPath
    return r.hasPrefix("/private/") ? String(r.dropFirst(8)) : r
}
