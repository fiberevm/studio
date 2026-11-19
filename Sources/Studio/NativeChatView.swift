import SwiftUI
import AppKit

/// The colors Claude Code's terminal UI draws with, taken from the theme's ANSI palette the same way the
/// TUI's are, so the native view looks like the terminal it replaces (and follows theme changes).
@MainActor enum TUIColor {
    private static func ansi(_ i: Int) -> SwiftUI.Color { SwiftUI.Color(nsColor: Theme.current.ansi[i]) }
    static var fg: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.foreground) }
    static var dim: SwiftUI.Color { fg.opacity(0.6) }                 // secondary text (SGR dim)
    static var success: SwiftUI.Color { ansi(10) }                    // ● of a finished tool call
    static var error: SwiftUI.Color { ansi(9) }
    static var warning: SwiftUI.Color { ansi(11) }
    static var code: SwiftUI.Color { ansi(12) }                       // `inline code`
    static var claude: SwiftUI.Color { ClaudeSpinner.orange }
    /// The band behind your messages.
    static var promptBand: SwiftUI.Color { Theme.current.isLight ? fg.opacity(0.07) : ansi(8) }
}

/// Opens an image full size (a modal over the window).
private struct ZoomImageKey: EnvironmentKey { static let defaultValue: (ChatImage) -> Void = { _ in } }
extension EnvironmentValues {
    var zoomImage: (ChatImage) -> Void {
        get { self[ZoomImageKey.self] }
        set { self[ZoomImageKey.self] = newValue }
    }
}

/// Studio's own rendering of a Claude conversation, laid out and colored like Claude Code's terminal UI:
/// everything left aligned, your messages on a band with a `>`, Claude's answers after a ●, and the tool
/// calls in between folded into a work log that collapses to one line once the answer is in. Approvals sit
/// inline; images show as thumbnails that open full size. The composer is a `>` prompt in the terminal font
/// with the model on the left and the permission mode beside Send on the right.
struct NativeChatView: View {
    @ObservedObject var chat: NativeChat
    @EnvironmentObject var model: ProjectModel
    @State private var draft = ""
    @State private var inputHeight: CGFloat = 20
    @State private var zoomed: ChatImage?

    private var size: CGFloat { model.store.fontSize }
    private var mono: Font { .system(size: size, design: .monospaced) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(turns) { turn in
                            TurnView(turn: turn, chat: chat, size: size, live: turn.id == turns.last?.id && chat.busy)
                                .id(turn.id)
                        }
                        SwiftUI.Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.items.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Hairline()
            composer
        }
        .font(mono)
        .foregroundStyle(TUIColor.fg)
        .background(SwiftUI.Color(nsColor: Theme.background))
        .environment(\.zoomImage) { zoomed = $0 }
        .sheet(item: $zoomed) { ImageModal(image: $0) }
    }

    // MARK: Turns

    /// A prompt and everything Claude did for it.
    struct Turn: Identifiable {
        let id: String
        var prompt: ChatItem?
        var work: [ChatItem] = []        // tool calls, permissions and in-between remarks
        var answer: [ChatItem] = []      // the text after the last tool call: the summary
        var end: ChatItem?               // the result note (duration)
    }

    private var turns: [Turn] {
        var out: [Turn] = []
        var cur = Turn(id: "start")
        func flush() {
            // the answer is the trailing run of text; earlier text is part of the work
            if let lastWork = cur.work.lastIndex(where: { if case .text = $0.kind { return false }; return true }) {
                cur.answer = Array(cur.work[(lastWork + 1)...])
                cur.work = Array(cur.work[...lastWork])
            } else {
                cur.answer = cur.work
                cur.work = []
            }
            if cur.prompt != nil || !cur.answer.isEmpty || !cur.work.isEmpty { out.append(cur) }
        }
        for item in chat.items {
            switch item.kind {
            case .user:
                flush()
                cur = Turn(id: item.id, prompt: item)
            case .note:
                cur.end = item
            default:
                cur.work.append(item)
            }
        }
        flush()
        return out
    }

    // MARK: Composer

    /// One line, like Claude Code's input: `>`, the text (growing to more lines as you type), then the
    /// elapsed time while working, the permission mode and Send. On the terminal background, monospaced.
    private var composer: some View {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 2   // + the text view's 1pt insets
        return HStack(alignment: .top, spacing: 10) {
            Text(">").font(mono).foregroundStyle(TUIColor.fg).frame(height: line)
            ChatInput(text: $draft, height: $inputHeight, fontSize: size,
                      placeholder: chat.exited ? "Session ended — ⌘/ to switch back to the terminal"
                                               : chat.busy ? "Queue a follow-up…" : "Ask \(chat.agent == .claude ? "Claude" : chat.agent.name) anything…",
                      onSubmit: send, onEscape: { chat.interrupt() }, register: { chat.inputView = $0 })
                .frame(height: min(max(inputHeight, line), 240))
            HStack(spacing: 10) {
                if chat.busy, let start = chat.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(ctx.date.timeIntervalSince(start))).foregroundStyle(TUIColor.dim).monospacedDigit()
                    }
                }
                Menu {
                    ForEach(chat.modes, id: \.id) { m in
                        Button { chat.setPermissionMode(m.id) } label: { Label(m.label, systemImage: m.icon) }
                    }
                } label: {
                    Label(modeLabel, systemImage: modeIcon)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(TUIColor.dim)
                .help("Permission mode")
                Button(action: { chat.busy && draft.isEmpty ? chat.interrupt() : send() }) {
                    Image(systemName: chat.busy && draft.isEmpty ? "stop.fill" : "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SwiftUI.Color(nsColor: Theme.background))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(TUIColor.fg.opacity(draft.isEmpty && !chat.busy ? 0.25 : 0.9)))
                }
                .buttonStyle(.plain)
                .help(chat.busy && draft.isEmpty ? "Stop (esc)" : "Send (↵)")
            }
            .font(.system(size: size - 1, design: .monospaced))
            .frame(height: line)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SwiftUI.Color(nsColor: Theme.background))
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.send(draft)
        draft = ""
    }

    private var modeLabel: String {
        chat.modes.first { $0.id == chat.permissionMode }?.label ?? (chat.permissionMode == "auto" ? "Auto" : "Supervised")
    }
    private var modeIcon: String {
        chat.modes.first { $0.id == chat.permissionMode }?.icon ?? "hand.raised"
    }
}

