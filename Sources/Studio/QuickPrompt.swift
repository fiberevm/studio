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
///   ↵ send to the highlighted session (or to every ticked one)   ⇥ tick/untick for broadcast
///   ⌘↵ start a new session with it   #name inserts a snippet   ⌘S saves the text as a snippet
struct QuickPrompt: View {
    @EnvironmentObject var model: ProjectModel
    @State private var text = ""
    @State private var index = 0
    @State private var ticked: [UUID] = []
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
                .onChange(of: text) { _, _ in if !snippetMatches.isEmpty { index = 0 } }

            if !snippets.isEmpty {
                header("SNIPPETS")
                ForEach(Array(snippets.enumerated()), id: \.element.id) { i, s in
                    row(selected: i == index) {
                        Text("#" + s.name).font(.system(size: 13))
                        Text(s.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .onTapGesture { insert(s) }
                }
            } else if targets.isEmpty {
                Text("No Claude sessions open").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 26)
            } else {
                header(ticked.isEmpty ? "SEND TO" : "SEND TO \(ticked.count) SESSIONS")
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                            targetRow(t, selected: i == index)
                                .onTapGesture { index = i }
                        }
                    }
                }
                .frame(maxHeight: 26 * 10)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("↵ send   ⇥ add to broadcast   ⌘↵ new session   #  snippets   ⌘S save as snippet   esc close")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 620)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onAppear {
            focused = true
            keys.start { e in
                let cmd = e.modifierFlags.contains(.command)
                let list = snippetMatches.isEmpty ? model.quickTargets.count : snippetMatches.count
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
        guard let t = targets[safe: index] else { return "Message…" }
        return "Message \(model.title(of: t))…"
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 2).frame(height: 20)
    }

    private func row<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content(); Spacer(minLength: 0) }
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
        index = 0
    }

    private func toggleTick() {
        guard let t = model.quickTargets[safe: index] else { return }
        toggle(t.id)
    }

    private func toggle(_ id: UUID) {
        if let i = ticked.firstIndex(of: id) { ticked.remove(at: i) } else { ticked.append(id) }
    }

    private var message: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !message.isEmpty else { return }
        let targets = model.quickTargets
        let chosen = ticked.isEmpty ? targets[safe: index].map { [$0] } ?? [] : targets.filter { ticked.contains($0.id) }
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
