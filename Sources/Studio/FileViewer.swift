import AppKit
import SwiftUI

// MARK: - Document

/// A file open in a tab: its text, whether it has unsaved edits, and a watch on the file so edits made
/// elsewhere (usually an agent) show up live.
@MainActor
final class FileDoc: ObservableObject {
    enum Content: Equatable { case text, image, binary, tooLarge, missing }

    let path: String
    @Published private(set) var content: Content = .text
    @Published private(set) var dirty = false
    /// Changed on disk while you had unsaved edits: the pane offers Reload / Keep Mine.
    @Published var changedOnDisk = false
    @Published private(set) var lineCount = 0
    /// Bumped whenever the text is replaced from disk, so the editor view picks it up.
    @Published private(set) var revision = 0

    private(set) var text = ""
    private var diskStamp: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    static let maxEditable = 8 << 20   // 8 MB
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "ico", "icns", "pdf"]

    init(path: String) {
        self.path = path
        load()
        watch()
    }

    deinit { watcher?.cancel() }

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { content = .missing; return }
        let attrs = try? fm.attributesOfItem(atPath: path)
        diskStamp = attrs?[.modificationDate] as? Date
        if Self.imageTypes.contains(ext) { content = .image; revision += 1; return }
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxEditable else { content = .tooLarge; return }
        guard let data = fm.contents(atPath: path) else { content = .missing; return }
        // a NUL in the first 8 KB: not text
        if data.prefix(8192).contains(0) { content = .binary; return }
        text = String(decoding: data, as: UTF8.self)
        content = .text
        dirty = false
        changedOnDisk = false
        lineCount = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        revision += 1
    }

    /// The editor reports edits here.
    func edited(_ new: String) {
        text = new
        if !dirty { dirty = true }
        lineCount = new.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
    }

    @discardableResult
    func save() -> Bool {
        guard content == .text else { return false }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            diskStamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            dirty = false
            changedOnDisk = false
            watch()   // an atomic write replaces the file: watch the new one
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    // MARK: Watching

    private func watch() {
        watcher?.cancel(); watcher = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.diskChanged(replaced: src.data.contains(.delete) || src.data.contains(.rename)) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func diskChanged(replaced: Bool) {
        // editors and agents often save by replacing the file: re-watch the new one a beat later
        if replaced { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.watch(); self?.diskChanged(replaced: false) } ; return }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        guard stamp != diskStamp else { return }   // our own save
        if dirty { changedOnDisk = true } else { load() }
    }
}

// MARK: - Pane

