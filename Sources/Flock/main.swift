import AppKit

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: FlockWindow!
    var paneManager: PaneManager!
    lazy var commandPalette = CommandPalette()
    var hotkeyManager: GlobalHotkeyManager?
    private var clickMonitor: Any?
    private var focusObserver: Any?
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Notifications
        FlockNotifications.setup()

        // Load saved theme
        let savedId = Settings.shared.themeId
        if let theme = Themes.all.first(where: { $0.id == savedId }) {
            Theme.active = theme
        }

        paneManager = PaneManager()
        mainWindow = FlockWindow(paneManager: paneManager)
        mainWindow.makeKeyAndOrderFront(nil)

        // Wire up command palette
        commandPalette.paneManager = paneManager
        commandPalette.window = mainWindow

        // Session restore or first pane
        if Settings.shared.startupBehavior == .restoreLastSession {
            paneManager.restoreSession()
        }
        if paneManager.panes.isEmpty {
            paneManager.addPane(type: .claude)
        }

        // Welcome card for first-time users
        if !Settings.shared.hasSeenWelcome && paneManager.panes.count == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let window = self.mainWindow else { return }
                WelcomeCard.showIfNeeded(in: window)
            }
        }

        // Usage tracker
        if Settings.shared.showUsageTracker {
            UsageTracker.shared.start()
        }

        // Global hotkey -- always create so it can respond to settings changes
        hotkeyManager = GlobalHotkeyManager(window: mainWindow)

        // Post-update changelog tab (before update check so it doesn't stack with the alert)
        let previousVersion = Settings.shared.lastRunVersion
        if UpdateChecker.shared.detectPostUpdate() {
            showChangelog(previousVersion: previousVersion)
        }

        // Auto-update check
        UpdateChecker.shared.checkOnLaunchIfNeeded()

        // Clean up stale shell temp dirs from crashed sessions
        ShellEnhancer.cleanupStale()

        // Clean up stale changelog temp files from crashed sessions
        let tmpDir = NSTemporaryDirectory()
        if let tmpContents = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            let myPid = ProcessInfo.processInfo.processIdentifier
            for file in tmpContents where file.hasPrefix("flock-changelog-") && file.hasSuffix(".txt") {
                if let pid = Int32(file.dropFirst("flock-changelog-".count).dropLast(".txt".count)),
                   pid != myPid, kill(pid, 0) != 0 {
                    try? FileManager.default.removeItem(atPath: tmpDir + "/" + file)
                }
            }
        }

        // Click-to-focus
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.paneManager.handleClick(event: event)
            return event
        }

        // Handle notification tap -> focus pane
        focusObserver = NotificationCenter.default.addObserver(forName: FlockNotifications.focusPaneRequested,
                                               object: nil, queue: .main) { [weak self] note in
            if let idx = note.userInfo?["paneIndex"] as? Int {
                self?.paneManager.focusPane(at: idx)
                self?.mainWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // React to settings changes at runtime
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange,
                                               object: nil, queue: .main) { [weak self] note in
            guard let key = note.userInfo?["key"] as? String else { return }
            if key == "showUsageTracker" {
                if Settings.shared.showUsageTracker {
                    UsageTracker.shared.start()
                } else {
                    UsageTracker.shared.stop()
                }
                self?.paneManager.statusBar?.update()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean up event monitors
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        if let observer = focusObserver { NotificationCenter.default.removeObserver(observer); focusObserver = nil }
        if let observer = settingsObserver { NotificationCenter.default.removeObserver(observer); settingsObserver = nil }

        paneManager.saveSession()
        paneManager.panes.forEach { $0.shutdown() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Changelog

    private func showChangelog(previousVersion: String?) {
        let text = UpdateChecker.shared.formattedChangelog(previousVersion: previousVersion)
        paneManager.addPane(type: .shell)
        guard let pane = paneManager.panes.last as? TerminalPane else { return }
        pane.customName = "What's New"

        let tmpPath = NSTemporaryDirectory() + "flock-changelog-\(ProcessInfo.processInfo.processIdentifier).txt"
        try? text.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pane.sendText("clear && cat '\(tmpPath)' && rm -f '\(tmpPath)'\n")
        }

        if paneManager.panes.count > 1 {
            paneManager.focusPane(at: 0)
        }
    }

    // MARK: - Menu actions

    @objc func newClaudePane(_ sender: Any?)   { paneManager.addPane(type: .claude) }
    @objc func newShellPane(_ sender: Any?)    { paneManager.addPane(type: .shell) }
    @objc func closeActivePane(_ sender: Any?) { paneManager.closeActivePane() }
    @objc func toggleMaximize(_ sender: Any?)  { paneManager.toggleMaximize() }

    @objc func focusPaneByNumber(_ sender: NSMenuItem) {
        paneManager.focusPane(at: sender.tag)
    }

    @objc func navigateLeft(_ sender: Any?)  { paneManager.navigateDirection(.left) }
    @objc func navigateRight(_ sender: Any?) { paneManager.navigateDirection(.right) }
    @objc func navigateUp(_ sender: Any?)    { paneManager.navigateDirection(.up) }
    @objc func navigateDown(_ sender: Any?)  { paneManager.navigateDirection(.down) }

    @objc func newMarkdownFile(_ sender: Any?) {
        commandPalette.createMarkdownFile()
    }

    @objc func openMarkdownFile(_ sender: Any?) {
        commandPalette.openMarkdownPicker()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette.show(in: mainWindow)
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesView.show(on: mainWindow)
    }

    @objc func findInTerminal(_ sender: Any?) {
        paneManager.showFindBar()
    }

    @objc func findNextInTerminal(_ sender: Any?) {
        paneManager.findNext()
    }

    @objc func findPreviousInTerminal(_ sender: Any?) {
        paneManager.findPrevious()
    }

    @objc func toggleBroadcast(_ sender: Any?) {
        paneManager.toggleBroadcast()
    }

    @objc func showGlobalFind(_ sender: Any?) {
        paneManager.showGlobalFind()
    }

    @objc func splitHorizontal(_ sender: Any?) {
        paneManager.splitActivePane(direction: .horizontal)
    }

    @objc func splitVertical(_ sender: Any?) {
        paneManager.splitActivePane(direction: .vertical)
    }

    @objc func toggleChangeLog(_ sender: Any?) {
        let idx = paneManager.activePaneIndex
        guard idx >= 0, idx < paneManager.panes.count else { return }
        (paneManager.panes[idx] as? TerminalPane)?.toggleChangeLog()
    }

    @objc func toggleCostStats(_ sender: Any?) {
        let idx = paneManager.activePaneIndex
        guard idx >= 0, idx < paneManager.panes.count else { return }
        (paneManager.panes[idx] as? TerminalPane)?.toggleCostStats()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkNow()
    }
}

// MARK: - Menu construction

func buildMainMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    // -- App menu --
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu(); appItem.submenu = appMenu
    appMenu.addItem(NSMenuItem(title: "About Flock",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    addItem(appMenu, "Check for Updates\u{2026}", #selector(AppDelegate.checkForUpdates(_:)),
            key: "", target: target)
    appMenu.addItem(.separator())
    addItem(appMenu, "Preferences\u{2026}", #selector(AppDelegate.showPreferences(_:)),
            key: ",", target: target)
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Hide Flock",
        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    appMenu.addItem(NSMenuItem(title: "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
    appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Quit Flock",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    // -- File menu --
    let fileItem = NSMenuItem(); main.addItem(fileItem)
    let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
    addItem(fileMenu, "New Markdown File", #selector(AppDelegate.newMarkdownFile(_:)),
            key: "n", target: target)
    addItem(fileMenu, "Open Markdown File\u{2026}", #selector(AppDelegate.openMarkdownFile(_:)),
            key: "o", target: target)

    // -- Edit menu --
    let editItem = NSMenuItem(); main.addItem(editItem)
    let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
    editMenu.addItem(NSMenuItem(title: "Copy",
        action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste",
        action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All",
        action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editMenu.addItem(.separator())
    addItem(editMenu, "Find\u{2026}", #selector(AppDelegate.findInTerminal(_:)),
            key: "f", target: target)
    addItem(editMenu, "Find Next", #selector(AppDelegate.findNextInTerminal(_:)),
            key: "g", target: target)
    addItem(editMenu, "Find Previous", #selector(AppDelegate.findPreviousInTerminal(_:)),
            key: "g", mods: [.command, .shift], target: target)
    addItem(editMenu, "Find in All Panes", #selector(AppDelegate.showGlobalFind(_:)),
            key: "f", mods: [.command, .shift], target: target)

    // -- View menu --
    let viewItem = NSMenuItem(); main.addItem(viewItem)
    let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
    addItem(viewMenu, "Command Palette", #selector(AppDelegate.showCommandPalette(_:)),
            key: "k", target: target)
    addItem(viewMenu, "Toggle Broadcast", #selector(AppDelegate.toggleBroadcast(_:)),
            key: "b", mods: [.command, .shift], target: target)
    addItem(viewMenu, "Toggle Change Log", #selector(AppDelegate.toggleChangeLog(_:)),
            key: "l", mods: [.command, .shift], target: target)
    addItem(viewMenu, "Toggle Usage Stats", #selector(AppDelegate.toggleCostStats(_:)),
            key: "u", mods: [.command, .shift], target: target)

    // -- Pane menu --
    let paneItem = NSMenuItem(); main.addItem(paneItem)
    let paneMenu = NSMenu(title: "Pane"); paneItem.submenu = paneMenu

    addItem(paneMenu, "New Claude Pane", #selector(AppDelegate.newClaudePane(_:)),
            key: "t", target: target)
    addItem(paneMenu, "New Shell Pane", #selector(AppDelegate.newShellPane(_:)),
            key: "t", mods: [.command, .shift], target: target)
    addItem(paneMenu, "Close Pane", #selector(AppDelegate.closeActivePane(_:)),
            key: "w", target: target)
    paneMenu.addItem(.separator())
    addItem(paneMenu, "Split Horizontal", #selector(AppDelegate.splitHorizontal(_:)),
            key: "d", target: target)
    addItem(paneMenu, "Split Vertical", #selector(AppDelegate.splitVertical(_:)),
            key: "d", mods: [.command, .shift], target: target)
    paneMenu.addItem(.separator())
    addItem(paneMenu, "Maximize / Restore", #selector(AppDelegate.toggleMaximize(_:)),
            key: "\r", target: target)

    // Focus 1–9
    paneMenu.addItem(.separator())
    for i in 1...9 {
        let item = NSMenuItem(title: "Focus Pane \(i)",
            action: #selector(AppDelegate.focusPaneByNumber(_:)), keyEquivalent: "\(i)")
        item.tag = i - 1
        item.target = target
        paneMenu.addItem(item)
    }

    // Arrow navigation
    paneMenu.addItem(.separator())
    addItem(paneMenu, "Navigate Left",  #selector(AppDelegate.navigateLeft(_:)),
            key: String(UnicodeScalar(0xF702)!), target: target)
    addItem(paneMenu, "Navigate Right", #selector(AppDelegate.navigateRight(_:)),
            key: String(UnicodeScalar(0xF703)!), target: target)
    addItem(paneMenu, "Navigate Up",    #selector(AppDelegate.navigateUp(_:)),
            key: String(UnicodeScalar(0xF700)!), target: target)
    addItem(paneMenu, "Navigate Down",  #selector(AppDelegate.navigateDown(_:)),
            key: String(UnicodeScalar(0xF701)!), target: target)

    return main
}

private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String, mods: NSEvent.ModifierFlags = [.command],
                     target: AnyObject) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.target = target
    menu.addItem(item)
}

// MARK: - Entry point

// Prevent SIGPIPE crashes when writing to terminated process pipes
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
NSApp.mainMenu = buildMainMenu(target: delegate)
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
