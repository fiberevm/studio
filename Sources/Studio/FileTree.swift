import SwiftUI

/// The project's files as a tree, for the Explorer in the sidebar. Folders are read when first expanded and
/// re-read every couple of seconds while the Explorer is showing, so files an agent creates appear on their own.
final class FileTree: ObservableObject {
    struct Row: Identifiable, Equatable {
        let path: String
        let name: String
        let isDir: Bool
        let depth: Int
        let expanded: Bool
        var id: String { path }
    }

    let root: String
    /// The visible rows, top to bottom: every entry whose ancestors are all expanded.
    @Published private(set) var rows: [Row] = []
    private var expanded: Set<String>
    private var defaultsKey: String { "explorerExpanded:" + root }
    /// Never listed (VS Code hides these too).
    private static let hidden: Set<String> = [".git", ".DS_Store", ".svn", ".hg", "Thumbs.db"]

    init(root: String) {
        self.root = root
        expanded = Set(UserDefaults.standard.stringArray(forKey: "explorerExpanded:" + root) ?? [])
        reload()
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) { expanded.remove(dir) } else { expanded.insert(dir) }
        UserDefaults.standard.set(expanded.sorted(), forKey: defaultsKey)
        reload()
    }

    /// Expand the folders leading to `path` (a file inside the project) so its row exists.
    func reveal(_ path: String) {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return }
        var dir = (path as NSString).deletingLastPathComponent, added = false
        while dir.count > root.count, dir.hasPrefix(base) {
            if expanded.insert(dir).inserted { added = true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if added { UserDefaults.standard.set(expanded.sorted(), forKey: defaultsKey); reload() }
    }

    /// Re-read the expanded folders; publishes only when something changed.
    func reload() {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in Self.list(dir) {
                let open = e.isDir && expanded.contains(e.path)
                out.append(Row(path: e.path, name: e.name, isDir: e.isDir, depth: depth, expanded: open))
                if open { walk(e.path, depth + 1) }
            }
        }
        walk(root, 0)
        if out != rows { rows = out }
    }

    /// A folder's entries: folders first, then files, each sorted like Finder (case-insensitive, numbers in order).
    private static func list(_ dir: String) -> [(name: String, path: String, isDir: Bool)] {
        let url = URL(fileURLWithPath: dir)
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.compactMap { u -> (name: String, path: String, isDir: Bool)? in
            let name = u.lastPathComponent
            if hidden.contains(name) { return nil }
            return (name, dir + "/" + name, (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        .sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// The Explorer on the left of a file tab: the project's folders and files laid out like VS Code's (22px rows,
/// chevrons, indent per level, this tab's file highlighted and scrolled into view). Click a file to open it,
/// a folder to expand it; drag its right edge to resize; the status bar's sidebar button hides it.
struct FileExplorer: View {
    @EnvironmentObject var model: ProjectModel
    @ObservedObject var tree: FileTree
    /// The file shown in this tab.
    let active: String?
    /// A file was clicked.
    let onOpen: (String) -> Void
    @AppStorage(FileExplorer.widthKey) private var width = 220.0
    @State private var dragStart: Double?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    static let widthKey = "explorerWidth"
    /// Whether file tabs show the Explorer (the sidebar button in a file tab's status bar).
    static let shownKey = "explorerShown"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(model.name.uppercased()).font(.system(size: 11, weight: .bold)).lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(height: 26)
                .help("Explorer: \(abbreviatePath(model.folder))")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tree.rows) { r in
                                FileTreeRow(row: r, selected: r.path == active)
                                    .onTapGesture { if r.isDir { tree.toggle(r.path) } else { onOpen(r.path) } }
                                    .contextMenu { menu(r) }
                                    .id(r.id)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .onAppear { show(active, proxy) }
                    .onChange(of: active) { _, new in show(new, proxy) }
                }
            }
            .frame(width: width)
            .background(SwiftUI.Color(nsColor: Theme.chrome), ignoresSafeAreaEdges: [])
            // the 1px edge, draggable to resize (like the window's sidebar)
            Hairline(vertical: true)
                .overlay(
                    SwiftUI.Color.clear.frame(width: 7).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let s0 = dragStart ?? width
                                if dragStart == nil { dragStart = s0 }
                                width = min(max(s0 + v.translation.width, 140), 480)
                            }
                            .onEnded { _ in dragStart = nil })
                )
                .zIndex(1)
        }
        .onReceive(tick) { _ in tree.reload() }
    }

    private func show(_ path: String?, _ proxy: ScrollViewProxy) {
        guard let path else { return }
        tree.reveal(path)
        DispatchQueue.main.async { proxy.scrollTo(path, anchor: nil) }   // nil: scroll only if it's out of view
    }

    @ViewBuilder private func menu(_ r: FileTree.Row) -> some View {
        if !r.isDir { Button("Open") { onOpen(r.path) } }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
        Divider()
        Button("Copy Path") { copy(r.path) }
        Button("Copy Relative Path") { copy(relativePath(r.path, to: model.folder)) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct FileTreeRow: View {
    let row: FileTree.Row
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if row.isDir {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else { SwiftUI.Color.clear }
            }
            .frame(width: 12)
            if !row.isDir { FileGlyph(name: row.name) }
            Text(row.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? .primary : SwiftUI.Color.primary.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 10).padding(.trailing, 8)
        .frame(height: 22)
        .background(selected ? SwiftUI.Color(nsColor: Theme.selection) : (hovering ? SwiftUI.Color.primary.opacity(0.05) : .clear),
                    ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(row.path)
    }
}

/// A small colored mark per file type, in the spirit of VS Code's file icons: two or three letters for code
/// ("TS", "JS", "{}"), a symbol for the rest.
private struct FileGlyph: View {
    let name: String

    var body: some View {
        let g = Self.glyph(for: name)
        Group {
            if let text = g.text {
                Text(text).font(.system(size: text.count > 2 ? 7.5 : 9, weight: .bold, design: .rounded)).foregroundStyle(g.color)
            } else {
                Image(systemName: g.symbol).font(.system(size: 10)).foregroundStyle(g.color)
            }
        }
        .frame(width: 16)
    }

    private static func glyph(for name: String) -> (text: String?, symbol: String, color: SwiftUI.Color) {
        let ext = (name as NSString).pathExtension.lowercased()
        let blue = SwiftUI.Color(red: 0.32, green: 0.61, blue: 0.87), yellow = SwiftUI.Color(red: 0.80, green: 0.70, blue: 0.28)
        let green = SwiftUI.Color(red: 0.42, green: 0.69, blue: 0.40), orange = SwiftUI.Color(red: 0.89, green: 0.50, blue: 0.24)
        let red = SwiftUI.Color(red: 0.84, green: 0.36, blue: 0.36), purple = SwiftUI.Color(red: 0.65, green: 0.47, blue: 0.82)
        let grey = SwiftUI.Color.secondary
        switch ext {
        case "swift": return (nil, "swift", orange)
        case "ts", "mts", "cts": return ("TS", "", blue)
        case "tsx": return ("TSX", "", blue)
        case "js", "mjs", "cjs": return ("JS", "", yellow)
        case "jsx": return ("JSX", "", yellow)
        case "json", "jsonc", "json5": return ("{}", "", yellow)
        case "py": return ("PY", "", blue)
        case "go": return ("GO", "", blue)
        case "rs": return ("RS", "", orange)
        case "rb": return ("RB", "", red)
        case "c", "h": return ("C", "", blue)
        case "cpp", "cc", "hpp", "mm", "m": return ("C+", "", blue)
        case "java", "kt": return (ext == "kt" ? "KT" : "J", "", ext == "kt" ? purple : red)
        case "html", "htm", "xml", "svg", "vue", "svelte": return ("<>", "", orange)
        case "css", "scss", "sass", "less": return ("#", "", blue)
        case "md", "mdx", "markdown": return ("MD", "", blue)
        case "sh", "bash", "zsh", "fish": return ("$", "", green)
        case "yml", "yaml", "toml", "ini", "conf", "plist", "env": return (nil, "gearshape", purple)
        case "sql", "db", "sqlite": return (nil, "cylinder", yellow)
        case "png", "jpg", "jpeg", "gif", "webp", "icns", "ico", "tiff", "heic": return (nil, "photo", purple)
        case "mp4", "mov", "webm", "mp3", "wav": return (nil, "play.rectangle", purple)
        case "pdf": return (nil, "doc.richtext", red)
        case "zip", "gz", "tar", "dmg", "tgz": return (nil, "archivebox", grey)
        case "lock", "resolved": return (nil, "lock", grey)
        default: break
        }
        switch name {
        case "Dockerfile": return (nil, "shippingbox", blue)
        case "Makefile": return (nil, "hammer", orange)
        case "LICENSE": return (nil, "checkmark.seal", yellow)
        case ".gitignore", ".gitattributes": return (nil, "arrow.triangle.branch", orange)
        default: return (nil, "doc", grey)
        }
    }
}
