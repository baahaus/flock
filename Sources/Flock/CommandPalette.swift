import AppKit
import UniformTypeIdentifiers

// MARK: - Command Action

struct CommandAction {
    let name: String
    let shortcut: String   // display hint like "⌘T"
    let category: String   // "Panes", "Layout", "View"
    let handler: () -> Void
}

// MARK: - Command Palette

class CommandPalette {
    weak var paneManager: PaneManager?
    weak var window: NSWindow?

    private var backdropView: CommandBackdropView?
    private var cardView: CommandCardView?
    private var actions: [CommandAction] = []
    private var isVisible = false

    // MARK: - Public API

    func registerActions(_ actions: [CommandAction]) {
        self.actions = actions
    }

    func show(in window: NSWindow) {
        guard !isVisible, let contentView = window.contentView else { return }
        isVisible = true

        // Rebuild every time -- the set of detected agent CLIs can change
        registerActions(defaultActions())

        // Backdrop
        let backdrop = CommandBackdropView(frame: contentView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onClickOutside = { [weak self] in self?.dismiss() }
        contentView.addSubview(backdrop)
        self.backdropView = backdrop

        // Card -- positioned in upper third of window
        let cardWidth: CGFloat = 420
        let cardMaxHeight: CGFloat = 380
        let cardX = floor((contentView.bounds.width - cardWidth) / 2)
        let cardY: CGFloat
        if contentView.isFlipped {
            cardY = contentView.bounds.height * 0.25
        } else {
            cardY = contentView.bounds.height - contentView.bounds.height * 0.25 - cardMaxHeight
        }

        let card = CommandCardView(
            frame: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardMaxHeight),
            actions: actions,
            isFlippedParent: contentView.isFlipped
        )
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        card.onDismiss = { [weak self] in self?.dismiss() }
        card.onExecute = { [weak self] action in
            self?.dismiss()
            action.handler()
        }
        contentView.addSubview(card)
        self.cardView = card

        // Animate in with scale
        backdrop.alphaValue = 0
        card.alphaValue = 0
        card.wantsLayer = true
        card.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop.animator().alphaValue = 1
            card.animator().alphaValue = 1
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        card.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        // Focus the search field after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.isVisible == true else { return }
            window.makeFirstResponder(card.searchField)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false

        let backdrop = self.backdropView
        let card = self.cardView

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop?.animator().alphaValue = 0
            card?.animator().alphaValue = 0
        }, completionHandler: {
            backdrop?.removeFromSuperview()
            card?.removeFromSuperview()
        })

        // Scale down on dismiss
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.fast)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        card?.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        CATransaction.commit()

        self.backdropView = nil
        self.cardView = nil
    }

    // MARK: - Default Actions

    private func defaultActions() -> [CommandAction] {
        [
            CommandAction(name: "New Claude Pane", shortcut: "⌘T", category: "Panes") { [weak self] in
                self?.paneManager?.addPane(type: .claude)
            },
            CommandAction(name: "New Shell Pane", shortcut: "⌘⇧T", category: "Panes") { [weak self] in
                self?.paneManager?.addPane(type: .shell)
            },
        ] + AgentCLIRegistry.shared.installed.map { cli in
            CommandAction(name: "New \(cli.displayName) Pane", shortcut: "", category: "Panes") { [weak self] in
                self?.paneManager?.addPane(type: .agent(cli))
            }
        } + [
            CommandAction(name: "New Markdown File", shortcut: "\u{2318}N", category: "Files") { [weak self] in
                self?.createMarkdownFile()
            },
            CommandAction(name: "Open Markdown File", shortcut: "\u{2318}O", category: "Files") { [weak self] in
                self?.openMarkdownPicker()
            },
            CommandAction(name: "Close Pane", shortcut: "⌘W", category: "Panes") { [weak self] in
                self?.paneManager?.closeActivePane()
            },
            CommandAction(name: "Maximize / Restore", shortcut: "⌘↩", category: "View") { [weak self] in
                self?.paneManager?.toggleMaximize()
            },
            CommandAction(name: "Rename Tab", shortcut: "", category: "Panes") { [weak self] in
                self?.paneManager?.tabBar?.renameActiveTab()
            },
            CommandAction(name: "Preferences", shortcut: "⌘,", category: "View") { [weak self] in
                guard let win = self?.window else { return }
                PreferencesView.show(on: win)
            },
            CommandAction(name: "Allow Microphone (Voice Dictation)", shortcut: "", category: "View") {
                VoiceMode.promptOrOpenSettings()
            },
            CommandAction(name: "Find in Terminal", shortcut: "⌘F", category: "View") { [weak self] in
                self?.paneManager?.showFindBar()
            },
            CommandAction(name: "Toggle Broadcast", shortcut: "⌘⇧B", category: "View") { [weak self] in
                self?.paneManager?.toggleBroadcast()
            },
            CommandAction(name: "Find in All Panes", shortcut: "⌘⇧F", category: "View") { [weak self] in
                self?.paneManager?.showGlobalFind()
            },
            CommandAction(name: "Split Horizontal", shortcut: "⌘D", category: "Panes") { [weak self] in
                self?.paneManager?.splitActivePane(direction: .horizontal)
            },
            CommandAction(name: "Split Vertical", shortcut: "⌘⇧D", category: "Panes") { [weak self] in
                self?.paneManager?.splitActivePane(direction: .vertical)
            },
            CommandAction(name: "Single Claude", shortcut: "", category: "Layout") { [weak self] in
                self?.applyPreset(LayoutPresets.all[0])
            },
            CommandAction(name: "Claude + Shell", shortcut: "", category: "Layout") { [weak self] in
                self?.applyPreset(LayoutPresets.all[1])
            },
            CommandAction(name: "2x2 Grid", shortcut: "", category: "Layout") { [weak self] in
                self?.applyPreset(LayoutPresets.all[2])
            },
            CommandAction(name: "3-up", shortcut: "", category: "Layout") { [weak self] in
                self?.applyPreset(LayoutPresets.all[3])
            },
            CommandAction(name: "Navigate Left", shortcut: "⌘←", category: "Panes") { [weak self] in
                self?.paneManager?.navigateDirection(.left)
            },
            CommandAction(name: "Navigate Right", shortcut: "⌘→", category: "Panes") { [weak self] in
                self?.paneManager?.navigateDirection(.right)
            },
            CommandAction(name: "Navigate Up", shortcut: "⌘↑", category: "Panes") { [weak self] in
                self?.paneManager?.navigateDirection(.up)
            },
            CommandAction(name: "Navigate Down", shortcut: "⌘↓", category: "Panes") { [weak self] in
                self?.paneManager?.navigateDirection(.down)
            },
        ] + (1...9).map { i in
            CommandAction(name: "Focus Pane \(i)", shortcut: "⌘\(i)", category: "Panes") { [weak self] in
                self?.paneManager?.focusPane(at: i - 1)
            }
        } + [
            CommandAction(name: "Toggle Change Log", shortcut: "⌘⇧L", category: "View") { [weak self] in
                guard let mgr = self?.paneManager else { return }
                let idx = mgr.activePaneIndex
                guard idx >= 0, idx < mgr.panes.count else { return }
                (mgr.panes[idx] as? TerminalPane)?.toggleChangeLog()
            },
            CommandAction(name: "Toggle Usage Stats", shortcut: "⌘⇧U", category: "View") { [weak self] in
                guard let mgr = self?.paneManager else { return }
                let idx = mgr.activePaneIndex
                guard idx >= 0, idx < mgr.panes.count else { return }
                (mgr.panes[idx] as? TerminalPane)?.toggleCostStats()
            },
        ] + Themes.all.map { theme in
            CommandAction(name: "Theme: \(theme.name)", shortcut: "", category: "Appearance") {
                Settings.shared.themeId = theme.id
                Theme.active = theme
            }
        } + workspaceActions()
    }

    private func workspaceActions() -> [CommandAction] {
        var actions: [CommandAction] = [
            CommandAction(name: "New Workspace", shortcut: "⌘⌃N", category: "Workspaces") { [weak self] in
                self?.paneManager?.addWorkspace()
            },
            CommandAction(name: "Next Workspace", shortcut: "⌘⌃]", category: "Workspaces") { [weak self] in
                self?.paneManager?.cycleWorkspace(forward: true)
            },
            CommandAction(name: "Previous Workspace", shortcut: "⌘⌃[", category: "Workspaces") { [weak self] in
                self?.paneManager?.cycleWorkspace(forward: false)
            },
            CommandAction(name: "Rename Workspace", shortcut: "", category: "Workspaces") {
                NSApp.sendAction(#selector(AppDelegate.renameWorkspace(_:)), to: nil, from: nil)
            },
            CommandAction(name: "Close Workspace", shortcut: "⌘⌃W", category: "Workspaces") { [weak self] in
                self?.paneManager?.closeActiveWorkspace()
            },
        ]
        // One "Switch to <name>" entry per existing workspace.
        if let mgr = paneManager {
            for (i, ws) in mgr.workspaces.enumerated() {
                actions.append(CommandAction(name: "Switch to: \(ws.name)", shortcut: "", category: "Workspaces") { [weak self] in
                    self?.paneManager?.switchToWorkspace(at: i)
                })
            }
        }
        return actions
    }

    private func applyPreset(_ preset: LayoutPreset) {
        guard let pm = paneManager else { return }
        pm.applyPreset(preset)
    }

    func openMarkdownPicker() {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .plainText,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "mdown"),
            UTType(filenameExtension: "mkd"),
        ].compactMap { $0 }
        panel.message = "Choose a markdown file to open in a pane."

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.paneManager?.openMarkdownFile(url.path)
        }
    }

    func createMarkdownFile() {
        guard let window = window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.md"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        panel.message = "Choose where to create the new markdown file."

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            let starter = "# Untitled\n\n"
            do {
                try starter.write(to: url, atomically: true, encoding: .utf8)
                self?.paneManager?.openMarkdownFile(url.path)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Create Markdown File"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window)
            }
        }
    }
}

