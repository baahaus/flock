import AppKit

/// One-time welcome card shown on first launch with no restored session.
/// Displays key shortcuts and an animated pixel bird. Dismissed via "Got it" or Esc.
class WelcomeCard {

    private static weak var backdrop: NSView?
    private static weak var card: WelcomeCardView?

    static func showIfNeeded(in window: NSWindow) {
        guard !Settings.shared.hasSeenWelcome,
              backdrop == nil,
              let contentView = window.contentView else { return }

        // Backdrop
        let bg = CommandBackdropView(frame: contentView.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.onClickOutside = { WelcomeCard.dismiss() }
        contentView.addSubview(bg)
        backdrop = bg

        // Card
        let cardW: CGFloat = 340
        let cardH: CGFloat = 280
        let cardX = floor((contentView.bounds.width - cardW) / 2)
        let cardY: CGFloat
        if contentView.isFlipped {
            cardY = floor((contentView.bounds.height - cardH) / 2)
        } else {
            cardY = floor((contentView.bounds.height - cardH) / 2)
        }

        let cardView = WelcomeCardView(frame: NSRect(x: cardX, y: cardY, width: cardW, height: cardH))
        cardView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        contentView.addSubview(cardView)
        card = cardView

        // Animate in
        bg.alphaValue = 0
        cardView.alphaValue = 0
        cardView.wantsLayer = true
        cardView.layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            bg.animator().alphaValue = 1
            cardView.animator().alphaValue = 1
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(Theme.Anim.snappyTimingFunction)
        cardView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    static func dismiss() {
        Settings.shared.hasSeenWelcome = true

        let bg = backdrop
        let c = card

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            bg?.animator().alphaValue = 0
            c?.animator().alphaValue = 0
        }, completionHandler: {
            bg?.removeFromSuperview()
            c?.removeFromSuperview()
        })

        backdrop = nil
        card = nil
    }
}

// MARK: - Card View

private class WelcomeCardView: NSView {

    private let birdView = PixelBirdView(frame: .zero)
    private var birdAnimator: CABasicAnimation?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = Theme.paneRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.borderRest.cgColor

        // Pixel bird flight across top of card
        let birdSize = birdView.intrinsicContentSize
        birdView.frame = NSRect(x: -birdSize.width, y: 12, width: birdSize.width, height: birdSize.height)
        birdView.wantsLayer = true
        addSubview(birdView)
        startBirdFlight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            WelcomeCard.dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        birdView.speedUp()
    }

    // MARK: - Bird Flight

    private func startBirdFlight() {
        guard let birdLayer = birdView.layer else { return }
        let flight = CABasicAnimation(keyPath: "position.x")
        flight.fromValue = -30
        flight.toValue = bounds.width + 30
        flight.duration = 6.0
        flight.repeatCount = .infinity
        flight.timingFunction = CAMediaTimingFunction(name: .linear)
        birdLayer.add(flight, forKey: "flight")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let pad: CGFloat = 24
        var y: CGFloat = 40

        // Headline
        let headline = "welcome to flock"
        let headAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: Theme.textPrimary,
        ]
        headline.draw(at: NSPoint(x: pad, y: y), withAttributes: headAttrs)
        y += 30

        // Shortcuts
        let shortcuts: [(key: String, desc: String)] = [
            ("\u{2318}T", "new claude pane"),
            ("\u{2318}\u{21E7}T", "new shell pane"),
            ("\u{2318}K", "command palette"),
            ("\u{2318}D", "split pane"),
            ("\u{2318}\u{21E7}L", "change log overlay"),
            ("\u{2318},", "preferences"),
        ]

        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.accent,
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: Theme.textSecondary,
        ]

        for (key, desc) in shortcuts {
            key.draw(at: NSPoint(x: pad, y: y), withAttributes: keyAttrs)
            desc.draw(at: NSPoint(x: pad + 56, y: y), withAttributes: descAttrs)
            y += 24
        }

        y += 8

        // Theme hint
        let hint = "7 themes available in preferences"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textTertiary,
        ]
        hint.draw(at: NSPoint(x: pad, y: y), withAttributes: hintAttrs)
        y += 28

        // "Got it" button
        let btnW: CGFloat = 72
        let btnH: CGFloat = 28
        let btnX = bounds.width - btnW - pad
        let btnPath = NSBezierPath(roundedRect: NSRect(x: btnX, y: y, width: btnW, height: btnH),
                                   xRadius: 6, yRadius: 6)
        Theme.surface.setFill()
        btnPath.fill()
        Theme.divider.setStroke()
        btnPath.lineWidth = 1
        btnPath.stroke()

        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Theme.textPrimary,
        ]
        let btnText = "Got it"
        let btnSize = btnText.size(withAttributes: btnAttrs)
        btnText.draw(at: NSPoint(x: btnX + (btnW - btnSize.width) / 2,
                                 y: y + (btnH - btnSize.height) / 2),
                     withAttributes: btnAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let pad: CGFloat = 24
        let btnW: CGFloat = 72
        let btnH: CGFloat = 28
        let btnX = bounds.width - btnW - pad
        let btnY: CGFloat = 238  // approximate from layout
        let btnRect = NSRect(x: btnX, y: btnY, width: btnW, height: btnH)
        if btnRect.contains(pt) {
            WelcomeCard.dismiss()
        }
    }
}
