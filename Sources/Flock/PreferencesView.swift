import AppKit

class PreferencesView: NSView {

    override var isFlipped: Bool { true }

    // MARK: - Controls

    private var themeSwatchViews: [NSView] = []
    private let fontSizeSlider = NSSlider()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let paneTypeControl = NSSegmentedControl()
    private let launchControl = NSSegmentedControl()
    private let activitySwitch = NSSwitch()
    private let claudeBordersSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()
    private let wrenSwitch = NSSwitch()
    private let usageSwitch = NSSwitch()
    private let updateSwitch = NSSwitch()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    // MARK: - Layout Constants

    private let panelWidth: CGFloat = 480
    private let panelHeight: CGFloat = 576
    private let labelX: CGFloat = 24
    private let controlX: CGFloat = 160
    private let controlWidth: CGFloat = 200
    private let rowHeight: CGFloat = 32
    private let sectionGap: CGFloat = 28
    private let sectionHeaderHeight: CGFloat = 20

    // MARK: - Show (backdrop overlay)

    private static weak var currentBackdrop: NSView?
    private static weak var currentCard: PreferencesView?

    static func show(on window: NSWindow) {
        guard currentBackdrop == nil, let contentView = window.contentView else { return }

        // Backdrop
        let backdrop = CommandBackdropView(frame: contentView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onClickOutside = { PreferencesView.dismiss() }
        contentView.addSubview(backdrop)
        currentBackdrop = backdrop

        // Card centered in window
        let cardW: CGFloat = 480
        let cardH: CGFloat = 576
        let cardX = floor((contentView.bounds.width - cardW) / 2)
        let cardY: CGFloat
        if contentView.isFlipped {
            cardY = floor((contentView.bounds.height - cardH) / 2)
        } else {
            cardY = floor((contentView.bounds.height - cardH) / 2)
        }

        let view = PreferencesView(frame: NSRect(x: cardX, y: cardY, width: cardW, height: cardH))
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        view.layer?.cornerRadius = Theme.paneRadius
        view.layer?.masksToBounds = true
        contentView.addSubview(view)
        currentCard = view

        // Animate in
        backdrop.alphaValue = 0
        view.alphaValue = 0
        view.wantsLayer = true
        view.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop.animator().alphaValue = 1
            view.animator().alphaValue = 1
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        view.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    static func dismiss() {
        let backdrop = currentBackdrop
        let card = currentCard

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            backdrop?.animator().alphaValue = 0
            card?.animator().alphaValue = 0
        }, completionHandler: {
            backdrop?.removeFromSuperview()
            card?.removeFromSuperview()
        })

        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.fast)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        card?.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        CATransaction.commit()

