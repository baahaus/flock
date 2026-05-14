import AppKit

class TabBarView: NSView, NSTextFieldDelegate {
    weak var paneManager: PaneManager?
    private var hoveredTab: Int = -1
    private var hoveredClose: Bool = false
    private var hoveredButton: Int = -1
    private var trackingArea: NSTrackingArea?

    private var editField: NSTextField?
    private var editingIndex: Int = -1

    // Hover animation state: per-tab progress 0->1
    private var tabHoverProgress: [Int: CGFloat] = [:]
    // Tab close animation state: per-tab progress 0->1 (1 = fully collapsed)
    private var tabCloseProgress: [Int: CGFloat] = [:]
    private var pendingCloseTabIndices: [Int] = []
    private var hoverTimer: Timer?

    // Active indicator layer (renders above draw content — intentional)
    private let activeIndicator = CALayer()
    private var lastActiveIndex: Int = -1

    private let tabH: CGFloat = 30
    private let tabPadL: CGFloat = 12
    private let tabPadR: CGFloat = 8
    private let closeSize: CGFloat = 18
    private let closeGap: CGFloat = 4
    private let tabGap: CGFloat = 2

    private let brandText = "flock"
    private let brandGap:  CGFloat = Theme.Space.xl

    // Dynamic left padding to clear traffic light buttons in fullSizeContentView mode
    private var brandPadL: CGFloat {
        guard let window = window else { return 78 }
        // In fullscreen the traffic lights are hidden -- use minimal padding
        if window.styleMask.contains(.fullScreen) {
            return 16
        }
        let zoomBtn = window.standardWindowButton(.zoomButton)
            ?? window.standardWindowButton(.miniaturizeButton)
            ?? window.standardWindowButton(.closeButton)
        guard let btn = zoomBtn else { return 78 }
        // Get the button's right edge in window coordinates
        if let superview = btn.superview {
            let btnInSuper = btn.frame
            // The traffic light buttons are in a container -- use the button's
            // position within its container, not the container's frame
            let rightEdge = superview.convert(CGPoint(x: btnInSuper.maxX, y: 0), to: self).x
            if rightEdge > 0 && rightEdge < 200 {
                return rightEdge + 12
            }
        }
        // Hardcoded fallback: standard traffic light width is ~68pt
        return 78
    }

    // Vertical center aligned with traffic light buttons (not full bounds center)
    private var contentCenterY: CGFloat {
        guard let window = window,
              !window.styleMask.contains(.fullScreen),
              let closeBtn = window.standardWindowButton(.closeButton) else {
            return bounds.height / 2
        }
        // Get the traffic light's vertical center in tab bar coordinates
        if let superview = closeBtn.superview {
            let btnCenter = superview.convert(
                CGPoint(x: 0, y: closeBtn.frame.midY),
                to: self
            ).y
            if btnCenter > 0 && btnCenter < bounds.height {
                return btnCenter
            }
        }
        return bounds.height / 2
    }

    override var isFlipped: Bool { true }

    init(paneManager: PaneManager) {
        self.paneManager = paneManager
        super.init(frame: .zero)
        wantsLayer = true
        // Semi-transparent so the NSVisualEffectView behind shows through
        layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.97).cgColor

