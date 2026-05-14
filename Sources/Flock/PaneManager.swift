import AppKit

enum PaneType {
    case claude, shell, markdown
    var label: String {
        switch self {
        case .claude: return "claude"
        case .shell:  return "shell"
        case .markdown: return "markdown"
        }
    }
}

enum Direction { case left, right, up, down }

class PaneManager {
    private(set) var panes: [FlockPane] = []
    private(set) var activePaneIndex: Int = -1
    private(set) var isMaximized: Bool = false

    weak var tabBar: TabBarView?
    weak var gridContainer: GridContainer?
    weak var statusBar: StatusBarView?

    // Find bar
    private var findBar: FindBarView?

    // Global find
    private let globalFind = GlobalFindView()

    // Broadcast mode
    private(set) var isBroadcasting: Bool = false

    // Split pane tree roots (one per tab)
    private(set) var tabNodes: [SplitNode] = []

    // MARK: - Pane lifecycle

    func addPane(type: PaneType, workingDirectory: String? = nil) {
        assert(Thread.isMainThread, "PaneManager must be accessed from main thread")
        guard type != .markdown else {
            assertionFailure("Use openMarkdownFile(_:) to create markdown panes.")
            return
        }
        let pane = TerminalPane(type: type, manager: self, workingDirectory: workingDirectory)
        panes.append(pane)
        tabNodes.append(SplitNode(pane: pane))
        gridContainer?.addSubview(pane)
        focusPane(at: panes.count - 1)
        layoutAndUpdate(animated: true)
        pane.animateEntrance()
    }

    func closePane(at index: Int) {
        assert(Thread.isMainThread, "PaneManager must be accessed from main thread")
        guard index >= 0, index < panes.count else { return }
        closeFindBar()
        let pane = panes[index]

        // Track desired focus target by identity before mutation
        let wasActive = (index == activePaneIndex)
        let nextFocusPane: FlockPane? = {
            if wasActive {
                // Prefer the pane after, else before
                if index + 1 < panes.count { return panes[index + 1] }
                if index - 1 >= 0 { return panes[index - 1] }
                return nil
            } else if activePaneIndex >= 0, activePaneIndex < panes.count {
                return panes[activePaneIndex]
            }
            return nil
        }()

        // Update tabNodes: remove the pane from its split tree or remove the whole tab
        if let tabIdx = tabNodes.firstIndex(where: { $0.findLeaf(containing: pane) != nil }) {
            if tabNodes[tabIdx].leafCount <= 1 {
                // Only leaf in this tab — remove the entire tab node
                tabBar?.animateTabClose(at: tabIdx)
                tabNodes.remove(at: tabIdx)
            } else {
                // Part of a split — remove pane and promote sibling
                _ = tabNodes[tabIdx].removePaneAndPromoteSibling(pane: pane)
            }
        }

        // Rebuild flat panes array from the updated tree
        rebuildPanesFromNodes()

        // Restore focus by identity
        if activePaneIndex >= 0, activePaneIndex < panes.count {
            panes[activePaneIndex].isFocused = false
        }
        if panes.isEmpty {
            activePaneIndex = -1
        } else if let target = nextFocusPane, let newIdx = panes.firstIndex(where: { $0 === target }) {
            activePaneIndex = newIdx
            panes[newIdx].isFocused = true
            let responder = panes[newIdx].firstResponderView
            responder.window?.makeFirstResponder(responder)
        } else {
            activePaneIndex = min(max(0, activePaneIndex), panes.count - 1)
            panes[activePaneIndex].isFocused = true
            let responder = panes[activePaneIndex].firstResponderView
            responder.window?.makeFirstResponder(responder)
        }
        isMaximized = false

        // Shutdown immediately, then animate exit
        pane.shutdown()
        pane.animateExit { [weak pane] in
            pane?.removeFromSuperview()
        }

        layoutAndUpdate(animated: true)
    }

    func closeActivePane() {
        closePane(at: activePaneIndex)
    }

