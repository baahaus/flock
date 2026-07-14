import AppKit

/// A named, hot-kept workspace. Each workspace owns its own tab tree and live
/// panes — the pane views and their processes stay alive while the workspace is
/// inactive. Switching workspaces detaches the current panes from the grid and
/// attaches the next workspace's, so running shells, dev servers, and Claude
/// sessions keep going in the background.
final class Workspace {
    let id: String
    var name: String
    var colorHex: Int?
    let createdAt: Date
    var lastUsedAt: Date

    // Live per-workspace state (formerly stored directly on PaneManager).
    var panes: [FlockPane] = []
    var tabNodes: [SplitNode] = []
    var activePaneIndex: Int = -1
    var isMaximized: Bool = false
    var isBroadcasting: Bool = false

    init(id: String = UUID().uuidString,
         name: String,
         colorHex: Int? = nil,
         createdAt: Date = Date(),
         lastUsedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