struct FilePane: View {
    @ObservedObject var doc: FileDoc
    let fontSize: CGFloat
    var register: (NSTextView) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if doc.changedOnDisk {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(doc.name) changed on disk while you were editing it.").font(.system(size: 12))
                    Spacer()
                    Button("Reload") { doc.load() }
                    Button("Keep Mine") { doc.changedOnDisk = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(SwiftUI.Color.orange.opacity(0.12))
            }
            switch doc.content {
            case .text:
                CodeEditor(doc: doc, fontSize: fontSize, register: register)
            case .image:
                if let img = NSImage(contentsOfFile: doc.path) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: min(img.size.width, 1600), maxHeight: min(img.size.height, 1600))
                            .padding(24)
                    }
                    .id(doc.revision)
                } else { notice("Can't display this image") }
            case .binary: notice("Binary file")
            case .tooLarge: notice("Too large to edit here (over 8 MB)")
            case .missing: notice("This file no longer exists")
            }
        }
        .background(SwiftUI.Color(nsColor: Theme.background))
    }

    private func notice(_ s: String) -> some View {
        VStack(spacing: 10) {
            Text(s).foregroundStyle(.secondary)
            Button("Open in Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: doc.path)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.path)]) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

/// NSTextView in the theme's colors and terminal font: plain text, undo, find bar (⌘F), no smart quotes,
/// with light syntax coloring. Text comes from the doc on load/reload; edits go back to it.
struct CodeEditor: NSViewRepresentable {
    @ObservedObject var doc: FileDoc
    let fontSize: CGFloat
    var register: (NSTextView) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var doc: FileDoc
        var revision = -1
        var themeId = ""
        var fontSize: CGFloat = 0
        var highlightWork: DispatchWorkItem?
        weak var textView: NSTextView?
        init(doc: FileDoc) { self.doc = doc }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            MainActor.assumeIsolated { doc.edited(tv.string) }
            scheduleHighlight()
        }

        func scheduleHighlight() {
            highlightWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let tv = self?.textView, let ext = self?.doc.ext else { return }
                    Highlighter.apply(to: tv, ext: ext)
                }
            }
            highlightWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        // no wrapping, like a code editor
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.textView = tv
        register(tv)
        style(tv, scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        let c = context.coordinator
        c.doc = doc
        // restyle only when the theme or size changes (it resets the text color, so color again after)
        if c.themeId != Theme.current.id || c.fontSize != fontSize {
            c.themeId = Theme.current.id; c.fontSize = fontSize
            style(tv, scroll)
            Highlighter.apply(to: tv, ext: doc.ext)
        }
        if c.revision != doc.revision {
            c.revision = doc.revision
            let sel = tv.selectedRanges
            tv.string = doc.text
            let len = (tv.string as NSString).length
            tv.selectedRanges = sel.filter { $0.rangeValue.location <= len }.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : sel.map {
                let r = $0.rangeValue
                return NSValue(range: NSRange(location: min(r.location, len), length: 0))
            }
            Highlighter.apply(to: tv, ext: doc.ext)
        }
    }

    private func style(_ tv: NSTextView, _ scroll: NSScrollView) {
        let font = Theme.font(fontSize)
        if tv.font != font { tv.font = font; tv.typingAttributes[.font] = font }
        tv.backgroundColor = Theme.background
        scroll.backgroundColor = Theme.background
        tv.textColor = Theme.foreground
        tv.insertionPointColor = Theme.current.cursor
        tv.selectedTextAttributes = [.backgroundColor: Theme.current.selection]
        tv.typingAttributes[.foregroundColor] = Theme.foreground
    }
}

/// Light, regex-based coloring: comments, strings, numbers and common keywords, in the theme's ANSI colors.
@MainActor
enum Highlighter {
    private static let keywords = ["func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class",
        "enum", "case", "switch", "guard", "in", "true", "false", "nil", "null", "undefined", "const", "function", "def",
        "async", "await", "export", "from", "type", "interface", "public", "private", "static", "self", "this", "new",
        "try", "catch", "throw", "throws", "package", "go", "fn", "impl", "pub", "use", "mod", "match", "with", "as",
        "extension", "protocol", "default", "break", "continue", "do", "elif", "lambda", "yield", "None", "True", "False"]
    private static let kw = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b")
    private static let num = try! NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F_]+|\\d[\\d_]*(\\.\\d+)?)\\b")
    private static let str = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'|`[^`]*`")
    private static let slash = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
    private static let hash = try! NSRegularExpression(pattern: "(?m)(^|\\s)#[^\\n]*")
    private static let mdHeading = try! NSRegularExpression(pattern: "(?m)^#{1,6} .*$")

    static func apply(to tv: NSTextView, ext: String) {
        guard let storage = tv.textStorage else { return }
        let len = storage.length
        guard len > 0, len < 1_500_000 else { return }
        let s = storage.string
        let all = NSRange(location: 0, length: len)
        let ansi = Theme.current.ansi
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: all)
        func paint(_ re: NSRegularExpression, _ color: NSColor) {
            re.enumerateMatches(in: s, range: all) { m, _, _ in if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) } }
        }
        if ext == "md" || ext == "markdown" {
            paint(mdHeading, ansi[4])
            paint(str, ansi[2])
        } else if !["txt", "log", "csv"].contains(ext) {
            paint(kw, ansi[5])
            paint(num, ansi[3])
            paint(str, ansi[2])
            let hashComments = ["py", "sh", "bash", "zsh", "rb", "yml", "yaml", "toml", "conf", "env", "dockerfile", "mk", "r", "pl"]
            paint(hashComments.contains(ext) || ext.isEmpty ? hash : slash, ansi[8])
        }
        storage.endEditing()
    }
}

// MARK: - File index (for ⌘K)

/// Every file in a project, for ⌘K: tracked and untracked-but-not-ignored files from git when it's a repo,
/// else a walk that skips the usual heavy folders. Built in the background and refreshed when older than 20s.
final class FileIndex: @unchecked Sendable {
    static let shared = FileIndex()
    private let lock = NSLock()
    private var cache: [String: (files: [String], at: Date)] = [:]
    private var building: Set<String> = []
    static let changed = Notification.Name("studio.fileindex.changed")

    /// Relative paths (may be empty while the first build runs).
    func files(in root: String) -> [String] {
        lock.lock()
        let c = cache[root]
        let stale = c == nil || Date().timeIntervalSince(c!.at) > 20
        let go = stale && !building.contains(root)
        if go { building.insert(root) }
        lock.unlock()
        if go { DispatchQueue.global(qos: .userInitiated).async { self.build(root) } }
        return c?.files ?? []
    }

    private func build(_ root: String) {
        var out = gitFiles(root) ?? walk(root)
        if out.count > 200_000 { out = Array(out.prefix(200_000)) }
        lock.lock(); cache[root] = (out, Date()); building.remove(root); lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: root) }
    }

    private func gitFiles(_ root: String) -> [String]? {
        guard FileManager.default.fileExists(atPath: root + "/.git") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func walk(_ root: String) -> [String] {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", ".next", "target", "Pods",
                                 ".venv", "venv", "__pycache__", ".cache", ".idea", ".gradle"]
        var out: [String] = []
        let base = URL(fileURLWithPath: root)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsPackageDescendants]) else { return [] }
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(String(u.path.dropFirst(base.path.count + 1)))
            if out.count >= 100_000 { break }
        }
        return out
    }

    /// Best matches for `q`: filename hits first (prefix, then substring), then path substring, then fuzzy.
    static func search(_ files: [String], _ q: String, limit: Int = 60) -> [String] {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Int, String)] = []
        for f in files {
            let lower = f.lowercased()
            let name = (lower as NSString).lastPathComponent
            let score: Int
            if name == q { score = 0 }
            else if name.hasPrefix(q) { score = 1 }
            else if name.contains(q) { score = 2 }
            else if lower.contains(q) { score = 3 }
            else if isSubsequence(q, of: name) { score = 4 }   // loose matches only within the file name
            else { continue }
            scored.append((score, f.count, f))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return scored.prefix(limit).map(\.2)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle where c != " " {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
