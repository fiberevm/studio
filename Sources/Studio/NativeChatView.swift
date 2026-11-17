import SwiftUI
import AppKit

/// Studio's own rendering of a Claude conversation: monospace, quiet, VS Code-like.
struct NativeChatView: View {
    @ObservedObject var chat: NativeChat
    @EnvironmentObject var model: ProjectModel
    @State private var draft = ""
    @State private var inputHeight: CGFloat = 22

    private var font: Font { .system(size: model.store.fontSize, design: .monospaced) }
    private var fg: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.foreground) }
    private var accent: SwiftUI.Color { SwiftUI.Color(nsColor: Theme.accent) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.items) { item in row(item).id(item.id) }
                        if !chat.streaming.isEmpty {
                            markdown(chat.streaming).id("streaming")
                        }
                        if chat.busy {
                            HStack(spacing: 8) {
                                ClaudeSpinner()
                                Text(chat.pendingPermission ? "Waiting for you" : "Working…  esc to interrupt")
                                    .foregroundStyle(.secondary)
                            }
                            .id("busy")
                        }
                        SwiftUI.Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(font)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Hairline()
            input
        }
        .background(SwiftUI.Color(nsColor: Theme.background))
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("❯").foregroundStyle(accent)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fg.opacity(0.06))
        case .text(let text):
            markdown(text)
        case .tool(_, let name, let summary):
            ToolRow(name: name, summary: summary, output: item.output, isError: item.isError, font: font)
        case .permission(_, let tool, let summary, let input):
            PermissionRow(item: item, tool: tool, summary: summary, input: input, chat: chat)
        case .note(let s):
            Text(s).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ s: String) -> some View {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attr).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Input

    private var input: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("❯").font(font).foregroundStyle(accent).padding(.top, 1)
            ChatInput(text: $draft, height: $inputHeight, fontSize: model.store.fontSize,
                      placeholder: chat.exited ? "Session ended — ⌘/ to switch back to the terminal" : "Message Claude…  (⇧↵ new line)",
                      onSubmit: { chat.send(draft); draft = "" },
                      onEscape: { chat.interrupt() })
                .frame(height: min(max(inputHeight, 20), 220))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(SwiftUI.Color(nsColor: Theme.background))
    }
}

/// "● Bash(npm test)" with its output folded under it; click to expand.
private struct ToolRow: View {
    let name: String
    let summary: String
    let output: String?
    let isError: Bool
    let font: Font
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Text("●").foregroundStyle(output == nil ? ClaudeSpinner.orange : isError ? NeedsYouDot.red : .green)
                (Text(name).bold() + Text(summary.isEmpty ? "" : "(\(summary))").foregroundColor(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let out = output, !out.isEmpty {
                let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                let shown = expanded ? lines : Array(lines.prefix(3))
                HStack(alignment: .top, spacing: 6) {
                    Text("⎿").foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shown.joined(separator: "\n")).foregroundStyle(isError ? NeedsYouDot.red.opacity(0.9) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if lines.count > 3 {
                            Text(expanded ? "show less" : "… \(lines.count - 3) more lines")
                                .foregroundStyle(.tertiary)
                                .onTapGesture { expanded.toggle() }
                                .modifier(PointingHandCursor())
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
        .font(font)
    }
}

/// Inline permission ask with Allow / Deny.
private struct PermissionRow: View {
    let item: ChatItem
    let tool: String
    let summary: String
    let input: String
    @ObservedObject var chat: NativeChat
    @State private var showInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                NeedsYouDot()
                Text("Allow ").foregroundStyle(.secondary) + Text(tool).bold() + Text(summary.isEmpty ? "?" : ": \(summary)?")
            }
            if showInput { Text(input).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let d = item.decided {
                Text(d ? "Allowed" : "Denied").foregroundStyle(d ? .green : NeedsYouDot.red)
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { chat.answer(item, allow: true) }
                    Button("Deny") { chat.answer(item, allow: false) }
                    Button(showInput ? "Hide details" : "Details") { showInput.toggle() }.buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(item.decided == nil ? NeedsYouDot.red.opacity(0.6) : SwiftUI.Color(nsColor: Theme.paneDivider)))
    }
}

/// Multi-line input: Return sends, Shift-Return inserts a newline, Esc interrupts. Grows with its content.
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let fontSize: CGFloat
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void

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
                (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                               withAttributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
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
        tv.delegate = context.coordinator
        scroll.documentView = tv
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
