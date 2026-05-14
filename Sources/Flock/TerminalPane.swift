import AppKit
import Darwin.POSIX
import SwiftTerm

class TerminalPane: FlockPane, LocalProcessTerminalViewDelegate {
    let terminalView: FlockTerminalView
    var shouldResume: Bool = false
    var resumeSessionId: String?  // Exact Claude session UUID to resume

    // Agent activity detection (Claude panes only)
    private var agentActivityTimer: Timer?
    private let agentIdleTimeout: TimeInterval = 1.2
    private var recentByteCount: Int = 0
    private var byteWindowTimer: Timer?
    private let byteRateThreshold: Int = 150  // bytes per second to count as "active"

    // Per-session cost tracking (Claude panes only)
    private var sessionCostUSD: Double = 0
    private var sessionTokens: Int = 0
    private var sessionInputTokens: Int = 0
    private var sessionOutputTokens: Int = 0
    private var sessionCacheReadTokens: Int = 0
    private var sessionCacheCreateTokens: Int = 0
    private var lastCostByteOffset: UInt64 = 0
    private var costLineCarry: String = ""  // trailing partial line from previous read
    private var isRefreshingCost: Bool = false
    private var costUpdateTimer: Timer?
    private var costStatsView: CostStatsView?
    private(set) var isCostStatsVisible: Bool = false

    // Agent state parsing (Claude panes only)
    let outputParser = ClaudeOutputParser()

    // Initial directory (for context file writes and session restore)
    private(set) var contextDirectory: String?

    // Temp ZDOTDIR for shell enhancements (cleaned up on shutdown)
    private var zdotdir: String?

    // Change log overlay
    private var changeLogView: ChangeLogView?
    private(set) var isChangeLogVisible: Bool = false

    // Command timing
    private var lastKnownTitle: String?

    var isRunningCommand: Bool { commandStartTime != nil }

    override var firstResponderView: NSView { terminalView }

