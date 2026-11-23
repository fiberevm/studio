import SwiftUI

/// A saved prompt, e.g. #tests → "Run the tests and fix any failures."
struct Snippet: Codable, Hashable, Identifiable {
    var name: String
    var text: String
    var id: String { name }
}

/// Snippets live in a JSON file so they're easy to edit by hand (Command Palette → "Snippets: Edit…").
enum Snippets {
    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }

    static let defaults: [Snippet] = [
        .init(name: "review", text: "Review your changes so far for bugs and anything you'd simplify, then fix what you find."),
        .init(name: "tests", text: "Run the tests and fix any failures."),
        .init(name: "pr", text: "Commit your work and open a PR with a clear description."),
        .init(name: "rebase", text: "Rebase this branch on main and resolve any conflicts."),
        .init(name: "summary", text: "Summarize what you changed and why, in five bullets."),
        .init(name: "continue", text: "Continue."),
    ]

    static var all: [Snippet] {
        get {
            if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Snippet].self, from: data) { return list }
            save(defaults)
            return defaults
        }
        set { save(newValue) }
    }

    private static func save(_ list: [Snippet]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(list).write(to: file, options: .atomic)
    }

    /// Names a snippet after its first words: "Run the tests and…" → "run-the-tests".
    static func add(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(3)
        var name = words.joined(separator: "-")
        if name.isEmpty { name = "snippet" }
        var list = all
        var unique = name, n = 2
        while list.contains(where: { $0.name == unique }) { unique = "\(name)-\(n)"; n += 1 }
        list.append(.init(name: unique, text: text))
        all = list
        return unique
    }
}

/// ⇧⌘K: type a message and send it to a session without switching to it, to several at once, or to a new session.
/// The list starts with what a new tab can be (a session per installed agent, a terminal, a web browser), then
/// the open sessions; the highlight starts on the first session, so ↵ still sends to the current one.
///   ↵ send to the highlighted session (or to every ticked one), or open the highlighted new tab with the text
///   (a session's first message, a terminal's command, a browser's address)   ⇥ tick/untick for broadcast
///   ⌘↵ start a new session with it   #name inserts a snippet   ⌘S saves the text as a snippet
struct QuickPrompt: View {
    @EnvironmentObject var model: ProjectModel
    @State private var text = ""
    @State private var index = 0
    @State private var ticked: [UUID] = []
    /// The "new tab" rows above the sessions; `index` runs over these, then the sessions.
    @State private var kinds: [NewTabKind] = []
    @FocusState private var focused: Bool
    @StateObject private var keys = KeyMonitor()