// MARK: - Fuzzy Matching

private struct FuzzyMatch {
    let action: CommandAction
    let score: Int

    /// Fuzzy match: characters of query must appear in-order in target.
    /// Score is based on how tightly packed the matched characters are.
    /// Returns nil if no match. Higher score = better match.
    static func match(query: String, action: CommandAction) -> FuzzyMatch? {
        let queryChars = Array(query.lowercased())
        let targetChars = Array(action.name.lowercased())

        guard !queryChars.isEmpty else {
            return FuzzyMatch(action: action, score: 0)
        }

        var matchIndices: [Int] = []
        var targetIdx = 0

        for qChar in queryChars {
            var found = false
            while targetIdx < targetChars.count {
                if targetChars[targetIdx] == qChar {
                    matchIndices.append(targetIdx)
                    targetIdx += 1
                    found = true
                    break
                }
                targetIdx += 1
            }
            if !found { return nil }
        }

        // Score: tighter packing = higher score.
        // Max possible spread is target length, so invert the spread.
        guard let first = matchIndices.first, let last = matchIndices.last else { return nil }
        let spread = last - first
        let maxScore = 1000
        let score = maxScore - spread * 10 - first * 2
        guard score > 0 else { return nil }
        return FuzzyMatch(action: action, score: score)
    }
}