func elapsed(_ s: Double) -> String {
    let t = Int(s)
    return t < 60 ? "\(t)s" : "\(t / 60)m \(t % 60)s"
}

// MARK: - One turn

private struct TurnView: View {
    let turn: NativeChatView.Turn
    @ObservedObject var chat: NativeChat
    let size: CGFloat
    let live: Bool
    @State private var showWork = false

    private var fg: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.foreground) }
    private var hasPending: Bool { turn.work.contains { if case .permission = $0.kind { return $0.decided == nil }; return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = turn.prompt, case .user(let text) = p.kind {
                // like the TUI: your message on a full-width band, after a ">"
                VStack(alignment: .leading, spacing: 8) {
                    if !text.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(">")
                            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !p.images.isEmpty { ImageStrip(images: p.images).padding(.leading, text.isEmpty ? 0 : 16) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TUIColor.promptBand)
            }

            if !turn.work.isEmpty {
                // While Claude works (or needs you), the log is open; once the answer is out it folds away.
                let open = live || hasPending || showWork
                VStack(alignment: .leading, spacing: 4) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { showWork.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                            Text(workSummary)
                        }
                        .foregroundStyle(TUIColor.dim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(live || hasPending)

                    if open {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(turn.work) { item in workRow(item) }
                        }
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) { fg.opacity(0.12).frame(width: 1) }
                        .transition(.opacity)
                    } else if !workImages.isEmpty {
                        // screenshots and other images stay in view when the log folds away
                        ImageStrip(images: workImages).padding(.leading, 14)
                    }
                }
            }

            ForEach(turn.answer) { item in
                if case .text(let t) = item.kind { Answer(text: t, size: size) }
            }
            if live && !chat.streaming.isEmpty {
                Answer(text: chat.streaming, size: size)
            } else if live && turn.answer.isEmpty && turn.work.isEmpty {
                HStack(spacing: 8) { ClaudeSpinner(); Text("Thinking…").foregroundStyle(TUIColor.dim) }
            }
        }
    }

    private var workImages: [ChatImage] { turn.work.flatMap(\.images) }

    private var workSummary: String {
        let steps = turn.work.filter { if case .tool = $0.kind { return true }; return false }.count
        if live { return hasPending ? "Waiting for your approval" : "Working · \(steps) step\(steps == 1 ? "" : "s")" }
        let time = turn.end?.duration.map { "Worked for " + elapsed($0) } ?? "Worked"
        return "\(time) · \(steps) step\(steps == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func workRow(_ item: ChatItem) -> some View {
        switch item.kind {
        case .tool(_, let name, let summary):
            ToolRow(name: name, summary: summary, output: item.output, isError: item.isError, images: item.images, size: size)
        case .permission(_, let tool, let summary, let input):
            PermissionRow(item: item, tool: tool, summary: summary, input: input, chat: chat)
        case .text(let t):
            Text(t.replacingOccurrences(of: "\n", with: " "))
                .foregroundStyle(TUIColor.dim).lineLimit(2)
                .padding(.leading, 8)
        default:
            EmptyView()
        }
    }
}

// MARK: - Work log rows

