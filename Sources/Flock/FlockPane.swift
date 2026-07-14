import AppKit

/// Base class for all pane types in Flock (terminal, markdown, etc.)
/// Provides shared visual chrome: shadows, borders, dim overlay, title bar, animations.
class FlockPane: NSView {
    let paneType: PaneType
    var customName: String? {
        didSet {
            updateTitleBar()
            manager?.tabBar?.update()
            manager?.statusBar?.update()
        }
    }
    weak var manager: PaneManager?

    // Visual chrome
    let clipView = NSView(frame: .zero)
    private let ambientShadowLayer = CALayer()
    private let dimOverlayLayer = CALayer()
    private let accentBarLayer = CALayer()

    // Title bar
    let paneTitleBar = NSView(frame: .zero)
    let titleProcessLabel = NSTextField(labelWithString: "")
    let titleCwdLabel = NSTextField(labelWithString: "")
    let titleCostLabel = NSTextField(labelWithString: "")
    let micButton = NSButton()   // voice-dictation mic indicator (Claude panes)
    let titleBarHeight: CGFloat = 24

    // Shared state -- subclasses modify directly
    var isAgentActive: Bool = false {
        didSet {
            if oldValue != isAgentActive { updateBorderForState() }
        }
    }
    var processTitle: String?
    var agentState: AgentState = .idle
    var commandStartTime: Date?
    var lastCommandDuration: TimeInterval?
    var currentDirectory: String?

    var accentColor: NSColor? {
        didSet { updateAccentBar() }
    }

    var isFocused: Bool = false {
        didSet { animateAppearance() }
    }

    override var isFlipped: Bool { true }

    /// The view that should become first responder when this pane is focused.
    var firstResponderView: NSView { self }

