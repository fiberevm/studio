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
    let caret = Caret()
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
        weak var textView: CodeTextView?
        init(doc: FileDoc) { self.doc = doc }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            MainActor.assumeIsolated { doc.edited(tv.string) }
            scheduleHighlight()
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            MainActor.assumeIsolated { doc.caret.update(from: tv) }
        }

        func scheduleHighlight() {
            highlightWork?.cancel()
            // big files: color once per load, not on every keystroke
            guard (textView?.textStorage?.length ?? 0) < 400_000 else { return }
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let tv = self.textView else { return }
                    Highlighter.apply(to: tv, ext: self.doc.ext, name: self.doc.name)
                }
            }
            highlightWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 throughout: the gutter and current-line highlight read line fragments from the layout manager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let tv = CodeTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true     // no wrapping, like a code editor
        tv.autoresizingMask = [.width, .height]
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
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 10)

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.ruler = ruler

        context.coordinator.textView = tv
        register(tv)
        style(tv, scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! CodeTextView
        let c = context.coordinator
        c.doc = doc
        // restyle only when the theme or size changes (it resets the text color, so color again after)
        if c.themeId != Theme.current.id || c.fontSize != fontSize {
            c.themeId = Theme.current.id; c.fontSize = fontSize
            style(tv, scroll)
            Highlighter.apply(to: tv, ext: doc.ext, name: doc.name)
        }
        if c.revision != doc.revision {
            c.revision = doc.revision
            let sel = tv.selectedRange()
            tv.string = doc.text
            tv.indentUnit = CodeTextView.detectIndent(doc.text)
            let len = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            Highlighter.apply(to: tv, ext: doc.ext, name: doc.name)
            tv.ruler?.textChanged()
            doc.caret.update(from: tv)
        }
    }

    private func style(_ tv: CodeTextView, _ scroll: NSScrollView) {
        let font = Theme.font(fontSize)
        tv.font = font
        let para = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        para.defaultTabInterval = space * 4
        para.tabStops = []
        // a fixed line height (blank lines included), text centered in it
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        let lineHeight = (natural * 1.3).rounded()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        tv.defaultParagraphStyle = para
        tv.baselineShift = ((lineHeight - natural) / 2).rounded()
        tv.lineHeight = lineHeight
        tv.typingAttributes = [.font: font, .foregroundColor: Theme.foreground, .paragraphStyle: para, .baselineOffset: tv.baselineShift]
        if let st = tv.textStorage, st.length > 0 { st.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: st.length)) }
        tv.backgroundColor = Theme.background
        scroll.backgroundColor = Theme.background
        tv.insertionPointColor = Theme.current.cursor
        tv.selectedTextAttributes = [.backgroundColor: Theme.current.selection]
        tv.lineHighlight = Theme.foreground.withAlphaComponent(Theme.current.isLight ? 0.05 : 0.045)
        tv.ruler?.restyle(font: font)
        tv.needsDisplay = true
    }
}

/// Where the caret is, for the status bar (Ln 12, Col 4 · 3 selected).
@MainActor
final class Caret: ObservableObject {
    @Published private(set) var line = 1
    @Published private(set) var column = 1
    @Published private(set) var selected = 0

    func update(from tv: NSTextView) {
        let s = tv.string as NSString
        let r = tv.selectedRange()
        let loc = min(r.location, s.length)
        var l = 1, i = 0
        // count newlines up to the caret (fast enough for editable sizes; files over 8 MB aren't editable)
        while i < loc {
            let found = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: loc - i))
            if found.location == NSNotFound { break }
            l += 1; i = found.location + 1
        }
        let lineStart = s.lineRange(for: NSRange(location: loc, length: 0)).location
        if line != l { line = l }
        if column != loc - lineStart + 1 { column = loc - lineStart + 1 }
        if selected != r.length { selected = r.length }
    }
}

/// The editor's text view: current-line highlight, auto-indent on Return, Tab inserts the file's indent.
final class CodeTextView: NSTextView {
    weak var ruler: LineNumberRuler?
    var lineHighlight: NSColor = .clear
    var indentUnit = "    "
    var lineHeight: CGFloat = 16
    var baselineShift: CGFloat = 0

