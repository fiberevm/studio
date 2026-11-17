import SwiftUI

/// One editor group: a tab strip plus the pane showing its selected tab (VS Code's "editor group").
final class GroupNode: Identifiable {
    let id = UUID()
    var tabIds: [UUID]
    /// "t:<terminal uuid>" or "s:<session id>" (a session running outside the app, shown as an info pane)
    var selection: String?
    init(tabIds: [UUID] = [], selection: String? = nil) { self.tabIds = tabIds; self.selection = selection }
}

/// Children laid out side by side (.horizontal) or stacked (.vertical), each with a fraction of the space.
final class SplitBox: Identifiable {
    let id = UUID()
    let axis: Axis
    var children: [LayoutNode]
    var fractions: [CGFloat]
    init(axis: Axis, children: [LayoutNode]) {
        self.axis = axis
        self.children = children
        self.fractions = Array(repeating: 1 / CGFloat(children.count), count: children.count)
    }
}

enum LayoutNode: Identifiable {
    case group(GroupNode)
    case split(SplitBox)

    var id: UUID {
        switch self {
        case .group(let g): return g.id
        case .split(let s): return s.id
        }
    }

    var groups: [GroupNode] {
        switch self {
        case .group(let g): return [g]
        case .split(let s): return s.children.flatMap(\.groups)
        }
    }
}

/// Where a dragged tab lands relative to a group.
enum DropZone: Equatable {
    case center, left, right, top, bottom

    var axis: Axis? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }
    var before: Bool { self == .left || self == .top }

    /// VS Code-style snapping: the outer third of each side splits that way, the middle drops into the group.
    static func at(_ p: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = p.x / size.width, y = p.y / size.height
        let edge: CGFloat = 0.33
        // pick the nearest edge if inside its band
        let candidates: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        if let (zone, d) = candidates.min(by: { $0.1 < $1.1 }), d < edge { return zone }
        return .center
    }
}

// MARK: - Saving the layout across launches

/// Serializable form of a window's layout. Tabs are stored by Claude session id (plain terminals aren't kept).
indirect enum SavedLayout: Codable {
    case group(tabs: [String], selected: String?, active: Bool)
    case split(horizontal: Bool, fractions: [Double], children: [SavedLayout])

    static func key(_ folder: String) -> String { "layout:" + folder }

    static func load(_ folder: String) -> SavedLayout? {
        guard let data = UserDefaults.standard.data(forKey: key(folder)) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    /// Every tab token in this layout (session ids, and "shell:<cwd>" for terminals).
    var tabs: [String] {
        switch self {
        case .group(let t, _, _): return t
        case .split(_, _, let children): return children.flatMap(\.tabs)
        }
    }

    /// Which window a saved session belongs to: the folder whose saved layout lists it, if any.
    static func owner(of sid: String) -> String? {
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix("layout:") {
            guard let data = v as? Data, let l = try? JSONDecoder().decode(SavedLayout.self, from: data) else { continue }
            if l.tabs.contains(sid) { return String(k.dropFirst("layout:".count)) }
        }
        return nil
    }

    func save(_ folder: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(folder)) }
    }
}