        currentBackdrop = nil
        currentCard = nil
    }

    // MARK: - Init

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            PreferencesView.dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor
        setupControls()

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        layer?.backgroundColor = Theme.chrome.cgColor
        doneButton.layer?.backgroundColor = Theme.surface.cgColor
        doneButton.layer?.borderColor = Theme.divider.cgColor
        doneButton.contentTintColor = Theme.textPrimary
        let selectedIdx = Themes.all.firstIndex(where: { $0.id == Settings.shared.themeId }) ?? 0
        updateSwatchSelection(selectedIndex: selectedIdx)
    }

    // MARK: - Setup

    private func setupControls() {
        let settings = Settings.shared

        var y: CGFloat = 20

        // ── Appearance ──
        y = addSectionHeader("Appearance", y: y)

        // Theme

        addLabel("Theme", y: y)

        let themes = Themes.all
        let swatchW: CGFloat = 34
        let swatchH: CGFloat = 28
        let swatchGap: CGFloat = 6
        let containerH: CGFloat = swatchH + 16
        var swatchX = controlX

        for (i, t) in themes.enumerated() {
            let chip = ClickableView(frame: NSRect(x: swatchX, y: y, width: swatchW, height: containerH))
            chip.wantsLayer = true
            chip.onClick = { [weak self] in self?.selectTheme(at: i) }

            // Color swatch (visual top of container)
            let swatch = NSView(frame: NSRect(x: 0, y: containerH - swatchH, width: swatchW, height: swatchH))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 6
            swatch.layer?.masksToBounds = true
            swatch.layer?.backgroundColor = t.surface.cgColor
            swatch.identifier = NSUserInterfaceItemIdentifier("swatch")

            let accentBar = CALayer()
            accentBar.frame = CGRect(x: 0, y: 0, width: swatchW, height: 5)
            accentBar.backgroundColor = t.accent.cgColor
            swatch.layer?.addSublayer(accentBar)

            chip.addSubview(swatch)

            // Name label (visual bottom of container)
            let name = NSTextField(labelWithString: t.name)
            name.alignment = .center
            name.frame = NSRect(x: -3, y: 2, width: swatchW + 6, height: 12)
            name.identifier = NSUserInterfaceItemIdentifier("name")
            chip.addSubview(name)

            addSubview(chip)
            themeSwatchViews.append(chip)
            swatchX += swatchW + swatchGap
        }

        updateSwatchSelection(selectedIndex: themes.firstIndex(where: { $0.id == settings.themeId }) ?? 0)

        y += 48

        // ── Terminal ──
        y += sectionGap - rowHeight
        y = addSectionHeader("Terminal", y: y)

        // Font Size

        addLabel("Font Size", y: y)

        fontSizeSlider.minValue = 11
        fontSizeSlider.maxValue = 18
        fontSizeSlider.isContinuous = true
        fontSizeSlider.doubleValue = Double(settings.fontSize)
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged(_:))
        fontSizeSlider.frame = NSRect(x: controlX, y: y + 4, width: controlWidth, height: 20)
        addSubview(fontSizeSlider)

        fontSizeLabel.font = Theme.Typo.status
        fontSizeLabel.textColor = Theme.textSecondary
        fontSizeLabel.alignment = .left
        fontSizeLabel.stringValue = "\(Int(settings.fontSize)) pt"
        fontSizeLabel.frame = NSRect(x: controlX + controlWidth + 8, y: y + 4, width: 50, height: 20)
        addSubview(fontSizeLabel)

        y += rowHeight

        // ── Behavior ──
        y += sectionGap - rowHeight
        y = addSectionHeader("Behavior", y: y)

        // Default Pane

        addLabel("Default Pane", y: y)

        paneTypeControl.segmentCount = 2
        paneTypeControl.setLabel("Claude", forSegment: 0)
        paneTypeControl.setLabel("Shell", forSegment: 1)
        paneTypeControl.segmentStyle = .rounded
        paneTypeControl.selectedSegment = settings.defaultPaneType == .claude ? 0 : 1
        paneTypeControl.target = self
        paneTypeControl.action = #selector(paneTypeChanged(_:))
        paneTypeControl.frame = NSRect(x: controlX, y: y + 2, width: controlWidth, height: 24)
        addSubview(paneTypeControl)

        y += rowHeight

        // On Launch

        addLabel("On Launch", y: y)

        launchControl.segmentCount = 2
        launchControl.setLabel("New Claude Pane", forSegment: 0)
        launchControl.setLabel("Restore Last Session", forSegment: 1)
        launchControl.segmentStyle = .rounded
        launchControl.selectedSegment = settings.startupBehavior.rawValue
        // Session restore is now functional
        launchControl.target = self
        launchControl.action = #selector(launchChanged(_:))
        launchControl.frame = NSRect(x: controlX, y: y + 2, width: controlWidth + 60, height: 24)
        addSubview(launchControl)

        y += rowHeight

        // ── Indicators ──
        y += sectionGap - rowHeight
        y = addSectionHeader("Indicators", y: y)

        // Activity Dots

        addLabel("Activity Dots", y: y)

        activitySwitch.state = settings.showActivityIndicators ? .on : .off
        activitySwitch.target = self
        activitySwitch.action = #selector(activityChanged(_:))
        activitySwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(activitySwitch)

        y += rowHeight

        // Claude Session Borders

        addLabel("Claude Borders", y: y)

        claudeBordersSwitch.state = settings.showClaudeSessionBorders ? .on : .off
        claudeBordersSwitch.target = self
        claudeBordersSwitch.action = #selector(claudeBordersChanged(_:))
        claudeBordersSwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(claudeBordersSwitch)

        let claudeBordersHint = NSTextField(labelWithString: "Blue/red border shows Claude status")
        claudeBordersHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        claudeBordersHint.textColor = Theme.textTertiary
        claudeBordersHint.frame = NSRect(x: controlX + 48, y: y + 5, width: 240, height: 14)
        addSubview(claudeBordersHint)

        y += rowHeight

        // Sound Effects

        addLabel("Sound Effects", y: y)

        soundSwitch.state = settings.soundEffectsEnabled ? .on : .off
        soundSwitch.target = self
        soundSwitch.action = #selector(soundChanged(_:))
        soundSwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(soundSwitch)

        y += rowHeight

        // Usage Tracker

        addLabel("Usage Tracker", y: y)

        usageSwitch.state = settings.showUsageTracker ? .on : .off
        usageSwitch.target = self
        usageSwitch.action = #selector(usageChanged(_:))
        usageSwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(usageSwitch)

        let usageHint = NSTextField(labelWithString: "Show today's cost + tokens in status bar")
        usageHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        usageHint.textColor = Theme.textTertiary
        usageHint.frame = NSRect(x: controlX + 48, y: y + 5, width: 240, height: 14)
        addSubview(usageHint)

        y += rowHeight

        // Auto Updates

        addLabel("Auto Updates", y: y)

        updateSwitch.state = settings.autoCheckUpdates ? .on : .off
        updateSwitch.target = self
        updateSwitch.action = #selector(updateChanged(_:))
        updateSwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(updateSwitch)

        let updateHint = NSTextField(labelWithString: "Check for new versions on launch")
        updateHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        updateHint.textColor = Theme.textTertiary
        updateHint.frame = NSRect(x: controlX + 48, y: y + 5, width: 240, height: 14)
        addSubview(updateHint)

        y += rowHeight

        // Wren Compression

        addLabel("Wren Compression", y: y)

        wrenSwitch.state = settings.wrenCompressionEnabled ? .on : .off
        wrenSwitch.target = self
        wrenSwitch.action = #selector(wrenChanged(_:))
        wrenSwitch.frame = NSRect(x: controlX, y: y + 2, width: 38, height: 22)
        addSubview(wrenSwitch)

        let wrenHint = NSTextField(labelWithString: "Compress prompts before sending to save tokens")
        wrenHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        wrenHint.textColor = Theme.textTertiary
        wrenHint.frame = NSRect(x: controlX + 48, y: y + 5, width: 240, height: 14)
        addSubview(wrenHint)

        y += rowHeight

        // ── Done Button ──
        let btnWidth: CGFloat = 72
        let btnHeight: CGFloat = 28
        let btnX = panelWidth - btnWidth - 24
        let btnY = panelHeight - btnHeight - 20

        doneButton.frame = NSRect(x: btnX, y: btnY, width: btnWidth, height: btnHeight)
        doneButton.bezelStyle = .rounded
        doneButton.isBordered = false
        doneButton.wantsLayer = true
        doneButton.layer?.backgroundColor = Theme.surface.cgColor
        doneButton.layer?.borderColor = Theme.divider.cgColor
        doneButton.layer?.borderWidth = 1
        doneButton.layer?.cornerRadius = 6
        doneButton.font = Theme.Typo.button
        doneButton.contentTintColor = Theme.textPrimary
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.keyEquivalent = "\r"
        addSubview(doneButton)
    }

    // MARK: - Layout Helpers

    @discardableResult
    private func addSectionHeader(_ title: String, y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.textSecondary
        label.frame = NSRect(x: labelX, y: y, width: panelWidth - labelX * 2, height: sectionHeaderHeight)
        addSubview(label)
        return y + sectionHeaderHeight + 8
    }


    private func addLabel(_ text: String, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = Theme.textPrimary
        label.alignment = .right
        label.frame = NSRect(x: labelX, y: y + 4, width: controlX - labelX - 16, height: 20)
        addSubview(label)
    }

    // MARK: - Actions

    private func selectTheme(at index: Int) {
        let themes = Themes.all
        guard index >= 0, index < themes.count else { return }
        let theme = themes[index]
        Settings.shared.themeId = theme.id
        Theme.active = theme
        updateSwatchSelection(selectedIndex: index)
    }

    private func updateSwatchSelection(selectedIndex: Int) {
        let themes = Themes.all
        for (i, container) in themeSwatchViews.enumerated() {
            let t = themes[i]
            let isSelected = (i == selectedIndex)
            if let swatch = container.subviews.first(where: { $0.identifier?.rawValue == "swatch" }) {
                swatch.layer?.borderWidth = isSelected ? 2 : 1
                swatch.layer?.borderColor = isSelected ? t.accent.cgColor : t.divider.cgColor
            }
            if let name = container.subviews.first(where: { $0.identifier?.rawValue == "name" }) as? NSTextField {
                name.font = NSFont.systemFont(ofSize: 9, weight: isSelected ? .semibold : .medium)
                name.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
            }
        }
    }

    @objc private func fontSizeChanged(_ sender: NSSlider) {
        let value = CGFloat(round(sender.doubleValue))
        sender.doubleValue = Double(value)
        Settings.shared.fontSize = value
        fontSizeLabel.stringValue = "\(Int(value)) pt"
    }

    @objc private func paneTypeChanged(_ sender: NSSegmentedControl) {
        Settings.shared.defaultPaneType = sender.selectedSegment == 0 ? .claude : .shell
    }

    @objc private func launchChanged(_ sender: NSSegmentedControl) {
        if let behavior = StartupBehavior(rawValue: sender.selectedSegment) {
            Settings.shared.startupBehavior = behavior
        }
    }

    @objc private func activityChanged(_ sender: NSSwitch) {
        Settings.shared.showActivityIndicators = (sender.state == .on)
    }

    @objc private func claudeBordersChanged(_ sender: NSSwitch) {
        Settings.shared.showClaudeSessionBorders = (sender.state == .on)
    }

    @objc private func soundChanged(_ sender: NSSwitch) {
        Settings.shared.soundEffectsEnabled = (sender.state == .on)
    }

    @objc private func usageChanged(_ sender: NSSwitch) {
        Settings.shared.showUsageTracker = (sender.state == .on)
    }

    @objc private func updateChanged(_ sender: NSSwitch) {
        Settings.shared.autoCheckUpdates = (sender.state == .on)
    }

    @objc private func wrenChanged(_ sender: NSSwitch) {
        Settings.shared.wrenCompressionEnabled = (sender.state == .on)
    }

    @objc private func done(_ sender: Any) {
        PreferencesView.dismiss()
    }

    // MARK: - Clickable Swatch View

    private class ClickableView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            return frame.contains(point) ? self : nil
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
