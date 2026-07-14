import AppKit

/// Horizontal switcher showing one chip per workspace (click to switch,
/// double-click to rename) plus a "+" to create a new one. Sits just below the
/// tab bar.
final class WorkspaceBarView: NSView {
    static let height: CGFloat = 28
    weak var paneManager: PaneManager?

    private var chipRects: [(rect: NSRect, index: Int)] = []
    private var plusRect: NSRect = .zero
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override var isFlipped: Bool { true }

    init(paneManager: PaneManager) {
        self.paneManager = paneManager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        layer?.backgroundColor = Theme.chrome.cgColor
        needsDisplay = true
    }

    func update() { needsDisplay = true }

    private func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mgr = paneManager else { return }
        chipRects.removeAll()

        let chipH: CGFloat = 20
        let y = (bounds.height - chipH) / 2
        var x: CGFloat = Theme.Space.md

        for (i, ws) in mgr.workspaces.enumerated() {
            let isActive = ws === mgr.activeWorkspace
            let textColor = isActive ? Theme.textPrimary : Theme.textSecondary
            let textAttrs = attrs(textColor)
            let size = (ws.name as NSString).size(withAttributes: textAttrs)
            let chipW = ceil(size.width) + Theme.Space.md * 2
            let rect = NSRect(x: x, y: y, width: chipW, height: chipH)

            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if isActive {
                Theme.surface.setFill()
                path.fill()
                path.lineWidth = 1
                Theme.accent.withAlphaComponent(0.7).setStroke()
                path.stroke()
            }
            (ws.name as NSString).draw(
                at: NSPoint(x: rect.minX + Theme.Space.md, y: rect.midY - size.height / 2),
                withAttributes: textAttrs)

            chipRects.append((rect, i))
            x += chipW + Theme.Space.sm
        }

        // "+" button
        plusRect = NSRect(x: x, y: y, width: chipH, height: chipH)
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: Theme.textTertiary,
        ]
        let ps = ("+" as NSString).size(withAttributes: plusAttrs)
        ("+" as NSString).draw(
            at: NSPoint(x: plusRect.midX - ps.width / 2, y: plusRect.midY - ps.height / 2),
            withAttributes: plusAttrs)

        // Bottom hairline
        Theme.divider.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        line.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let mgr = paneManager else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if plusRect.contains(pt) {
            mgr.addWorkspace()
            return
        }
        for (rect, index) in chipRects where rect.contains(pt) {
            mgr.switchToWorkspace(at: index)
            if event.clickCount >= 2 {
                // Rename the (now active) workspace via the app delegate dialog.
                NSApp.sendAction(#selector(AppDelegate.renameWorkspace(_:)), to: nil, from: self)
            }
            return
        }
    }
}