// MARK: - Backdrop View

class CommandBackdropView: NSView {
    var onClickOutside: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClickOutside?()
    }
}

// MARK: - Card View

private class CommandCardView: NSView {
    let searchField: CommandSearchField
    private let resultsView: CommandResultsView
    private let divider = NSView()
    private let isFlippedParent: Bool

    var onDismiss: (() -> Void)?
    var onExecute: ((CommandAction) -> Void)?

    private var allActions: [CommandAction]
    private var filteredResults: [FuzzyMatch] = []

    init(frame: NSRect, actions: [CommandAction], isFlippedParent: Bool) {
        self.allActions = actions
        self.isFlippedParent = isFlippedParent
        self.searchField = CommandSearchField()
        self.resultsView = CommandResultsView()

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = Theme.paneRadius

        // Dual shadow
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Theme.Shadow.Focus.ambient.opacity
        layer?.shadowRadius = Theme.Shadow.Focus.ambient.radius
        layer?.shadowOffset = Theme.Shadow.Focus.ambient.offset

        setupSearchField()
        setupDivider()
        setupResultsView()
        updateResults(query: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { isFlippedParent }

    // MARK: - Setup

    private func setupSearchField() {
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        searchField.textColor = Theme.textPrimary
        searchField.placeholderString = "Type a command..."
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        searchField.onArrowDown = { [weak self] in self?.moveSelection(by: 1) }
        searchField.onArrowUp = { [weak self] in self?.moveSelection(by: -1) }
        searchField.onEnter = { [weak self] in self?.executeSelected() }
        searchField.onEscape = { [weak self] in self?.onDismiss?() }
        searchField.onTextChange = { [weak self] text in self?.updateResults(query: text) }

        addSubview(searchField)
    }

    private func setupDivider() {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        addSubview(divider)
    }

    private func setupResultsView() {
        resultsView.onSelect = { [weak self] action in
            self?.onExecute?(action)
        }
        addSubview(resultsView)
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutSubviewsManual()
    }

    override func layout() {
        super.layout()
        layoutSubviewsManual()
    }

    private func layoutSubviewsManual() {
        let w = bounds.width
        let topPad: CGFloat = Theme.Space.xs
        let fieldHeight: CGFloat = 48
        let dividerHeight: CGFloat = 1
        let padding: CGFloat = Theme.Space.lg

        searchField.frame = NSRect(x: padding, y: topPad, width: w - padding * 2, height: fieldHeight)
        divider.frame = NSRect(x: 0, y: topPad + fieldHeight, width: w, height: dividerHeight)
        resultsView.frame = NSRect(
            x: 0,
            y: topPad + fieldHeight + dividerHeight,
            width: w,
            height: bounds.height - topPad - fieldHeight - dividerHeight
        )
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: NSTextField) {
        updateResults(query: sender.stringValue)
    }

    private func updateResults(query: String) {
        if query.isEmpty {
            filteredResults = allActions.map { FuzzyMatch(action: $0, score: 0) }
        } else {
            filteredResults = allActions.compactMap { FuzzyMatch.match(query: query, action: $0) }
                .sorted { $0.score > $1.score }
        }
        resultsView.results = filteredResults.map { $0.action }
        resultsView.selectedIndex = filteredResults.isEmpty ? -1 : 0
        resultsView.needsDisplay = true
    }

    private func moveSelection(by delta: Int) {
        guard !filteredResults.isEmpty else { return }
        var idx = resultsView.selectedIndex + delta
        if idx < 0 { idx = 0 }
        if idx >= filteredResults.count { idx = filteredResults.count - 1 }
        resultsView.selectedIndex = idx
        resultsView.needsDisplay = true
    }

    private func executeSelected() {
        let idx = resultsView.selectedIndex
        guard idx >= 0, idx < filteredResults.count else { return }
        onExecute?(filteredResults[idx].action)
    }
}

// MARK: - Search Field (with key interception)

class CommandSearchField: NSTextField, NSTextFieldDelegate {
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Intercept commands from the field editor (the actual first responder during editing)
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            onArrowDown?()
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            onArrowUp?()
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            onEnter?()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Results View (custom draw)

private class CommandResultsView: NSView {
    var results: [CommandAction] = []
    var selectedIndex: Int = 0
    var hoveredIndex: Int = -1

    var onSelect: ((CommandAction) -> Void)?

    private let rowHeight: CGFloat = 36
    private let horizontalPadding: CGFloat = Theme.Space.lg

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        let nameAttrsNormal: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Theme.textPrimary,
        ]
        let nameAttrsSelected: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Theme.textPrimary,
        ]
        let shortcutAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Theme.textTertiary,
        ]
        let categoryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textTertiary,
        ]

        for (i, action) in results.enumerated() {
            let rowRect = NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
            guard rowRect.intersects(dirtyRect) else { continue }

            // Background for selected / hovered row
            if i == selectedIndex {
                Theme.hover.setFill()
                let bgPath = NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
                bgPath.fill()

                // Left accent bar (3px wide)
                Theme.accent.setFill()
                let accentBarRect = NSRect(x: 4, y: rowRect.minY + 4, width: 3, height: rowRect.height - 8)
                NSBezierPath(roundedRect: accentBarRect, xRadius: 1.5, yRadius: 1.5).fill()
            } else if i == hoveredIndex {
                Theme.hover.withAlphaComponent(0.5).setFill()
                let bgPath = NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
                bgPath.fill()
            }

            // Category badge
            let categoryStr = NSAttributedString(string: action.category, attributes: categoryAttrs)
            let categorySize = categoryStr.size()
            let badgePadH: CGFloat = 6
            let badgePadV: CGFloat = 2
            let badgeRect = NSRect(
                x: horizontalPadding,
                y: rowRect.midY - (categorySize.height + badgePadV * 2) / 2,
                width: categorySize.width + badgePadH * 2,
                height: categorySize.height + badgePadV * 2
            )
            Theme.chrome.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
            categoryStr.draw(at: NSPoint(x: badgeRect.minX + badgePadH, y: badgeRect.minY + badgePadV))

            // Action name
            let nameX = badgeRect.maxX + Theme.Space.sm
            let attrs = i == selectedIndex ? nameAttrsSelected : nameAttrsNormal
            let nameStr = NSAttributedString(string: action.name, attributes: attrs)
            let nameSize = nameStr.size()
            nameStr.draw(at: NSPoint(x: nameX, y: rowRect.midY - nameSize.height / 2))

            // Shortcut hint (right-aligned)
            if !action.shortcut.isEmpty {
                let shortcutStr = NSAttributedString(string: action.shortcut, attributes: shortcutAttrs)
                let shortcutSize = shortcutStr.size()
                shortcutStr.draw(at: NSPoint(
                    x: bounds.width - horizontalPadding - shortcutSize.width,
                    y: rowRect.midY - shortcutSize.height / 2
                ))
            }
        }
    }

    // MARK: - Mouse Tracking

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = Int(pt.y / rowHeight)
        if idx >= 0, idx < results.count, idx != hoveredIndex {
            hoveredIndex = idx
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = -1
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = Int(pt.y / rowHeight)
        if idx >= 0, idx < results.count {
            onSelect?(results[idx])
        }
    }
}