    var body: some View {
        let targets = model.quickTargets
        let snippets = snippetMatches
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder(targets), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(SwiftUI.Color(nsColor: Theme.background))
                .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.accent), lineWidth: 1))
                .padding(6)
                .focused($focused)
                .onChange(of: text) { old, _ in
                    // the snippet list and the main list share `index`: start each at its natural first row
                    if !snippetMatches.isEmpty { index = 0 }
                    else if old.hasPrefix("#"), !old.contains(" ") { index = model.quickTargets.isEmpty ? 0 : kinds.count }
                }

            if !snippets.isEmpty {
                header("SNIPPETS")
                ForEach(Array(snippets.enumerated()), id: \.element.id) { i, s in
                    row(selected: i == index) {
                        Text("#" + s.name).font(.system(size: 13))
                        Text(s.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .onTapGesture { insert(s) }
                }
            } else {
                header("NEW")
                ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                    row(selected: i == index) {
                        Image(systemName: k.icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                        Text(k.title).font(.system(size: 13))
                        Spacer(minLength: 8)
                        Text(i == 0 ? "⌘N" : k.keyLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .onTapGesture { index = i; open(k) }
                }
                if !targets.isEmpty {
                    header(ticked.isEmpty ? "SEND TO" : "SEND TO \(ticked.count) SESSIONS")
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                                targetRow(t, selected: i + kinds.count == index)
                                    .onTapGesture { index = i + kinds.count }
                            }
                        }
                    }
                    .frame(maxHeight: 26 * 10)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("↵ send or open   ⇥ add to broadcast   ⌘↵ new session   #  snippets   ⌘S save as snippet   esc close")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 620)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onAppear {
            focused = true
            kinds = NewTabKind.available
            index = model.quickTargets.isEmpty ? 0 : kinds.count    // the current session, as before
            keys.start { e in
                let cmd = e.modifierFlags.contains(.command)
                let list = snippetMatches.isEmpty ? kinds.count + model.quickTargets.count : snippetMatches.count
                switch e.keyCode {
                case 125: if list > 0 { index = (index + 1) % list }; return true          // ↓
                case 126: if list > 0 { index = (index - 1 + list) % list }; return true   // ↑
                case 53: close(); return true                                             // esc
                case 48:                                                                  // tab
                    if let s = snippetMatches[safe: index] { insert(s) } else { toggleTick() }
                    return true
                case 36, 76:                                                              // return
                    if let s = snippetMatches[safe: index] { insert(s) }
                    else if cmd { newSession() }
                    else { send() }
                    return true
                case 1 where cmd:                                                         // ⌘S
                    saveSnippet(); return true
                default: return false
                }
            }
        }
        .onDisappear { keys.stop() }
    }

    // MARK: Pieces

    private func placeholder(_ targets: [TerminalSession]) -> String {
        if !ticked.isEmpty { return "Message \(ticked.count) sessions…" }
        if let k = kinds[safe: index] {
            switch k {
            case .agent(let a): return "First message for a new \(a.name) session (optional)…"
            case .terminal: return "Command to run in a new terminal (optional)…"
            case .browser: return "Address for a new web browser tab (optional)…"
            case .files: return "Open the project's file tree in a new tab…"
            }
        }
        guard let t = targets[safe: index - kinds.count] else { return "Message…" }
        return "Message \(model.title(of: t))…"
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 2).frame(height: 20)
    }

    private func row<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        // no trailing spacer: a row's own Spacer pushes its last label (shortcut, project) to the right edge
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : .clear, ignoresSafeAreaEdges: [])
            .contentShape(Rectangle())
    }

    private func targetRow(_ t: TerminalSession, selected: Bool) -> some View {
        let item = model.item(for: t)
        let on = ticked.contains(t.id)
        return row(selected: selected) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(on ? SwiftUI.Color(nsColor: Theme.accent) : .secondary)
                .onTapGesture { toggle(t.id) }
            StatusDot(status: item?.status ?? .starting,
                      attention: t.sessionId.map(model.store.attention.contains) ?? false, activity: item?.activity)
            Text(model.title(of: t)).font(.system(size: 13)).lineLimit(1)
            if t.id == model.selectedTerminal?.id {
                Text("current").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(projectName(for: t.cwd)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var snippetMatches: [Snippet] {
        guard text.hasPrefix("#"), !text.contains(" ") else { return [] }
        let q = text.dropFirst().lowercased()
        return Snippets.all.filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    // MARK: Actions

    private func insert(_ s: Snippet) {
        text = s.text
        index = model.quickTargets.isEmpty ? 0 : kinds.count
    }

    /// Open a new tab of this kind, handing it the typed text: an agent's first message, a terminal's command,
    /// a browser's address. With no text it's the same as the + menu.
    private func open(_ kind: NewTabKind) {
        let m = message
        close()
        switch kind {
        case .agent(let a):
            if m.isEmpty { model.newTab(a) } else { model.select(model.store.newSession(in: model.folder, prompt: m, agent: a)) }
        case .terminal:
            let t = model.store.newShell(in: model.folder)
            model.select(t)
            if !m.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { t.type(m + "\r") } }
        case .browser:
            let address = m.isEmpty || m.contains(" ") ? nil : URL(string: m.contains("://") ? m : (m.hasPrefix("localhost") ? "http://" : "https://") + m)
            model.openWeb(address, zone: .center)
        case .files:
            model.openFiles()
        }
    }

    private func toggleTick() {
        guard let t = model.quickTargets[safe: index - kinds.count] else { return }
        toggle(t.id)
    }

    private func toggle(_ id: UUID) {
        if let i = ticked.firstIndex(of: id) { ticked.remove(at: i) } else { ticked.append(id) }
    }

    private var message: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        if ticked.isEmpty, let k = kinds[safe: index] { open(k); return }
        guard !message.isEmpty else { return }
        let targets = model.quickTargets
        let chosen = ticked.isEmpty ? targets[safe: index - kinds.count].map { [$0] } ?? [] : targets.filter { ticked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        for t in chosen { t.submit(message) }
        close()
        model.showToast(chosen.count == 1 ? "Sent to \(model.title(of: chosen[0]))" : "Sent to \(chosen.count) sessions")
    }

    private func newSession() {
        guard !message.isEmpty else { return }
        let m = message
        close()
        model.select(model.store.newSession(in: model.folder, prompt: m))
    }

    private func saveSnippet() {
        guard !message.isEmpty, !message.hasPrefix("#") else { return }
        let name = Snippets.add(message)
        model.showToast("Saved snippet #\(name)")
    }

    private func close() {
        model.quickPrompt = false
        model.focusTerminal()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