/// One line per tool call, as the TUI draws it: `● Name(target)`, the dot green when it worked and red when it
/// failed. Click to see its output; images it returned (screenshots) show underneath.
private struct ToolRow: View {
    let name: String
    let summary: String
    let output: String?
    let isError: Bool
    let images: [ChatImage]
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Group {
                    if output == nil { ClaudeSpinner(size: 10) }
                    else { Text("●").foregroundStyle(isError ? TUIColor.error : TUIColor.success) }
                }
                .frame(width: 14)
                (Text(name).bold() + Text(summary.isEmpty ? "" : "(\(summary))").foregroundColor(TUIColor.dim))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if output?.isEmpty == false { expanded.toggle() } }
            .padding(.leading, 8)

            if expanded, let out = output {
                ScrollView {
                    Text(out).font(.system(size: size - 1, design: .monospaced))
                        .foregroundStyle(isError ? TUIColor.error : TUIColor.dim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.05)))
                .padding(.leading, 30)
            }
            if !images.isEmpty { ImageStrip(images: images).padding(.leading, 30) }
        }
    }
}

/// Claude's prose after a ●, the way the TUI marks its messages.
private struct Answer: View {
    let text: String
    let size: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("●").foregroundStyle(TUIColor.fg)
            MarkdownView(text: text, size: size)
        }
    }
}

/// Thumbnails of a message's images; click one to see it full size.
private struct ImageStrip: View {
    let images: [ChatImage]
    @Environment(\.zoomImage) private var zoom
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { img in
                    if let ns = img.image {
                        Image(nsImage: ns).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: 320, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SwiftUI.Color(nsColor: Theme.paneDivider)))
                            .contentShape(Rectangle())
                            .onTapGesture { zoom(img) }
                            .modifier(PointingHandCursor())
                            .help("Click to enlarge")
                    }
                }
            }
        }
    }
}

/// An image full size, as large as the screen allows; esc, click or Close dismisses it.
private struct ImageModal: View {
    let image: ChatImage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let ns = image.image
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let natural = ns?.size ?? .zero
        let scale = min(1, (screen.width * 0.85) / max(natural.width, 1), (screen.height * 0.8) / max(natural.height, 1))
        VStack(spacing: 0) {
            if let ns {
                Image(nsImage: ns).resizable().interpolation(.high).scaledToFit()
                    .frame(width: max(natural.width * scale, 200), height: max(natural.height * scale, 120))
                    .onTapGesture { dismiss() }
            }
            HStack {
                Text("\(Int(natural.width)) × \(Int(natural.height))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    if let ns { NSPasteboard.general.writeObjects([ns]) }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .background(SwiftUI.Color(nsColor: Theme.background))
    }
}

/// Inline approval under the command it's about: Decline / Approve.
private struct PermissionRow: View {
    let item: ChatItem
    let tool: String
    let summary: String
    let input: String
    @ObservedObject var chat: NativeChat
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").foregroundStyle(NeedsYouDot.red).font(.system(size: 10.5)).frame(width: 14)
                Text("\(tool) wants to run").foregroundStyle(.secondary)
            }
            Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.05)))
            if details { Text(input).foregroundStyle(.secondary).font(.system(size: 11, design: .monospaced)) }
            if let d = item.decided {
                Text(d ? "Approved" : "Declined").foregroundStyle(d ? .green : NeedsYouDot.red)
            } else {
                HStack(spacing: 8) {
                    Button("Decline") { chat.answer(item, allow: false) }
                    Button("Approve") { chat.answer(item, allow: true) }.keyboardShortcut(.defaultAction)
                    Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(item.decided == nil ? NeedsYouDot.red.opacity(0.5) : SwiftUI.Color(nsColor: Theme.paneDivider)))
        .padding(.leading, 8)
    }
}

// MARK: - Markdown

/// Block-level markdown: headings, lists, quotes and fenced code; inline styles via AttributedString.
struct MarkdownView: View {
    let text: String
    let size: CGFloat

    enum Block: Hashable { case para(String), heading(String, Int), code(String, String),
                           bullet(marker: String, text: String, indent: Int), rule,
                           table(header: [String], rows: [[String]]) }
    /// A block and whether a blank line came before it in the source. Like the TUI, blocks are spaced by a
    /// full empty line only where the text has one; lines that follow each other (a bold line and its list,
    /// list items) stay together.
    struct Entry: Hashable { let block: Block; let gap: Bool }