        // Active indicator: thin bar under active tab
        activeIndicator.backgroundColor = Theme.accent.cgColor
        activeIndicator.cornerRadius = 1
        activeIndicator.isHidden = true
        layer?.addSublayer(activeIndicator)

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.themeDidChange, object: nil)
    }

    @objc private func themeChanged() {
        layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.97).cgColor
        activeIndicator.backgroundColor = Theme.accent.cgColor
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        hoverTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func update() {
        updateActiveIndicator()
        needsDisplay = true
    }

    // MARK: - Active Indicator

    private func updateActiveIndicator() {
        guard let mgr = paneManager, let ati = mgr.activeTabIndex else {
            activeIndicator.isHidden = true
            return
        }
        let frames = tabFrames()
        guard ati < frames.count else {
            activeIndicator.isHidden = true
            return
        }

        let rect = frames[ati]
        let inset: CGFloat = 8
        let indicatorFrame = CGRect(
            x: rect.origin.x + inset,
            y: rect.maxY,
            width: rect.width - inset * 2,
            height: 2
        )

        activeIndicator.isHidden = false

        if lastActiveIndex != ati && lastActiveIndex >= 0 {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.Anim.normal)
            CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
            activeIndicator.frame = indicatorFrame
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            activeIndicator.frame = indicatorFrame
            CATransaction.commit()
        }

        lastActiveIndex = ati
    }

    // MARK: - Hover Animation

    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickHover()
        }
    }

    private func tickHover() {
        guard let mgr = paneManager else { return }
        var changed = false
        let step: CGFloat = 0.15  // converges in ~6-7 frames ~ 0.1s

        // Animate hover toward targets
        for i in 0..<mgr.tabNodes.count {
            let target: CGFloat = (i == hoveredTab) ? 1.0 : 0.0
            let current = tabHoverProgress[i] ?? 0.0
            let diff = target - current

            if abs(diff) < 0.01 {
                if tabHoverProgress[i] != target {
                    tabHoverProgress[i] = target
                    changed = true
                }
            } else {
                tabHoverProgress[i] = current + diff * step
                changed = true
            }
        }

        // Animate tab close progress
        let closeStep: CGFloat = 0.12  // converges in ~8 frames ~ 0.13s
        var completed: [Int] = []
        for idx in tabCloseProgress.keys {
            let current = tabCloseProgress[idx] ?? 0.0
            let diff = 1.0 - current
            if abs(diff) < 0.01 {
                tabCloseProgress[idx] = 1.0
                completed.append(idx)
                changed = true
            } else {
                tabCloseProgress[idx] = current + diff * closeStep
                changed = true
            }
        }

        // Clean up completed close animations
        for idx in completed {
            tabCloseProgress.removeValue(forKey: idx)
        }
        if !completed.isEmpty {
            // The actual close already happened; just stop tracking
            pendingCloseTabIndices.removeAll(where: { completed.contains($0) })
        }

        if changed {
            needsDisplay = true
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    /// Begin close animation for a tab index (called before the actual data is removed).
    func animateTabClose(at index: Int) {
        tabCloseProgress[index] = 0.0
        pendingCloseTabIndices.append(index)
        startHoverAnimation()
    }

    // Tab drag reorder state
    private struct TabDragState {
        let sourceIndex: Int
        let startX: CGFloat
        var currentX: CGFloat
        var didPassThreshold: Bool = false
    }
    private var dragState: TabDragState?

    // MARK: - Label

    private func tabLabel(for index: Int, node: SplitNode) -> String {
        // Show the focused pane's name if it's in this node, else first leaf
        let leaves = node.allLeaves
        let mgr = paneManager
        let activePaneInNode: FlockPane? = {
            guard let mgr = mgr, mgr.activePaneIndex >= 0, mgr.activePaneIndex < mgr.panes.count else { return nil }
            let active = mgr.panes[mgr.activePaneIndex]
            return leaves.contains(where: { $0 === active }) ? active : nil
        }()
        let pane = activePaneInNode ?? leaves.first
        let name = pane?.customName ?? pane?.processTitle ?? pane?.paneType.label ?? "pane"
        let suffix = node.leafCount > 1 ? " (\(node.leafCount))" : ""
        return "\(index + 1)  \(name)\(suffix)"
    }

    // MARK: - Geometry

    private var tabsOriginX: CGFloat {
        let bw = brandText.size(withAttributes: [.font: Theme.Typo.brand, .kern: Theme.Typo.brandKern]).width
        return brandPadL + bw + brandGap
    }

    private func tabFrames() -> [CGRect] {
        guard let mgr = paneManager else { return [] }

        // Calculate natural widths first
        let y = contentCenterY - tabH / 2
        var naturalWidths: [CGFloat] = []
        for (i, node) in mgr.tabNodes.enumerated() {
            let label = tabLabel(for: i, node: node)
            let font = Theme.Typo.tabActive
            let labelW = label.size(withAttributes: [.font: font]).width
            naturalWidths.append(tabPadL + labelW + closeGap + closeSize + tabPadR)
        }

        // Available width for tabs (between brand and action buttons)
        let btns = buttonFrames()
        let availableWidth = btns.claude.origin.x - tabsOriginX - Theme.Space.sm
        let totalNatural = naturalWidths.reduce(0, +) + CGFloat(max(0, naturalWidths.count - 1)) * tabGap
        let minTabWidth: CGFloat = 80

        // Progressive compression if tabs overflow
        var widths = naturalWidths
        if totalNatural > availableWidth && !widths.isEmpty {
            let totalGaps = CGFloat(max(0, widths.count - 1)) * tabGap
            let maxPerTab = (availableWidth - totalGaps) / CGFloat(widths.count)
            widths = widths.map { max(minTabWidth, min($0, maxPerTab)) }
        }

        var frames: [CGRect] = []
        var x = tabsOriginX
        for (i, w) in widths.enumerated() {
            let closeP = tabCloseProgress[i] ?? 0.0
            let effectiveW = w * (1.0 - closeP)
            let effectiveGap = tabGap * (1.0 - closeP)
            frames.append(CGRect(x: x, y: y, width: effectiveW, height: tabH))
            x += effectiveW + effectiveGap
        }
        return frames
    }

    private func closeButtonRect(for tabRect: CGRect) -> CGRect {
        CGRect(
            x: tabRect.maxX - closeSize - tabPadR,
            y: tabRect.midY - closeSize / 2,
            width: closeSize,
            height: closeSize
        )
    }

    private func buttonFrames() -> (claude: CGRect, shell: CGRect) {
        let btnH: CGFloat = 26
        let y = contentCenterY - btnH / 2
        let shellW = "+ shell".size(withAttributes: [.font: Theme.Typo.button]).width + 20
        let claudeW = "+ claude".size(withAttributes: [.font: Theme.Typo.button]).width + 20
        let shellX = bounds.width - shellW - Theme.Space.lg
        let claudeX = shellX - claudeW - Theme.Space.sm
        return (
            CGRect(x: claudeX, y: y, width: claudeW, height: btnH),
            CGRect(x: shellX, y: y, width: shellW, height: btnH)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let mgr = paneManager else { return }

        // Chrome background (semi-transparent for vibrancy)
        ctx.setFillColor(Theme.chrome.withAlphaComponent(0.97).cgColor)
        ctx.fill(bounds)

        // Bottom divider — gradient fade at edges
        drawGradientDivider(ctx: ctx, y: bounds.height - 0.5, width: bounds.width)

        // Brand wordmark
        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Typo.brand,
            .foregroundColor: Theme.textPrimary,
            .kern: Theme.Typo.brandKern,
        ]
        let brandSz = brandText.size(withAttributes: brandAttrs)
        brandText.draw(
            at: NSPoint(x: brandPadL, y: contentCenterY - brandSz.height / 2),
            withAttributes: brandAttrs
        )

        // Tabs — one per tabNode
        let frames = tabFrames()
        let activeTabIdx = mgr.activeTabIndex
        let dragOffset: CGFloat
        if let ds = dragState, ds.didPassThreshold {
            dragOffset = ds.currentX - ds.startX
        } else {
            dragOffset = 0
        }

        for (i, node) in mgr.tabNodes.enumerated() {
            guard i < frames.count else { break }
            if i == editingIndex { continue }

            var rect = frames[i]
            let isDragged = dragState?.sourceIndex == i && dragState?.didPassThreshold == true

            // Offset the dragged tab to follow the cursor
            if isDragged {
                rect.origin.x += dragOffset
            }
            let closeP = tabCloseProgress[i] ?? 0.0
            let active = (i == activeTabIdx)
            let hovered = (i == hoveredTab)
            let hoverAlpha = tabHoverProgress[i] ?? 0.0

            // Skip fully collapsed tabs
            if closeP >= 0.99 { continue }

            // Apply alpha for closing tabs
            if closeP > 0.01 {
                ctx.saveGState()
                ctx.setAlpha(1.0 - closeP)
                ctx.clip(to: rect)
            }

            // Dragged tab: draw elevated with shadow
            if isDragged {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6,
                              color: NSColor.black.withAlphaComponent(0.2).cgColor)
            }

            // Tab background
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if isDragged || active {
                Theme.surface.setFill()
                bgPath.fill()
            } else if hoverAlpha > 0.01 {
                Theme.hover.withAlphaComponent(hoverAlpha).setFill()
                bgPath.fill()
            }

            if isDragged {
                ctx.restoreGState()
            }

            // Label
            let label = tabLabel(for: i, node: node)
            let leaves = node.allLeaves
            let agentWorking = leaves.contains(where: { $0.isAgentActive }) && Settings.shared.showActivityIndicators
            let textColor = active ? Theme.textPrimary : Theme.textSecondary
            let font = active ? Theme.Typo.tabActive : Theme.Typo.tabRest
            let labelSize = label.size(withAttributes: [.font: font])
            let origin = NSPoint(x: rect.origin.x + tabPadL, y: rect.midY - labelSize.height / 2)
            label.draw(at: origin, withAttributes: [.font: font, .foregroundColor: textColor])

            // Activity dot — discrete colored dot after label when agent is working
            if agentWorking {
                let dotDiameter: CGFloat = 5
                let dotX = origin.x + labelSize.width + 4
                let dotY = rect.midY - dotDiameter / 2
                let dotAlpha = tabHoverProgress[i].map { max(0.6, $0) } ?? 1.0
                Theme.accent.withAlphaComponent(dotAlpha).setFill()
                NSBezierPath(ovalIn: CGRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)).fill()
            }
            // Accent color dot — show first leaf's accent
            if let accent = leaves.first?.accentColor {
                let adotSize: CGFloat = 6
                let adotX = rect.origin.x + 5
                let adotY = rect.midY - adotSize / 2
                accent.setFill()
                NSBezierPath(ovalIn: CGRect(x: adotX, y: adotY, width: adotSize, height: adotSize)).fill()
            }

            // Close button
            if active || hovered {
                let cr = closeButtonRect(for: rect)
                let closeHovered = hovered && hoveredClose

                if closeHovered {
                    let circlePath = NSBezierPath(ovalIn: cr.insetBy(dx: 1, dy: 1))
                    Theme.hover.setFill()
                    circlePath.fill()
                }

                let xColor = closeHovered ? Theme.textPrimary : Theme.textTertiary
                let cx = cr.midX
                let cy = cr.midY
                let s: CGFloat = 3.5
                ctx.setStrokeColor(xColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: cx - s, y: cy - s))
                ctx.addLine(to: CGPoint(x: cx + s, y: cy + s))
                ctx.move(to: CGPoint(x: cx + s, y: cy - s))
                ctx.addLine(to: CGPoint(x: cx - s, y: cy + s))
                ctx.strokePath()
            }

            // Restore state if we were animating close
            if closeP > 0.01 {
                ctx.restoreGState()
            }
        }

        // Action buttons
        let btns = buttonFrames()
        drawActionButton(ctx: ctx, rect: btns.claude, title: "+ claude", hovered: hoveredButton == 0)
        drawActionButton(ctx: ctx, rect: btns.shell, title: "+ shell", hovered: hoveredButton == 1)
    }

    private func drawGradientDivider(ctx: CGContext, y: CGFloat, width: CGFloat) {
        let fadeLen: CGFloat = width * 0.1
        let color = Theme.divider

        for i in 0..<Int(fadeLen) {
            let alpha = CGFloat(i) / fadeLen
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: CGFloat(i), y: y, width: 1, height: 0.5))
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: fadeLen, y: y, width: width - fadeLen * 2, height: 0.5))
        for i in 0..<Int(fadeLen) {
            let alpha = CGFloat(i) / fadeLen
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: width - CGFloat(i) - 1, y: y, width: 1, height: 0.5))
        }
    }

    private func drawActionButton(ctx: CGContext, rect: CGRect, title: String, hovered: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if hovered {
            Theme.hover.setFill()
            path.fill()
        }
        // Subtle border
        Theme.divider.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let color = hovered ? Theme.textPrimary : Theme.textSecondary
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typo.button, .foregroundColor: color]
        let sz = title.size(withAttributes: attrs)
        title.draw(
            at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Inline rename

    func renameActiveTab() {
        guard let mgr = paneManager, let tabIdx = mgr.activeTabIndex else { return }
        beginRename(at: tabIdx)
    }

    private func beginRename(at tabIndex: Int) {
        guard let mgr = paneManager, tabIndex < mgr.tabNodes.count else { return }
        let frames = tabFrames()
        guard tabIndex < frames.count else { return }
        guard let pane = mgr.tabNodes[tabIndex].allLeaves.first else { return }
        commitRename()

        editingIndex = tabIndex
        let rect = frames[tabIndex].insetBy(dx: 4, dy: 3)

        let field = NSTextField(frame: rect)
        field.stringValue = pane.customName ?? pane.paneType.label
        field.font = Theme.Typo.tabActive
        field.textColor = Theme.textPrimary
        field.backgroundColor = Theme.surface
        field.isBordered = false
        field.focusRingType = .none
        field.alignment = .center
        field.delegate = self
        field.target = self
        field.action = #selector(renameAction(_:))
        addSubview(field)
        field.selectText(nil)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
        editField = field
    }

    @objc private func renameAction(_ sender: NSTextField) { commitRename() }

    private func commitRename() {
        guard let field = editField,
              let mgr = paneManager,
              editingIndex >= 0, editingIndex < mgr.tabNodes.count,
              let pane = mgr.tabNodes[editingIndex].allLeaves.first else {
            cleanupEditor(); return
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        pane.customName = text.isEmpty ? nil : text
        cleanupEditor()
        update()
    }

    private func cleanupEditor() {
        editField?.removeFromSuperview()
        editField = nil
        editingIndex = -1
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitRename() }

    // MARK: - Interaction

    override var mouseDownCanMoveWindow: Bool { false }

    // Prevents the window server from claiming this area for titlebar dragging.
    // Required for fullSizeContentView -- mouseDownCanMoveWindow alone is ignored
    // in the titlebar region. Used by Firefox, Chrome, iTerm2, and WebKit.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

    override func mouseDown(with event: NSEvent) {
        guard let mgr = paneManager else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
            for (i, rect) in tabFrames().enumerated() {
                if rect.contains(pt) { beginRename(at: i); return }
            }
        }

        if editField != nil { commitRename() }

        let frames = tabFrames()
        for (i, rect) in frames.enumerated() {
            let isActiveTab = (i == mgr.activeTabIndex)
            if closeButtonRect(for: rect).contains(pt) && (isActiveTab || i == hoveredTab) {
                mgr.closeTab(at: i)
                return
            }
            if rect.contains(pt) {
                // Focus the tab
                if i < mgr.tabNodes.count, let firstPane = mgr.tabNodes[i].allLeaves.first,
                   let paneIdx = mgr.panes.firstIndex(where: { $0 === firstPane }) {
                    mgr.focusPane(at: paneIdx)
                }
                // Enter drag tracking loop if reorderable
                if !mgr.isMaximized && mgr.tabNodes.count > 1 {
                    trackTabDrag(sourceIndex: i, startX: pt.x, initialEvent: event)
                }
                return
            }
        }

        let btns = buttonFrames()
        if btns.claude.contains(pt) { mgr.addPane(type: .claude) }
        else if btns.shell.contains(pt) { mgr.addPane(type: .shell) }
        else { window?.performDrag(with: event) }
    }

    /// Local event-tracking loop for tab drag reorder.
    /// Consumes all mouse events until mouseUp, preventing the titlebar from intercepting.
    private func trackTabDrag(sourceIndex: Int, startX: CGFloat, initialEvent: NSEvent) {
        var currentX = startX
        var didPassThreshold = false

        dragState = TabDragState(sourceIndex: sourceIndex, startX: startX, currentX: startX)

        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let pt = convert(nextEvent.locationInWindow, from: nil)

            switch nextEvent.type {
            case .leftMouseDragged:
                currentX = pt.x
                if !didPassThreshold && abs(currentX - startX) > 3 {
                    didPassThreshold = true
                }
                dragState = TabDragState(
                    sourceIndex: sourceIndex, startX: startX,
                    currentX: currentX, didPassThreshold: didPassThreshold
                )
                if didPassThreshold {
                    needsDisplay = true
                    displayIfNeeded()
                }

            case .leftMouseUp:
                if didPassThreshold {
                    // Compute drop target
                    let frames = tabFrames()
                    var targetIndex = sourceIndex
                    for (i, rect) in frames.enumerated() {
                        if currentX < rect.midX {
                            targetIndex = i
                            break
                        }
                        targetIndex = i + 1
                    }
                    targetIndex = min(targetIndex, (paneManager?.tabNodes.count ?? 1) - 1)
                    targetIndex = max(0, targetIndex)

                    if targetIndex != sourceIndex {
                        paneManager?.reorderPane(from: sourceIndex, to: targetIndex)
                    }
                }
                dragState = nil
                needsDisplay = true
                return

            default:
                break
            }
        }

        // Fallback cleanup
        dragState = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard paneManager != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        for (i, rect) in tabFrames().enumerated() {
            if rect.contains(pt) { showContextMenu(at: i, event: event); return }
        }
    }

    private static let accentPresets: [(name: String, color: NSColor?)] = [
        ("Red", NSColor(hex: 0xFF3B30)),
        ("Orange", NSColor(hex: 0xFF9500)),
        ("Yellow", NSColor(hex: 0xFFCC00)),
        ("Green", NSColor(hex: 0x28CD41)),
        ("Blue", NSColor(hex: 0x007AFF)),
        ("Purple", NSColor(hex: 0xAF52DE)),
        ("None", nil),
    ]

    private func showContextMenu(at index: Int, event: NSEvent) {
        guard let mgr = paneManager, index < mgr.tabNodes.count else { return }
        let menu = NSMenu()

        let rename = NSMenuItem(title: "Rename", action: #selector(ctxRename(_:)), keyEquivalent: "")
        rename.target = self; rename.tag = index
        menu.addItem(rename)

        // Split submenu
        let splitH = NSMenuItem(title: "Split Horizontal", action: #selector(ctxSplitH(_:)), keyEquivalent: "")
        splitH.target = self; splitH.tag = index
        menu.addItem(splitH)

        let splitV = NSMenuItem(title: "Split Vertical", action: #selector(ctxSplitV(_:)), keyEquivalent: "")
        splitV.target = self; splitV.tag = index
        menu.addItem(splitV)

        menu.addItem(.separator())

        // Color submenu
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (ci, preset) in Self.accentPresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(ctxSetColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index * 100 + ci  // encode both pane index and color index
            if let c = preset.color {
                let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    c.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
                    return true
                }
                item.image = swatch
            }
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close", action: #selector(ctxClose(_:)), keyEquivalent: "")
        close.target = self; close.tag = index
        menu.addItem(close)

        let closeOthers = NSMenuItem(title: "Close Others", action: #selector(ctxCloseOthers(_:)), keyEquivalent: "")
        closeOthers.target = self; closeOthers.tag = index
        closeOthers.isEnabled = mgr.tabNodes.count > 1
        menu.addItem(closeOthers)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func ctxRename(_ s: NSMenuItem) { beginRename(at: s.tag) }
    @objc private func ctxSplitH(_ s: NSMenuItem) {
        guard let mgr = paneManager, s.tag < mgr.tabNodes.count,
              let firstPane = mgr.tabNodes[s.tag].allLeaves.first,
              let idx = mgr.panes.firstIndex(where: { $0 === firstPane }) else { return }
        mgr.focusPane(at: idx)
        mgr.splitActivePane(direction: .horizontal)
    }
    @objc private func ctxSplitV(_ s: NSMenuItem) {
        guard let mgr = paneManager, s.tag < mgr.tabNodes.count,
              let firstPane = mgr.tabNodes[s.tag].allLeaves.first,
              let idx = mgr.panes.firstIndex(where: { $0 === firstPane }) else { return }
        mgr.focusPane(at: idx)
        mgr.splitActivePane(direction: .vertical)
    }
    @objc private func ctxSetColor(_ s: NSMenuItem) {
        let tabIdx = s.tag / 100
        let colorIndex = s.tag % 100
        guard let mgr = paneManager, tabIdx < mgr.tabNodes.count,
              colorIndex < Self.accentPresets.count else { return }
        // Apply accent to all leaves in this tab
        for pane in mgr.tabNodes[tabIdx].allLeaves {
            pane.accentColor = Self.accentPresets[colorIndex].color
        }
        needsDisplay = true
    }
    @objc private func ctxClose(_ s: NSMenuItem) { paneManager?.closeTab(at: s.tag) }
    @objc private func ctxCloseOthers(_ s: NSMenuItem) {
        guard let mgr = paneManager, s.tag < mgr.tabNodes.count else { return }
        // Capture the node to keep by identity, then close everything else
        let keepNode = mgr.tabNodes[s.tag]
        while mgr.tabNodes.count > 1 {
            guard let idx = mgr.tabNodes.firstIndex(where: { $0 !== keepNode }) else { break }
            mgr.closeTab(at: idx)
        }
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let mgr = paneManager else { return }
        let pt = convert(event.locationInWindow, from: nil)

        var newTab = -1
        var newClose = false
        for (i, rect) in tabFrames().enumerated() {
            if rect.contains(pt) && i < mgr.tabNodes.count {
                newTab = i
                newClose = closeButtonRect(for: rect).contains(pt)
                break
            }
        }

        var newBtn = -1
        let btns = buttonFrames()
        if btns.claude.contains(pt) { newBtn = 0 }
        else if btns.shell.contains(pt) { newBtn = 1 }

        let tabChanged = newTab != hoveredTab
        let changed = tabChanged || newClose != hoveredClose || newBtn != hoveredButton

        hoveredTab = newTab
        hoveredClose = newClose
        hoveredButton = newBtn

        if tabChanged {
            startHoverAnimation()
        }

        if changed {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        let tabChanged = hoveredTab != -1
        hoveredTab = -1
        hoveredClose = false
        hoveredButton = -1
        if tabChanged { startHoverAnimation() }
        needsDisplay = true
    }
}