    init(type: PaneType, manager: PaneManager, workingDirectory: String? = nil) {
        self.terminalView = FlockTerminalView(frame: .zero)
        super.init(type: type, manager: manager)

        terminalView.owningPane = self

        // Agent state parser
        outputParser.onStateChange = { [weak self] state in
            guard let self else { return }
            self.agentState = state

            self.updateTitleBar()
            self.updateBorderForState()
            self.manager?.tabBar?.update()
            self.manager?.statusBar?.update()
        }

        outputParser.onAction = { [weak self] entry in
            self?.changeLogView?.addAction(entry)
        }

        // Auto-accept workspace trust prompt
        outputParser.onTrustPrompt = { [weak self] in
            guard let self else { return }
            NSLog("[Flock] Trust prompt detected in pane, auto-accepting")
            self.sendText("\r")
        }

        // Terminal
        let fontSize = Settings.shared.fontSize
        terminalView.nativeBackgroundColor = Theme.terminalBg
        terminalView.nativeForegroundColor = Theme.terminalFg
        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        installAnsiColors()
        terminalView.processDelegate = self
        clipView.addSubview(terminalView)

        // Live font-size preview
        observeFontSize()

        // Start shell with enhancements (autosuggestions)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        let cwd = workingDirectory ?? ProcessInfo.processInfo.environment["HOME"]

        if let enhanced = ShellEnhancer.enhancedEnvironment(workingDirectory: workingDirectory) {
            self.zdotdir = enhanced.zdotdir
            terminalView.startProcess(executable: shell, environment: enhanced.env, execName: "-\(name)", currentDirectory: cwd)
        } else {
            terminalView.startProcess(executable: shell, execName: "-\(name)", currentDirectory: cwd)
        }

        if type == .claude {
            contextDirectory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if self.shouldResume {
                    if let sid = self.resumeSessionId, sid != "resume" {
                        // Resume exact conversation by session ID
                        self.sendText("claude --resume \(sid) --dangerously-skip-permissions\n")
                    } else {
                        // Fallback: continue most recent conversation in this directory
                        self.sendText("claude -c --dangerously-skip-permissions\n")
                    }
                } else {
                    self.sendText("claude --dangerously-skip-permissions\n")
                }

                // Initial cost refresh for restored sessions
                if self.shouldResume {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.refreshSessionCost()
                    }
                }
            }
        }

        // Listen for changes
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: Settings.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        byteWindowTimer?.invalidate()
        agentActivityTimer?.invalidate()
        shutdown()
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String else { return }
        if key == "fontSize" {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: Settings.shared.fontSize, weight: .regular)
        }
    }

    // MARK: - Theme (subclass hook)

    override func themeDidChange() {
        terminalView.nativeBackgroundColor = Theme.terminalBg
        terminalView.nativeForegroundColor = Theme.terminalFg
        installAnsiColors()
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    // MARK: - Live font-size preview

    private var fontSizeObserver: Any?

    func observeFontSize() {
        fontSizeObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.userInfo?["key"] as? String, key == "fontSize" else { return }
            let size = Settings.shared.fontSize
            self?.terminalView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            self?.terminalView.setNeedsDisplay(self?.terminalView.bounds ?? .zero)
        }
    }

    // MARK: - Title bar

    override func updateTitleBar() {
        let stateLabel = (agentState != .idle) ? agentState.label : nil
        titleProcessLabel.stringValue = stateLabel ?? processTitle ?? paneType.label
        titleProcessLabel.textColor = (agentState == .waiting) ? Theme.accent
            : (agentState == .error) ? NSColor(hex: 0xFF3B30)
            : Theme.textSecondary
        if let dir = currentDirectory {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            titleCwdLabel.stringValue = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        } else {
            titleCwdLabel.stringValue = ""
        }
    }

    // MARK: - Per-session cost tracking

    // Pricing per million tokens (from LiteLLM, updated 2026-04)
    private static let costPricing: [String: (input: Double, output: Double, cacheRead: Double, cacheCreate: Double)] = [
        "claude-opus-4-6":            (5.0,   25.0,  0.50,  6.25),
        "claude-opus-4-5-20251101":   (5.0,   25.0,  0.50,  6.25),
        "claude-sonnet-4-5-20250929": (3.0,   15.0,  0.30,  3.75),
        "claude-sonnet-4-6":          (3.0,   15.0,  0.30,  3.75),
        "claude-haiku-4-5-20251001":  (0.80,  4.0,   0.08,  1.0),
    ]
    private static let defaultCostPricing = (input: 3.0, output: 15.0, cacheRead: 0.30, cacheCreate: 3.75)

    /// Schedules a cost update shortly after output arrives (debounced).
    private func scheduleCostUpdate() {
        guard paneType == .claude else { return }
        costUpdateTimer?.invalidate()
        costUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.refreshSessionCost()
        }
    }

    /// Reads the session JSONL file and computes cost for this session only.
    /// Seeks to the byte offset of the last read and only parses new bytes — the
    /// JSONL file grows unbounded over a session (tens of MB), so loading the
    /// whole file each refresh caused OOM kills after ~15-20 minutes.
    private func refreshSessionCost() {
        guard let sid = resumeSessionId, !sid.isEmpty, sid != "resume",
              let dir = contextDirectory ?? processWorkingDirectory() else { return }
        guard !isRefreshingCost else { return }
        isRefreshingCost = true

        let encoded = dir.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(home)/.claude/projects/\(encoded)/\(sid).jsonl"
        let startOffset = lastCostByteOffset
        let carry = costLineCarry

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var cost: Double = 0
            var tokens: Int = 0
            var inputTok: Int = 0
            var outputTok: Int = 0
            var cacheReadTok: Int = 0
            var cacheCreateTok: Int = 0
            var newOffset: UInt64 = startOffset
            var newCarry: String = carry

            autoreleasepool {
                guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
                defer { try? handle.close() }

                let fileSize = (try? handle.seekToEnd()) ?? 0
                if fileSize < startOffset {
                    // File rotated/truncated — reset
                    newOffset = 0
                    newCarry = ""
                } else if fileSize == startOffset {
                    return
                }

                do {
                    try handle.seek(toOffset: newOffset)
                } catch {
                    return
                }

                let data = (try? handle.readToEnd()) ?? Data()
                newOffset = fileSize
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                let combined = newCarry + chunk
                // Keep anything after the last newline as carry for next refresh
                var body: Substring
                if let lastNL = combined.lastIndex(of: "\n") {
                    body = combined[..<lastNL]
                    newCarry = String(combined[combined.index(after: lastNL)...])
                } else {
                    // No newline yet — buffer the whole thing, bounded
                    body = Substring()
                    newCarry = combined.count > 65_536 ? String(combined.suffix(32_768)) : combined
                }

                for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
                    autoreleasepool {
                        guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") else { return }
                        guard let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              json["type"] as? String == "assistant",
                              let message = json["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { return }

                        let input = usage["input_tokens"] as? Int ?? 0
                        let output = usage["output_tokens"] as? Int ?? 0
                        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                        let model = message["model"] as? String ?? ""

                        tokens += input + output
                        inputTok += input
                        outputTok += output
                        cacheReadTok += cacheRead
                        cacheCreateTok += cacheCreate
                        let p = Self.costPricing[model] ?? Self.defaultCostPricing
                        let baseInput = max(0, input - cacheRead - cacheCreate)
                        cost += Double(baseInput) / 1_000_000 * p.input
                             + Double(output) / 1_000_000 * p.output
                             + Double(cacheRead) / 1_000_000 * p.cacheRead
                             + Double(cacheCreate) / 1_000_000 * p.cacheCreate
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessionCostUSD += cost
                self.sessionTokens += tokens
                self.sessionInputTokens += inputTok
                self.sessionOutputTokens += outputTok
                self.sessionCacheReadTokens += cacheReadTok
                self.sessionCacheCreateTokens += cacheCreateTok
                self.lastCostByteOffset = newOffset
                self.costLineCarry = newCarry
                self.isRefreshingCost = false
                self.updateCostLabel()
                self.updateCostStatsIfVisible()
            }
        }
    }

    private func updateCostLabel() {
        guard paneType == .claude else { return }
        let cost = sessionCostUSD
        let costStr: String
        if cost == 0 {
            costStr = "$0.00"
        } else if cost < 0.01 {
            costStr = "<$0.01"
        } else if cost < 10 {
            costStr = String(format: "$%.2f", cost)
        } else {
            costStr = String(format: "$%.0f", cost)
        }

        let tokens = sessionTokens
        let tokenStr: String
        if tokens < 1000 {
            tokenStr = "\(tokens)"
        } else if tokens < 1_000_000 {
            tokenStr = String(format: "%.1fK", Double(tokens) / 1000)
        } else {
            tokenStr = String(format: "%.1fM", Double(tokens) / 1_000_000)
        }

        let prev = titleCostLabel.stringValue
        titleCostLabel.stringValue = "\(costStr) · \(tokenStr)"

        // Animate on change
        if prev != titleCostLabel.stringValue && !prev.isEmpty {
            titleCostLabel.alphaValue = 0.3
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Anim.fast
                self.titleCostLabel.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Cost stats panel

    func toggleCostStats() {
        guard paneType == .claude else { return }
        if isCostStatsVisible { hideCostStats() } else { showCostStats() }
    }

    private func showCostStats() {
        guard costStatsView == nil else { return }
        let panel = CostStatsView(frame: .zero)
        panel.onClose = { [weak self] in self?.hideCostStats() }
        panel.update(
            sessionCost: sessionCostUSD, sessionTokens: sessionTokens,
            inputTokens: sessionInputTokens, outputTokens: sessionOutputTokens,
            cacheReadTokens: sessionCacheReadTokens, cacheCreateTokens: sessionCacheCreateTokens
        )
        let h = panel.idealHeight()
        let x = clipView.bounds.width - panel.panelWidth - 8
        let y = titleBarHeight + 4
        panel.frame = NSRect(x: x, y: y, width: panel.panelWidth, height: h)
        panel.alphaValue = 0
        clipView.addSubview(panel)
        costStatsView = panel
        isCostStatsVisible = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Anim.normal
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            panel.animator().alphaValue = 1
        }
    }

    private func hideCostStats() {
        guard let panel = costStatsView else { return }
        isCostStatsVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.removeFromSuperview()
            self?.costStatsView = nil
        })
    }

    private func updateCostStatsIfVisible() {
        guard isCostStatsVisible, let panel = costStatsView else { return }
        panel.update(
            sessionCost: sessionCostUSD, sessionTokens: sessionTokens,
            inputTokens: sessionInputTokens, outputTokens: sessionOutputTokens,
            cacheReadTokens: sessionCacheReadTokens, cacheCreateTokens: sessionCacheCreateTokens
        )
        let h = panel.idealHeight()
        let x = clipView.bounds.width - panel.panelWidth - 8
        let y = titleBarHeight + 4
        panel.frame = NSRect(x: x, y: y, width: panel.panelWidth, height: h)
    }

    // MARK: - Agent activity detection

    func didReceiveOutput(byteCount: Int) {
        guard paneType == .claude && Settings.shared.showActivityIndicators else { return }

        // Ignore keyboard echo — if user typed recently, this is likely just echo
        let timeSinceInput = CFAbsoluteTimeGetCurrent() - terminalView.lastUserInputTime
        if timeSinceInput < 0.3 { return }

        recentByteCount += byteCount

        if byteWindowTimer == nil {
            byteWindowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                let bytes = self.recentByteCount
                self.recentByteCount = 0
                self.byteWindowTimer = nil

                if bytes >= self.byteRateThreshold {
                    if !self.isAgentActive {
                        self.isAgentActive = true
                        self.manager?.tabBar?.update()
                    }
                    self.agentActivityTimer?.invalidate()
                    self.agentActivityTimer = Timer.scheduledTimer(withTimeInterval: self.agentIdleTimeout, repeats: false) { [weak self] _ in
                        guard let self, self.isAgentActive else { return }
                        self.isAgentActive = false
                        self.manager?.tabBar?.update()
                        // Claude went idle — new tokens likely written to JSONL
                        self.scheduleCostUpdate()
                    }
                }
            }
        }
    }

    // MARK: - Change Log

    func toggleChangeLog() {
        guard paneType == .claude else { return }

        if isChangeLogVisible {
            hideChangeLog()
        } else {
            showChangeLog()
        }
    }

    private func showChangeLog() {
        guard changeLogView == nil else { return }

        let panel = ChangeLogView(frame: .zero)
        panel.onClose = { [weak self] in self?.hideChangeLog() }

        for action in outputParser.actions {
            panel.addAction(action)
        }

        let h = panel.idealHeight()
        let x = clipView.bounds.width - panel.panelWidth - 8
        let y = clipView.bounds.height - h - 8
        panel.frame = NSRect(x: x, y: y, width: panel.panelWidth, height: h)
        panel.alphaValue = 0

        clipView.addSubview(panel)
        changeLogView = panel
        isChangeLogVisible = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Anim.normal
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            panel.animator().alphaValue = 1
        }
    }

    private func hideChangeLog() {
        guard let panel = changeLogView else { return }
        isChangeLogVisible = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Anim.fast
            ctx.timingFunction = Theme.Anim.snappyTimingFunction
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.removeFromSuperview()
            self?.changeLogView = nil
        })
    }

    private func installAnsiColors() {
        var colors: [Color] = []
        for hex in Theme.ansiHex {
            let r = UInt16(((hex >> 16) & 0xFF)) * 257
            let g = UInt16(((hex >> 8) & 0xFF)) * 257
            let b = UInt16((hex & 0xFF)) * 257
            colors.append(Color(red: r, green: g, blue: b))
        }
        terminalView.installColors(colors)
    }

    func sendText(_ text: String) { terminalView.send(txt: text) }

    /// Returns the current working directory of the shell process via proc_pidinfo.
    /// Works even when Claude Code is the active foreground process, because the
    /// shell's CWD reflects where it was when claude was launched.
    func processWorkingDirectory() -> String? {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return nil }
        var pathInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, size)
        guard result == size else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    // MARK: - Session ID capture

    /// Captures the Claude session ID by reading ~/.claude/sessions/<PID>.json.
    /// Claude writes a JSON file named by its PID that contains the sessionId.
    /// Each pane's shell has one Claude child → its PID maps to exactly one session.
    func captureSessionId() {
        guard paneType == .claude else { return }
        let shellPid = terminalView.process.shellPid
        guard shellPid > 0 else { return }

        // Find the Claude child process of our shell
        let maxPids = 4096
        var allPids = [pid_t](repeating: 0, count: maxPids)
        let pidBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &allPids, Int32(maxPids * MemoryLayout<pid_t>.size))
        let pidCount = Int(pidBytes) / MemoryLayout<pid_t>.size

        for i in 0..<pidCount {
            let pid = allPids[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_bsdshortinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &taskInfo, Int32(MemoryLayout<proc_bsdshortinfo>.size))
            guard infoSize > 0, taskInfo.pbsi_ppid == UInt32(shellPid) else { continue }

            // Found child of our shell — read ~/.claude/sessions/<PID>.json
            let sessionFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions/\(pid).json")
            guard let data = try? Data(contentsOf: sessionFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["sessionId"] as? String else { continue }

            resumeSessionId = sessionId
            return
        }
    }

    override func shutdown() {
        costUpdateTimer?.invalidate()
        if let obs = fontSizeObserver { NotificationCenter.default.removeObserver(obs) }
        if let dir = zdotdir { ShellEnhancer.cleanup(zdotdir: dir) }
        terminalView.terminate()
    }

    // MARK: - Content layout

    override func layoutContent() {
        let pad: CGFloat = 8
        let newFrame = CGRect(x: pad, y: titleBarHeight, width: clipView.bounds.width - pad * 2, height: clipView.bounds.height - titleBarHeight - pad)
        // Only set frame if it actually changed — setting it unconditionally
        // triggers SwiftTerm's internal layout which resets scroll position
        if terminalView.frame != newFrame {
            terminalView.frame = newFrame
        }

        // Reposition change log overlay if visible
        if let panel = changeLogView {
            let h = panel.idealHeight()
            let x = clipView.bounds.width - panel.panelWidth - 8
            let y = clipView.bounds.height - h - 8
            panel.frame = NSRect(x: x, y: y, width: panel.panelWidth, height: h)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let newTitle = title.isEmpty ? nil : title

        if let oldTitle = lastKnownTitle, oldTitle != title {
            if commandStartTime == nil && newTitle != nil {
                commandStartTime = Date()
            } else if let start = commandStartTime {
                let elapsed = Date().timeIntervalSince(start)
                lastCommandDuration = elapsed
                if !isFocused && elapsed > 10 {
                    sendCommandNotification()
                    SoundEffects.playChime()
                }
                commandStartTime = nil
            }
        }
        lastKnownTitle = title
        processTitle = newTitle
        updateTitleBar()
        manager?.tabBar?.update()
        manager?.statusBar?.update()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        currentDirectory = directory
        updateTitleBar()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let start = commandStartTime, !isFocused {
            let elapsed = Date().timeIntervalSince(start)
            lastCommandDuration = elapsed
            if elapsed > 10 {
                sendCommandNotification()
                SoundEffects.playChime()
            }
        }
        commandStartTime = nil
    }

    private func sendCommandNotification() {
        let paneName = customName ?? processTitle ?? paneType.label
        let paneIdx = manager?.panes.firstIndex(where: { $0 === self }) ?? 0
        FlockNotifications.sendCompletion(paneName: paneName, paneIndex: paneIdx, duration: lastCommandDuration)
    }
}