    private var lineHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)))
    }

    var body: some View {
        let line = lineHeight
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                block(e.block).padding(.top, i == 0 ? 0 : e.gap ? line : 2)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: Block) -> some View {
        switch b {
        case .para(let s):
            Text(inline(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            // Titles in the proportional system font, sized by level, with room above (GitHub-like rules under H1/H2).
            VStack(alignment: .leading, spacing: 6) {
                Text(inline(s))
                    .font(.system(size: size + (level == 1 ? 10 : level == 2 ? 6 : level == 3 ? 3 : 1),
                                  weight: level <= 2 ? .bold : .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 { SwiftUI.Color(nsColor: Theme.paneDivider).frame(height: 1) }
            }
            .padding(.top, level == 1 ? 18 : level == 2 ? 14 : 10)
            .padding(.bottom, 4)
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(size: size - 0.5, design: .monospaced)).padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.06)))
        case .bullet(let marker, let s, let indent):
            // the TUI's markers: "-" for plain items, the number for ordered ones; wrapped lines hang under the text
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(marker + " ")
                Text(inline(s)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 2 * (size * 0.6))
        case .rule:
            SwiftUI.Color(nsColor: Theme.paneDivider).frame(height: 1)
        case .table(let header, let rows):
            let line = SwiftUI.Color(nsColor: Theme.paneDivider)
            let cols = max(header.count, rows.map(\.count).max() ?? 0)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(inline(c < header.count ? header[c] : "")).bold()
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(SwiftUI.Color(nsColor: Theme.foreground).opacity(0.06))
                        }
                    }
                    line.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                Text(inline(c < row.count ? row[c] : ""))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                        }
                        if i < rows.count - 1 { line.opacity(0.6).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(line))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        // common inline HTML in READMEs: <kbd>⌘K</kbd> → `⌘K`, <br> → newline; other tags stay as text
        let t = s.replacingOccurrences(of: #"<kbd>(.*?)</kbd>"#, with: "`$1`", options: .regularExpression)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        var a = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        // inline code in the TUI's code color
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].foregroundColor = TUIColor.code
        }
        return a
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        var gap = false   // a blank line since the last block
        func add(_ b: Block) { out.append(Entry(block: b, gap: gap)); gap = false }
        var para: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flushPara() { if !para.isEmpty { add(.para(para.joined(separator: "\n"))); para = [] } }
        var tableRows: [[String]]? = nil
        func flushTable() {
            if let t = tableRows, let h = t.first { add(.table(header: h, rows: Array(t.dropFirst()))) }
            tableRows = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code { add(.code(lang, c.joined(separator: "\n"))); code = nil }
                else { flushPara(); code = []; lang = String(trimmed.dropFirst(3)) }
                continue
            }
            if code != nil { code!.append(line); continue }
            if trimmed.isEmpty { flushPara(); flushTable(); if !out.isEmpty { gap = true }; continue }
            // GitHub tables: | a | b |, then |---|---|, then rows
            if trimmed.hasPrefix("|") {
                flushPara()
                let cells = Self.cells(trimmed)
                if tableRows == nil { tableRows = [cells] }
                else if cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { continue }
                else { tableRows!.append(cells) }
                continue
            }
            flushTable()
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                flushPara(); add(.heading(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces), level)); continue
            }
            if trimmed == "---" || trimmed == "***" { flushPara(); add(.rule); continue }
            if let r = trimmed.range(of: #"^([-*+]|\d+\.)\s+"#, options: .regularExpression) {
                flushPara()
                let indent = (line.count - line.drop(while: { $0 == " " }).count) / 2
                let marker = trimmed[r].trimmingCharacters(in: .whitespaces)
                add(.bullet(marker: marker.hasSuffix(".") ? marker : "-", text: String(trimmed[r.upperBound...]), indent: indent))
                continue
            }
            para.append(line)
        }
        if let c = code { add(.code(lang, c.joined(separator: "\n"))) }
        flushPara()
        flushTable()
        return out
    }

    private static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Input

/// Multi-line input: Return sends, Shift-Return inserts a newline, Esc interrupts. Grows with its content.
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let fontSize: CGFloat
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    /// Hands over the text view (to focus it from outside).
    var register: ((NSTextView) -> Void)? = nil

    final class Box: NSTextView {
        var submit: (() -> Void)?
        var escape: (() -> Void)?
        var placeholder = ""
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 36 || e.keyCode == 76 {
                if e.modifierFlags.contains(.shift) { insertNewline(nil) } else { submit?() }
                return
            }
            if e.keyCode == 53 { escape?(); return }
            super.keyDown(with: e)
        }
        override func draw(_ r: NSRect) {
            super.draw(r)
            if string.isEmpty, let f = font {
                (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                                               withAttributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        init(_ p: ChatInput) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            measure(tv)
        }
        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            DispatchQueue.main.async { self.parent.height = h }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = Box()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 1)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        scroll.documentView = tv
        register?(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? Box else { return }
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textColor = Theme.foreground
        tv.insertionPointColor = Theme.accent
        tv.placeholder = placeholder
        tv.submit = onSubmit
        tv.escape = onEscape
        if tv.string != text {
            tv.string = text
            context.coordinator.measure(tv)
            tv.needsDisplay = true
        }
    }
}
