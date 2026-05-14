import AppKit

class FlockWindow: NSWindow {
    let paneManager: PaneManager
    let tabBar: TabBarView
    let gridContainer: GridContainer
    let statusBar: StatusBarView
    let rootView: FlockRootView

    init(paneManager: PaneManager) {
        self.paneManager = paneManager
        self.tabBar = TabBarView(paneManager: paneManager)
        self.gridContainer = GridContainer(paneManager: paneManager)
        self.statusBar = StatusBarView(paneManager: paneManager)
        self.rootView = FlockRootView()

        // Screen-relative sizing: 80% of main screen
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = floor(screen.width * 0.8)
        let h = floor(screen.height * 0.8)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        paneManager.tabBar = tabBar
        paneManager.gridContainer = gridContainer
        paneManager.statusBar = statusBar

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = false
        backgroundColor = Theme.chrome
        minSize = NSSize(width: 600, height: 400)
        title = "Flock"
        delegate = self
        center()

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.themeDidChange, object: nil)

        rootView.tabBar = tabBar
        rootView.gridContainer = gridContainer
        rootView.statusBar = statusBar
        rootView.addSubview(rootView.tabBarEffectView)
        rootView.addSubview(tabBar)
        rootView.addSubview(gridContainer)
        rootView.addSubview(statusBar)
        contentView = rootView
    }

    @objc private func themeChanged() {
        backgroundColor = Theme.chrome
    }

    // MARK: - Fullscreen relayout

    override func toggleFullScreen(_ sender: Any?) {
        super.toggleFullScreen(sender)
    }
}

extension FlockWindow: NSWindowDelegate {
    func windowDidEnterFullScreen(_ notification: Notification) {
        relayoutAfterFullScreenChange()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        relayoutAfterFullScreenChange()
    }

    private func relayoutAfterFullScreenChange() {
        rootView.resizeSubviews(withOldSize: rootView.bounds.size)
        if let tabBar = rootView.tabBar as? TabBarView {
            tabBar.needsDisplay = true
        }
    }
}

class FlockRootView: NSView {
    weak var tabBar: NSView?
    weak var gridContainer: NSView?
    weak var statusBar: NSView?
    let tabBarEffectView: NSVisualEffectView = {
        let v = TitlebarEffectView(frame: .zero)
        v.material = .titlebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }()

    override var isFlipped: Bool { true }

    private var titlebarInset: CGFloat {
        guard let window = window else { return 0 }
        // In fullscreen the titlebar is hidden so contentLayoutRect fills the window.
        // Use a fixed inset so the tab bar keeps a comfortable height.
        if window.styleMask.contains(.fullScreen) {
            return 22
        }
        let frameInWindow = window.contentLayoutRect
        let fullFrame = NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)
        return fullFrame.height - frameInWindow.height
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // contentLayoutRect isn't ready on first layout -- re-layout once the window is set up
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeSubviews(withOldSize: self.bounds.size)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let w = bounds.width
        let h = bounds.height
        let inset = titlebarInset
        let tabH = Theme.tabBarHeight + inset
        let statusH = Theme.statusHeight

        tabBarEffectView.frame = NSRect(x: 0, y: 0, width: w, height: tabH)
        tabBar?.frame       = NSRect(x: 0, y: 0, width: w, height: tabH)
        gridContainer?.frame = NSRect(x: 0, y: tabH, width: w, height: h - tabH - statusH)
        statusBar?.frame    = NSRect(x: 0, y: h - statusH, width: w, height: statusH)
    }
}

// MARK: - TitlebarEffectView

/// NSVisualEffectView subclass that prevents the titlebar from claiming its area
/// for window dragging when used with fullSizeContentView.
private class TitlebarEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
}