    init(type: PaneType, manager: PaneManager) {
        self.paneType = type
        self.manager = manager
        super.init(frame: .zero)
        setupChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var claudeSessionBordersEnabled: Bool {
        Settings.shared.showClaudeSessionBorders
    }

    private func applyBorderAppearance(animated: Bool) {
        let apply = {
            if self.paneType == .claude, self.claudeSessionBordersEnabled {
                // Claude-specific border logic lives in updateBorderForState()/animateAppearance().
                self.updateBorderForState()
            } else {
                // Default pane border behavior (also used when Claude borders are disabled).
                self.layer?.borderWidth = 1
                self.layer?.borderColor = (self.isFocused ? Theme.borderFocus : Theme.borderRest).cgColor
            }
        }

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.Anim.fast)
            CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
            apply()
            CATransaction.commit()
        } else {
            apply()
        }
    }

    // MARK: - Chrome setup

    private func setupChrome() {
        wantsLayer = true
        layer?.cornerRadius = Theme.paneRadius
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Theme.Shadow.Rest.contact.opacity
        layer?.shadowRadius = Theme.Shadow.Rest.contact.radius
        layer?.shadowOffset = Theme.Shadow.Rest.contact.offset
        layer?.borderWidth = 1
        layer?.borderColor = Theme.borderRest.cgColor

        // Ambient shadow
        ambientShadowLayer.shadowColor = NSColor.black.cgColor
        ambientShadowLayer.shadowOpacity = Theme.Shadow.Rest.ambient.opacity
        ambientShadowLayer.shadowRadius = Theme.Shadow.Rest.ambient.radius
        ambientShadowLayer.shadowOffset = Theme.Shadow.Rest.ambient.offset
        ambientShadowLayer.backgroundColor = Theme.surface.cgColor
        ambientShadowLayer.cornerRadius = Theme.paneRadius
        layer?.insertSublayer(ambientShadowLayer, at: 0)

        // Accent bar (hidden by default)
        accentBarLayer.isHidden = true
        accentBarLayer.cornerRadius = 1.5
        layer?.addSublayer(accentBarLayer)

        // Clip view
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Theme.paneRadius
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        // Dim overlay for unfocused panes
        dimOverlayLayer.backgroundColor = Theme.chrome.withAlphaComponent(0.04).cgColor
        dimOverlayLayer.cornerRadius = Theme.paneRadius
        dimOverlayLayer.opacity = 1  // starts dimmed (unfocused)
        layer?.addSublayer(dimOverlayLayer)

        // Pane title bar
        paneTitleBar.wantsLayer = true
        paneTitleBar.layer?.backgroundColor = Theme.surface.cgColor
        clipView.addSubview(paneTitleBar)

        titleProcessLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        titleProcessLabel.textColor = Theme.textSecondary
        titleProcessLabel.isBezeled = false
        titleProcessLabel.drawsBackground = false
        titleProcessLabel.isEditable = false
        titleProcessLabel.lineBreakMode = .byTruncatingTail
        paneTitleBar.addSubview(titleProcessLabel)

        titleCwdLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        titleCwdLabel.textColor = Theme.textTertiary
        titleCwdLabel.alignment = .right
        titleCwdLabel.isBezeled = false
        titleCwdLabel.drawsBackground = false
        titleCwdLabel.isEditable = false
        titleCwdLabel.lineBreakMode = .byTruncatingMiddle
        paneTitleBar.addSubview(titleCwdLabel)

        // Cost label (Claude panes only)
        titleCostLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        titleCostLabel.textColor = Theme.textTertiary
        titleCostLabel.alignment = .right
        titleCostLabel.isBezeled = false
        titleCostLabel.drawsBackground = false
        titleCostLabel.isEditable = false
        titleCostLabel.isHidden = paneType != .claude
        paneTitleBar.addSubview(titleCostLabel)

        // Voice-dictation mic indicator (Claude panes only).
        // Styled like Flock's other SF-symbol buttons (cf. FindBarView).
        micButton.isBordered = false
        micButton.wantsLayer = true
        micButton.layer?.cornerRadius = 4
        micButton.bezelStyle = .inline
        micButton.setButtonType(.momentaryPushIn)
        (micButton.cell as? NSButtonCell)?.highlightsBy = []
        micButton.imagePosition = .imageOnly
        micButton.target = self
        micButton.action = #selector(micButtonTapped)
        micButton.isHidden = true
        paneTitleBar.addSubview(micButton)
        updateMicButton()
        // Re-check permission when returning to Flock (user may grant in Settings).
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)

        updateTitleBar()

        // Theme observer
        NotificationCenter.default.addObserver(self, selector: #selector(baseThemeDidChange),
                                               name: Theme.themeDidChange, object: nil)

        // Settings observer (Claude border toggle)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)),
                                               name: Settings.didChange, object: nil)

        applyBorderAppearance(animated: false)
    }

    // MARK: - Title bar (override in subclasses)

    func updateTitleBar() {
        titleProcessLabel.stringValue = customName ?? paneType.label
        titleCwdLabel.stringValue = ""
    }

    // MARK: - Voice dictation (microphone)

    @objc private func appBecameActive() { updateMicButton() }

    @objc private func micButtonTapped() {
        switch VoiceMode.micStatus {
        case .notDetermined:
            VoiceMode.requestMic { [weak self] _ in self?.updateMicButton() }
        case .denied, .restricted:
            VoiceMode.openMicSettings()
        case .authorized:
            showVoiceHint()
        @unknown default:
            VoiceMode.requestMic { [weak self] _ in self?.updateMicButton() }
        }
    }

    private func showVoiceHint() {
        let alert = NSAlert()
        alert.messageText = "Voice dictation is ready"
        alert.informativeText = "In this Claude pane, type /voice then hold Space to dictate — your speech is transcribed into the prompt."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Updates the mic indicator's visibility/icon/tooltip from the current
    /// microphone permission. Shown only on Claude panes (where `/voice` lives).
    func updateMicButton() {
        guard paneType == .claude else { micButton.isHidden = true; return }
        micButton.isHidden = false
        let symbol: String, color: NSColor, tip: String
        switch VoiceMode.micStatus {
        case .authorized:
            symbol = "mic.fill"; color = Theme.accent
            tip = "Microphone ready — use /voice in Claude, then hold Space"
        case .denied, .restricted:
            symbol = "mic.slash.fill"; color = NSColor(hex: 0xFF3B30)
            tip = "Microphone blocked — click to open System Settings"
        default:
            symbol = "mic"; color = Theme.textTertiary
            tip = "Voice dictation available — click to allow the microphone"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        micButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice dictation")?
            .withSymbolConfiguration(config)
        micButton.contentTintColor = color
        micButton.toolTip = tip
    }

    /// Override in subclasses that support full-text search outside the terminal find API.
    func matchesSearchTerm(_ term: String) -> Bool { false }

    // MARK: - Theme

    @objc private func baseThemeDidChange() {
        layer?.backgroundColor = Theme.surface.cgColor
        applyBorderAppearance(animated: false)
        ambientShadowLayer.backgroundColor = Theme.surface.cgColor
        dimOverlayLayer.backgroundColor = Theme.chrome.withAlphaComponent(0.04).cgColor
        paneTitleBar.layer?.backgroundColor = Theme.surface.cgColor
        titleProcessLabel.textColor = Theme.textSecondary
        titleCwdLabel.textColor = Theme.textTertiary
        titleCostLabel.textColor = Theme.textTertiary
        themeDidChange()
    }

    @objc private func settingsDidChange(_ note: Notification) {
        guard
            let key = note.userInfo?["key"] as? String,
            key == "showClaudeSessionBorders"
        else { return }
        applyBorderAppearance(animated: true)
    }

    /// Override point for subclass-specific theme updates.
    func themeDidChange() {}

    // MARK: - Claude border state

    /// Whether to render the Claude session borders. TerminalPane overrides this
    /// to drop them once the Claude process exits (pane fell back to a shell).
    var claudeBordersActive: Bool { paneType == .claude && claudeSessionBordersEnabled }

    /// Updates the border color and width based on Claude activity.
    /// Red = actively outputting, Blue = idle/waiting for prompt.
    func updateBorderForState() {
        guard paneType == .claude else { return }
        guard claudeBordersActive else {
            layer?.borderWidth = 1
            layer?.borderColor = (isFocused ? Theme.borderFocus : Theme.borderRest).cgColor
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.fast)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)

        if agentState == .error {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor(hex: 0xFF3B30).cgColor
        } else if isAgentActive {
            // Claude is actively outputting — red
            layer?.borderWidth = 2
            layer?.borderColor = NSColor(hex: 0xE05545).cgColor
        } else {
            // Idle — blue
            layer?.borderWidth = 1.5
            layer?.borderColor = (isFocused ? NSColor(hex: 0x6AB0FF) : NSColor(hex: 0x4A90D9)).cgColor
        }

        CATransaction.commit()
    }

    // MARK: - Accent bar

    private func updateAccentBar() {
        if let color = accentColor {
            accentBarLayer.isHidden = false
            accentBarLayer.backgroundColor = color.cgColor
        } else {
            accentBarLayer.isHidden = true
        }
    }

    // MARK: - Focus animation

    private func animateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.normal)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)

        // If Claude pane is actively working, keep the red border
        let claudeIsWorking = claudeBordersActive && (isAgentActive || agentState == .error)

        if !claudeIsWorking {
            layer?.borderWidth = 1
        }

        if isFocused {
            layer?.shadowOpacity = Theme.Shadow.Focus.contact.opacity
            layer?.shadowRadius = Theme.Shadow.Focus.contact.radius
            layer?.shadowOffset = Theme.Shadow.Focus.contact.offset
            if !claudeIsWorking {
                layer?.borderColor = (claudeBordersActive ? NSColor(hex: 0x6AB0FF) : Theme.borderFocus).cgColor
            }
            ambientShadowLayer.shadowOpacity = Theme.Shadow.Focus.ambient.opacity
            ambientShadowLayer.shadowRadius = Theme.Shadow.Focus.ambient.radius
            ambientShadowLayer.shadowOffset = Theme.Shadow.Focus.ambient.offset
            dimOverlayLayer.opacity = 0
        } else {
            layer?.shadowOpacity = Theme.Shadow.Rest.contact.opacity
            layer?.shadowRadius = Theme.Shadow.Rest.contact.radius
            layer?.shadowOffset = Theme.Shadow.Rest.contact.offset
            if !claudeIsWorking {
                layer?.borderColor = (claudeBordersActive ? NSColor(hex: 0x4A90D9) : Theme.borderRest).cgColor
            }
            ambientShadowLayer.shadowOpacity = Theme.Shadow.Rest.ambient.opacity
            ambientShadowLayer.shadowRadius = Theme.Shadow.Rest.ambient.radius
            ambientShadowLayer.shadowOffset = Theme.Shadow.Rest.ambient.offset
            dimOverlayLayer.opacity = 1
        }

        CATransaction.commit()
    }

    // MARK: - Entrance / Exit animations

    func animateEntrance() {
        alphaValue = 0
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.96, y: 0.96))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Anim.slow
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            self.animator().alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.slow)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    func animateExit(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.normal
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            self.animator().alphaValue = 0
        }, completionHandler: completion)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Anim.normal)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.97, y: 0.97))
        CATransaction.commit()
    }

    func animateFadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Anim.normal
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            self.animator().alphaValue = 0
        }
    }

    func animateFadeIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Anim.normal
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            self.animator().alphaValue = 1
        }
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        clipView.frame = bounds
        paneTitleBar.frame = CGRect(x: 0, y: 0, width: clipView.bounds.width, height: titleBarHeight)
        let labelH: CGFloat = 16
        let labelY = (titleBarHeight - labelH) / 2
        // Measure cost label width dynamically
        var costW: CGFloat = 0
        if !titleCostLabel.isHidden && !titleCostLabel.stringValue.isEmpty {
            titleCostLabel.sizeToFit()
            costW = ceil(titleCostLabel.frame.width) + 8  // 8px breathing room
        }
        let barW = paneTitleBar.bounds.width
        let micVisible = !micButton.isHidden
        if micVisible {
            micButton.frame = CGRect(x: 6, y: labelY - 1, width: 18, height: labelH + 2)
        }
        let procX: CGFloat = micVisible ? 26 : 8
        titleProcessLabel.frame = CGRect(x: procX, y: labelY, width: max(20, barW / 2 - 4 - procX), height: labelH)
        titleCwdLabel.frame = CGRect(x: barW / 2, y: labelY, width: barW / 2 - 8 - costW, height: labelH)
        if costW > 0 {
            titleCostLabel.frame = CGRect(x: barW - costW - 8, y: labelY, width: costW, height: labelH)
        }
        ambientShadowLayer.frame = bounds
        dimOverlayLayer.frame = bounds
        accentBarLayer.frame = CGRect(x: 4, y: 0, width: bounds.width - 8, height: 3)

        layoutContent()
    }

    /// Override in subclasses to layout content within clipView.
    func layoutContent() {}

    // MARK: - Shutdown

    /// Override in subclasses to clean up resources.
    func shutdown() {}
}
