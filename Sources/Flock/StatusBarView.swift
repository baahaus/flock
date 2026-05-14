import AppKit

class StatusBarView: NSView {
    weak var paneManager: PaneManager?
    private let label = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let broadcastBadge = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private var lastText: String = ""
    private var durationTimer: Timer?

    override var isFlipped: Bool { true }

    init(paneManager: PaneManager) {
        self.paneManager = paneManager
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor

        label.font = Theme.Typo.status
        label.textColor = Theme.textTertiary
        addSubview(label)

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.textColor = Theme.textTertiary
        durationLabel.alignment = .right
        addSubview(durationLabel)

        broadcastBadge.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        broadcastBadge.textColor = NSColor(hex: 0xFF9500)
        broadcastBadge.stringValue = "BROADCAST"
        broadcastBadge.isHidden = true
        addSubview(broadcastBadge)

        usageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        usageLabel.textColor = Theme.textTertiary
        usageLabel.alignment = .center
        usageLabel.isHidden = !Settings.shared.showUsageTracker
        addSubview(usageLabel)

        update()

        // Timer for live command duration
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDuration()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(usageUpdated),
                                               name: UsageTracker.didUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    deinit {
        durationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func usageUpdated() { updateUsage() }
    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String, key == "showUsageTracker" else { return }
        let show = Settings.shared.showUsageTracker
        usageLabel.isHidden = !show
        if show {
            UsageTracker.shared.start()
        } else {
            UsageTracker.shared.stop()
        }
        updateUsage()
        resizeSubviews(withOldSize: bounds.size)
    }

    @objc private func themeChanged() {
        layer?.backgroundColor = Theme.chrome.cgColor
        label.textColor = Theme.textTertiary
        durationLabel.textColor = Theme.textTertiary
        usageLabel.textColor = Theme.textTertiary
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update() {
        guard let mgr = paneManager else { return }

        let n = mgr.panes.count
        let newText = n == 0 ? "\u{2318}T for a new pane" : n == 1 ? "1 session" : "\(n) sessions"

        if newText != lastText && !lastText.isEmpty {
            // Cancel any in-flight animation by setting immediately, then animate
            label.layer?.removeAllAnimations()
            label.alphaValue = 1
            label.stringValue = newText
            // Quick flash to indicate change
            label.alphaValue = 0.3
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Anim.fast
                self.label.animator().alphaValue = 1
            }
        } else {
            label.stringValue = newText
        }
        lastText = newText

        // Broadcast badge
        broadcastBadge.isHidden = !(mgr.isBroadcasting)

        updateDuration()
        updateUsage()
        needsDisplay = true
    }

    private func updateDuration() {
        guard let mgr = paneManager,
              mgr.activePaneIndex >= 0, mgr.activePaneIndex < mgr.panes.count else {
            durationLabel.stringValue = ""
            return
        }
        let pane = mgr.panes[mgr.activePaneIndex]
        if let start = pane.commandStartTime {
            let elapsed = Int(Date().timeIntervalSince(start))
            durationLabel.stringValue = "Running: \(elapsed)s"
            // Visual escalation for long-running commands
            if elapsed >= 900 { // 15 minutes
                durationLabel.textColor = Theme.accent
                durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            } else if elapsed >= 300 { // 5 minutes
                durationLabel.textColor = Theme.accent
                durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            } else {
                durationLabel.textColor = Theme.textTertiary
                durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            }
        } else if let duration = pane.lastCommandDuration {
            durationLabel.textColor = Theme.textTertiary
            durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            if duration < 1 {
                durationLabel.stringValue = String(format: "Last: %.0fms", duration * 1000)
            } else if duration < 60 {
                durationLabel.stringValue = String(format: "Last: %.1fs", duration)
            } else {
                let mins = Int(duration) / 60
                let secs = Int(duration) % 60
                durationLabel.stringValue = "Last: \(mins)m\(secs)s"
            }
        } else {
            durationLabel.textColor = Theme.textTertiary
            durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            durationLabel.stringValue = ""
        }
    }

    private func updateUsage() {
        guard Settings.shared.showUsageTracker else {
            usageLabel.isHidden = true
            return
        }
        usageLabel.isHidden = false
        let text = UsageTracker.shared.statusText
        if text != usageLabel.stringValue {
            usageLabel.layer?.removeAllAnimations()
            usageLabel.alphaValue = 1
            usageLabel.stringValue = text
            usageLabel.alphaValue = 0.3
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Anim.fast
                self.usageLabel.animator().alphaValue = 1
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let pad = Theme.Space.lg
        let labelH: CGFloat = 16
        let labelY = (bounds.height - labelH) / 2
        broadcastBadge.frame = NSRect(x: pad, y: labelY, width: 70, height: labelH)
        let labelX = (paneManager?.isBroadcasting == true) ? pad + 76 : pad
        label.frame = NSRect(x: labelX, y: labelY, width: 200, height: labelH)

        let usageW: CGFloat = 180
        let durationW: CGFloat = 200
        if Settings.shared.showUsageTracker {
            usageLabel.frame = NSRect(x: bounds.width / 2 - usageW / 2, y: labelY, width: usageW, height: labelH)
            durationLabel.frame = NSRect(x: bounds.width - durationW - pad, y: labelY, width: durationW, height: labelH)
        } else {
            durationLabel.frame = NSRect(x: bounds.width - durationW - pad, y: labelY, width: durationW, height: labelH)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let fadeLen: CGFloat = bounds.width * 0.1
        let color = Theme.divider

        for i in 0..<Int(fadeLen) {
            let alpha = CGFloat(i) / fadeLen
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: CGFloat(i), y: 0, width: 1, height: 0.5))
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: fadeLen, y: 0, width: bounds.width - fadeLen * 2, height: 0.5))
        for i in 0..<Int(fadeLen) {
            let alpha = CGFloat(i) / fadeLen
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: bounds.width - CGFloat(i) - 1, y: 0, width: 1, height: 0.5))
        }
    }
}