    func closeTab(at tabIndex: Int) {
        assert(Thread.isMainThread, "PaneManager must be accessed from main thread")
        guard tabIndex >= 0, tabIndex < tabNodes.count else { return }
        tabBar?.animateTabClose(at: tabIndex)
        let leaves = tabNodes[tabIndex].allLeaves
        let activePane: FlockPane? = {
            guard activePaneIndex >= 0, activePaneIndex < panes.count else { return nil }
            return panes[activePaneIndex]
        }()
        let closingIndices = leaves.compactMap { leaf in
            panes.firstIndex(where: { $0 === leaf })
        }
        let nextFocusPane: FlockPane? = {
            guard let activePane else { return nil }
            if leaves.contains(where: { $0 === activePane }) {
                guard let firstClosingIndex = closingIndices.min(),
                      let lastClosingIndex = closingIndices.max() else { return nil }
                if lastClosingIndex + 1 < panes.count {
                    return panes[lastClosingIndex + 1]
                }
                if firstClosingIndex > 0 {
                    return panes[firstClosingIndex - 1]
                }
                return nil
            }
            return activePane
        }()
        tabNodes.remove(at: tabIndex)
        for pane in leaves {
            pane.shutdown()
            pane.animateExit { [weak pane] in
                pane?.removeFromSuperview()
            }
        }
        rebuildPanesFromNodes()
        panes.forEach { $0.isFocused = false }
        if panes.isEmpty {
            activePaneIndex = -1
        } else if let target = nextFocusPane, let newIdx = panes.firstIndex(where: { $0 === target }) {
            activePaneIndex = newIdx
            panes[newIdx].isFocused = true
            let responder = panes[newIdx].firstResponderView
            responder.window?.makeFirstResponder(responder)
        } else {
            activePaneIndex = max(0, min(activePaneIndex, panes.count - 1))
            panes[activePaneIndex].isFocused = true
            let responder = panes[activePaneIndex].firstResponderView
            responder.window?.makeFirstResponder(responder)
        }
        isMaximized = false
        layoutAndUpdate(animated: true)
    }

    func focusPane(at index: Int) {
        assert(Thread.isMainThread, "PaneManager must be accessed from main thread")
        guard index >= 0, index < panes.count else { return }
        if activePaneIndex >= 0, activePaneIndex < panes.count {
            panes[activePaneIndex].isFocused = false
        }
        activePaneIndex = index
        panes[index].isFocused = true
        let responder = panes[index].firstResponderView
        responder.window?.makeFirstResponder(responder)
        closeFindBar()
        tabBar?.update()
        statusBar?.update()
    }

    func toggleMaximize() {
        guard !panes.isEmpty else { return }
        isMaximized.toggle()

        if isMaximized {
            for (i, pane) in panes.enumerated() {
                if i != activePaneIndex {
                    pane.animateFadeOut()
                }
            }
            gridContainer?.layoutPanes(animated: true)
        } else {
            gridContainer?.layoutPanes(animated: true)
            for (i, pane) in panes.enumerated() {
                if i != activePaneIndex {
                    pane.isHidden = false
                    pane.animateFadeIn()
                }
            }
        }
        tabBar?.update()
        statusBar?.update()
    }

    // Tab index for a given pane
    func tabIndex(for pane: FlockPane) -> Int? {
        tabNodes.firstIndex(where: { $0.findLeaf(containing: pane) != nil })
    }

    var activeTabIndex: Int? {
        guard activePaneIndex >= 0, activePaneIndex < panes.count else { return nil }
        return tabIndex(for: panes[activePaneIndex])
    }

    // MARK: - Broadcast