    /// Tabs if most indented lines start with one, else the most common small space step (2 or 4).
    static func detectIndent(_ text: String) -> String {
        var tabs = 0, two = 0, four = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            if line.hasPrefix("\t") { tabs += 1; continue }
            let n = line.prefix { $0 == " " }.count
            guard n > 0, n < line.count else { continue }
            if n % 4 == 0 { four += 1 } else if n % 2 == 0 { two += 1 }
        }
        if tabs > two + four { return "\t" }
        return two > four / 2 && two > 0 ? "  " : "    "
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let r = currentLineRect() else { return }
        lineHighlight.setFill()
        NSRect(x: 0, y: r.minY, width: max(bounds.width, visibleRect.maxX), height: r.height).fill()
    }

    func currentLineRect() -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let loc = selectedRange().location
        let len = (string as NSString).length
        var rect: NSRect
        if loc >= len, len == 0 || (string as NSString).character(at: len - 1) == 10 {
            rect = lm.extraLineFragmentRect
            if rect.isEmpty, len == 0 { rect = NSRect(x: 0, y: 0, width: 1, height: (font.map { lm.defaultLineHeight(for: $0) } ?? 16)) }
        } else {
            let g = lm.glyphIndexForCharacter(at: min(loc, max(len - 1, 0)))
            rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        _ = tc
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = currentLineRect()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if let old { setNeedsDisplay(NSRect(x: 0, y: old.minY, width: bounds.width, height: old.height)) }
        if let new = currentLineRect() { setNeedsDisplay(NSRect(x: 0, y: new.minY, width: bounds.width, height: new.height)) }
        if selectedRange().length > 0 { needsDisplay = true }
        ruler?.needsDisplay = true
    }

    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let loc = selectedRange().location
        let line = s.substring(with: s.lineRange(for: NSRange(location: loc, length: 0)))
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let lineStart = s.lineRange(for: NSRange(location: loc, length: 0)).location
        let beforeCaret = s.substring(with: NSRange(location: lineStart, length: loc - lineStart))
            .trimmingCharacters(in: .whitespaces)
        if let last = beforeCaret.last, "{[(:".contains(last) { indent += indentUnit }
        // between a pair like {|}: put the closer on its own line
        let next = loc < s.length ? s.character(at: loc) : 0
        if let last = beforeCaret.last, "{[(".contains(last), [125, 93, 41].contains(next) {
            let outer = String(indent.dropLast(indentUnit.count))
            insertText("\n" + indent + "\n" + outer, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: loc + 1 + (indent as NSString).length, length: 0))
            return
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 { shiftLines(by: 1); return }
        if indentUnit == "\t" { super.insertTab(sender); return }
        // pad to the next indent stop
        let s = string as NSString
        let loc = selectedRange().location
        let col = loc - s.lineRange(for: NSRange(location: loc, length: 0)).location
        let n = indentUnit.count - col % indentUnit.count
        insertText(String(repeating: " ", count: n), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    /// Indent or outdent every line the selection touches.
    func shiftLines(by d: Int) {
        let s = string as NSString
        let range = s.lineRange(for: selectedRange())
        var out: [String] = []
        s.substring(with: range).enumerateLines { line, _ in
            if d > 0 { out.append(line.isEmpty ? line : self.indentUnit + line) }
            else if line.hasPrefix("\t") { out.append(String(line.dropFirst())) }
            else { out.append(String(line.dropFirst(min(self.indentUnit == "\t" ? 4 : self.indentUnit.count, line.prefix { $0 == " " }.count)))) }
        }
        var text = out.joined(separator: "\n")
        if s.substring(with: range).hasSuffix("\n") { text += "\n" }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (text as NSString).length - (text.hasSuffix("\n") ? 1 : 0)))
    }
}

/// The gutter: line numbers, the caret's line brighter.
final class LineNumberRuler: NSRulerView {
    private weak var textView: CodeTextView?
    private var lineStarts: [Int] = [0]
    private var stale = true
    private var numberFont = Theme.font(11)

    init(textView: CodeTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange), name: NSText.didChangeNotification, object: textView)
    }
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func textDidChange() { textChanged() }
    func textChanged() { stale = true; needsDisplay = true }

    func restyle(font: NSFont) {
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)
        stale = true
        needsDisplay = true
    }

    private func rebuild() {
        guard stale, let s = textView?.string as NSString? else { return }
        stale = false
        var starts = [0]
        var i = 0
        let n = s.length
        while i < n {
            let r = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: n - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1); i = r.location + 1
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let w = ("8" as NSString).size(withAttributes: [.font: numberFont]).width * CGFloat(digits) + 26
        if abs(ruleThickness - w) > 0.5 { ruleThickness = w }
    }

    /// 0-based line containing character `i`.
    private func line(of i: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= i { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        rebuild()
        Theme.background.setFill()
        bounds.fill()
        let s = tv.string as NSString
        let caretLine = line(of: min(tv.selectedRange().location, s.length))
        let dim = Theme.foreground.withAlphaComponent(Theme.current.isLight ? 0.4 : 0.35)
        let bright = Theme.foreground.withAlphaComponent(0.9)
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let origin = tv.textContainerOrigin
        let right = bounds.width - 12

        func draw(_ n: Int, fragment: NSRect, baseline: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: n == caretLine ? bright : dim]
            let label = String(n + 1) as NSString
            let size = label.size(withAttributes: attrs)
            // same baseline as the text: the fixed line's bottom, less the font's descent, raised by the shift
            let textBaseline = fragment.minY + tv.lineHeight + (tv.font?.descender ?? -3) - tv.baselineShift
            let yInTV = textBaseline + origin.y - numberFont.ascender
            let y = convert(NSPoint(x: 0, y: yInTV), from: tv).y
            label.draw(at: NSPoint(x: right - size.width, y: y), withAttributes: attrs)
        }

        var lastBase = (tv.font?.ascender ?? 10) * 1.1
        var ln = line(of: chars.location)
        var idx = lineStarts[ln]
        // walk the visible lines (one fragment each: no wrapping)
        while idx <= NSMaxRange(chars), ln < lineStarts.count {
            if idx >= s.length { break }
            let g = lm.glyphIndexForCharacter(at: idx)
            var eff = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
            let base = lm.location(forGlyphAt: g).y
            if frag.minY + origin.y > visible.maxY { break }
            draw(ln, fragment: frag, baseline: base)
            lastBase = base
            ln += 1
            idx = ln < lineStarts.count ? lineStarts[ln] : Int.max
        }
        // the empty last line after a trailing newline (or an empty file)
        if ln == lineStarts.count - 1, lineStarts[ln] == s.length {
            let extra = lm.extraLineFragmentRect
            let h = tv.font.map { lm.defaultLineHeight(for: $0) } ?? 16
            draw(ln, fragment: extra.isEmpty ? NSRect(x: 0, y: 0, width: 1, height: h) : extra, baseline: lastBase)
        }
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