    func toggleBroadcast() {
        isBroadcasting.toggle()
        statusBar?.update()

        // Animate border color changes (constant 1pt width -- no width animation)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.normal)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)

        for pane in panes {
            if isBroadcasting {
                pane.layer?.borderColor = NSColor(hex: 0xFF9500).withAlphaComponent(0.6).cgColor
            } else {
                pane.layer?.borderColor = (pane.isFocused ? Theme.borderFocus : Theme.borderRest).cgColor
            }
        }

        CATransaction.commit()

        // On broadcast enable, pulse the border color briefly
        if isBroadcasting {
            for pane in panes {
                let pulse = CABasicAnimation(keyPath: "borderColor")
                pulse.fromValue = NSColor(hex: 0xFF9500).withAlphaComponent(0.6).cgColor
                pulse.toValue = NSColor(hex: 0xFF9500).withAlphaComponent(0.9).cgColor
                pulse.duration = 0.3
                pulse.autoreverses = true
                pulse.timingFunction = Theme.Anim.snappyTimingFunction
                pane.layer?.add(pulse, forKey: "broadcastPulse")
            }
        }
    }

    // MARK: - Split Panes

    func splitActivePane(direction: SplitDirection) {
        guard activePaneIndex >= 0, activePaneIndex < panes.count else { return }
        let activePane = panes[activePaneIndex]

        // Find the tab node containing this pane
        guard let nodeIndex = tabNodes.firstIndex(where: { $0.findLeaf(containing: activePane) != nil }),
              let leafNode = tabNodes[nodeIndex].findLeaf(containing: activePane) else { return }

        // Create new pane
        let newPane = TerminalPane(type: .shell, manager: self)
        gridContainer?.addSubview(newPane)

        // Split the leaf
        leafNode.split(direction: direction, newPane: newPane)

        // Update flat panes array
        rebuildPanesFromNodes()
        focusPane(at: panes.firstIndex(where: { $0 === newPane }) ?? activePaneIndex)
        layoutAndUpdate(animated: true)
        newPane.animateEntrance()
    }

    private func rebuildPanesFromNodes() {
        panes = tabNodes.flatMap { $0.allLeaves }
    }

    // MARK: - Session Save/Restore

    func openMarkdownFile(_ path: String) {
        let pane = MarkdownPane(filePath: path, manager: self)
        panes.append(pane)
        tabNodes.append(SplitNode(pane: pane))
        gridContainer?.addSubview(pane)
        focusPane(at: panes.count - 1)
        layoutAndUpdate(animated: true)
        pane.animateEntrance()
    }

    func saveSession() {
        // Capture each Claude pane's session ID from its running process before saving
        for pane in panes {
            (pane as? TerminalPane)?.captureSessionId()
        }
        let tabs = tabNodes.map { encodeNode($0) }
        SessionRestore.save(tabs: tabs, activeIndex: activePaneIndex)
    }

    private func encodeNode(_ node: SplitNode) -> SessionNode {
        switch node.content {
        case .leaf(let pane):
            let sp = sessionPane(for: pane)
            return .leaf(sp)
        case .split(let direction, let first, let second):
            let dir = direction == .horizontal ? "horizontal" : "vertical"
            return .split(direction: dir, first: encodeNode(first), second: encodeNode(second), ratio: Double(node.ratio))
        }
    }

    private func sessionPane(for pane: FlockPane) -> SessionPane {
        if let mp = pane as? MarkdownPane {
            return SessionPane(type: "markdown", workingDirectory: mp.filePath, customName: mp.customName, sessionId: nil)
        }
        // Try multiple sources for working directory:
        // 1. OSC 7 reported directory (most accurate when shell is in foreground)
        // 2. CWD from the running process via proc_pidinfo (works even when Claude is active)
        // 3. contextDirectory (the initial directory from pane creation)
        let termPane = pane as? TerminalPane
        let dir = pane.currentDirectory
            ?? termPane?.processWorkingDirectory()
            ?? termPane?.contextDirectory
        // Use the session ID captured from the process's open files at shutdown
        let sessionId: String? = pane.paneType == .claude
            ? termPane?.resumeSessionId ?? "resume"
            : nil
        return SessionPane(
            type: pane.paneType == .claude ? "claude" : "shell",
            workingDirectory: dir,
            customName: pane.customName,
            sessionId: sessionId
        )
    }

    func restoreSession() {
        guard let layout = SessionRestore.restore() else { return }

        if let tabs = layout.tabs {
            // New tree-based restore
            for tab in tabs {
                let node = restoreNode(tab)
                tabNodes.append(node)
                for pane in node.allLeaves {
                    gridContainer?.addSubview(pane)
                }
            }
            rebuildPanesFromNodes()
        } else if let flatPanes = layout.panes {
            // Legacy flat restore
            for sp in flatPanes {
                let pane = restorePane(sp)
                panes.append(pane)
                tabNodes.append(SplitNode(pane: pane))
                gridContainer?.addSubview(pane)
            }
        }

        if layout.activeIndex >= 0, layout.activeIndex < panes.count {
            focusPane(at: layout.activeIndex)
        } else if !panes.isEmpty {
            focusPane(at: 0)
        }
        layoutAndUpdate(animated: false)
    }

    private func restoreNode(_ sessionNode: SessionNode) -> SplitNode {
        switch sessionNode {
        case .leaf(let sp):
            let pane = restorePane(sp)
            return SplitNode(pane: pane)
        case .split(let direction, let first, let second, let ratio):
            let dir: SplitDirection = direction == "horizontal" ? .horizontal : .vertical
            let firstNode = restoreNode(first)
            let secondNode = restoreNode(second)
            let node = SplitNode(direction: dir, first: firstNode, second: secondNode)
            node.ratio = CGFloat(ratio)
            return node
        }
    }

    private func restorePane(_ sp: SessionPane) -> FlockPane {
        if sp.type == "markdown", let path = sp.workingDirectory {
            let pane = MarkdownPane(filePath: path, manager: self)
            pane.customName = sp.customName
            return pane
        }
        let type: PaneType = sp.type == "shell" ? .shell : .claude
        let pane = TerminalPane(type: type, manager: self, workingDirectory: sp.workingDirectory)
        pane.customName = sp.customName
        if type == .claude, let sid = sp.sessionId {
            pane.shouldResume = true
            pane.resumeSessionId = sid
        }
        return pane
    }

    // MARK: - Layout Presets

    func applyPreset(_ preset: LayoutPreset) {
        // Close all existing panes
        for i in stride(from: panes.count - 1, through: 0, by: -1) {
            let pane = panes.remove(at: i)
            pane.shutdown()
            pane.removeFromSuperview()
        }
        tabNodes.removeAll()
        activePaneIndex = -1
        isMaximized = false

        // Create all panes without intermediate layouts
        for type in preset.panes {
            guard type != .markdown else { continue }
            let pane = TerminalPane(type: type, manager: self)
            panes.append(pane)
            tabNodes.append(SplitNode(pane: pane))
            gridContainer?.addSubview(pane)
        }
        if !panes.isEmpty {
            focusPane(at: panes.count - 1)
        }
        // Single layout pass after all panes created
        layoutAndUpdate(animated: true)
        for pane in panes { pane.animateEntrance() }
    }

    // MARK: - Tab Reorder

    func reorderPane(from sourceIndex: Int, to targetIndex: Int) {
        guard sourceIndex != targetIndex,
              sourceIndex >= 0, sourceIndex < tabNodes.count,
              targetIndex >= 0, targetIndex < tabNodes.count else { return }

        // Track active pane before reorder
        let activePane = (activePaneIndex >= 0 && activePaneIndex < panes.count)
            ? panes[activePaneIndex] : nil

        let node = tabNodes.remove(at: sourceIndex)
        tabNodes.insert(node, at: targetIndex)
        rebuildPanesFromNodes()

        // Restore active pane index after rebuild
        if let activePane = activePane,
           let newIndex = panes.firstIndex(where: { $0 === activePane }) {
            activePaneIndex = newIndex
        }

        layoutAndUpdate(animated: true)
    }

    // MARK: - Find

    func showFindBar() {
        guard activePaneIndex >= 0, activePaneIndex < panes.count,
              let pane = panes[activePaneIndex] as? TerminalPane else { return }
        if findBar != nil { closeFindBar() }

        let bar = FindBarView(terminalView: pane.terminalView)
        pane.addSubview(bar)
        bar.show()
        findBar = bar
    }

    func closeFindBar() {
        findBar?.dismiss()
        findBar = nil
    }

    func findNext() {
        findBar?.findNext(nil)
    }

    func findPrevious() {
        findBar?.findPrevious(nil)
    }

    // MARK: - Global Find

    func showGlobalFind() {
        guard let window = gridContainer?.window else { return }
        closeFindBar()
        globalFind.show(in: window, paneManager: self)
    }

    // MARK: - Navigation

    func navigateDirection(_ dir: Direction) {
        guard !isMaximized, panes.count > 1, activePaneIndex >= 0, activePaneIndex < panes.count else { return }
        let activePane = panes[activePaneIndex]
        let activeFrame = activePane.frame
        let center = CGPoint(x: activeFrame.midX, y: activeFrame.midY)

        // Find closest pane in the given direction by actual frame position
        var bestIndex = activePaneIndex
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (i, pane) in panes.enumerated() where i != activePaneIndex {
            let f = pane.frame
            let pc = CGPoint(x: f.midX, y: f.midY)
            let dx = pc.x - center.x
            let dy = pc.y - center.y

            let inDirection: Bool
            switch dir {
            case .left:  inDirection = dx < -1
            case .right: inDirection = dx > 1
            case .up:    inDirection = dy < -1  // flipped coordinates
            case .down:  inDirection = dy > 1
            }
            guard inDirection else { continue }

            let dist = dx * dx + dy * dy
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
            }
        }

        if bestIndex != activePaneIndex { focusPane(at: bestIndex) }
    }

    func handleClick(event: NSEvent) {
        for (i, pane) in panes.enumerated() {
            let pt = pane.convert(event.locationInWindow, from: nil)
            if pane.bounds.contains(pt) {
                if i != activePaneIndex { focusPane(at: i) }
                return
            }
        }
    }

    // MARK: - Grid math

    func gridDimensions(for count: Int) -> (cols: Int, rows: Int) {
        switch count {
        case 0:      return (0, 0)
        case 1:      return (1, 1)
        case 2:      return (2, 1)
        case 3, 4:   return (2, 2)
        case 5, 6:   return (3, 2)
        default:     return (3, 3)
        }
    }

    // Grid frames for tab nodes (one rect per tab)
    func calculateTabFrames(in bounds: NSRect) -> [NSRect] {
        let count = tabNodes.count
        guard count > 0 else { return [] }

        let pad = Theme.panePadding
        let gap = Theme.paneGap
        let area = NSRect(
            x: bounds.origin.x + pad,
            y: bounds.origin.y,
            width: bounds.width - pad * 2,
            height: bounds.height - pad
        )

        let (cols, _) = gridDimensions(for: count)
        let totalRows = Int(ceil(Double(count) / Double(cols)))

        let totalVGap = CGFloat(totalRows - 1) * gap
        let cellH = (area.height - totalVGap) / CGFloat(totalRows)

        var frames: [NSRect] = []
        var idx = 0
        for row in 0..<totalRows {
            let itemsInRow = min(cols, count - idx)
            let totalHGap = CGFloat(itemsInRow - 1) * gap
            let cellW = (area.width - totalHGap) / CGFloat(itemsInRow)
            for col in 0..<itemsInRow {
                let x = area.origin.x + CGFloat(col) * (cellW + gap)
                let y = area.origin.y + CGFloat(row) * (cellH + gap)
                frames.append(NSRect(x: x, y: y, width: cellW, height: cellH))
                idx += 1
            }
        }
        return frames
    }

    func layoutAndUpdate(animated: Bool = false) {
        gridContainer?.layoutPanes(animated: animated)
        tabBar?.update()
        statusBar?.update()
    }
}
