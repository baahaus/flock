import Foundation

// MARK: - AgentState

enum AgentState: String {
    case idle
    case thinking
    case writing
    case running
    case reading
    case waiting
    case error

    var label: String {
        switch self {
        case .idle:     return ""
        case .thinking: return "Thinking…"
        case .writing:  return "Writing files"
        case .running:  return "Running command"
        case .reading:  return "Reading…"
        case .waiting:  return "Needs input"
        case .error:    return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle:     return ""
        case .thinking: return "brain"
        case .writing:  return "doc.text"
        case .running:  return "terminal"
        case .reading:  return "doc.text.magnifyingglass"
        case .waiting:  return "exclamationmark.bubble"
        case .error:    return "xmark.circle"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .idle:     return 0
        case .thinking: return 1
        case .reading:  return 2
        case .running:  return 3
        case .writing:  return 4
        case .error:    return 5
        case .waiting:  return 6
        }
    }
}

// MARK: - AgentActionType

enum AgentActionType: String, Codable {
    case think
    case read
    case edit
    case write
    case bash
    case search
    case agent
    case web
    case message

    var badge: String {
        switch self {
        case .think:   return "..."
        case .read:    return "R"
        case .edit:    return "E"
        case .write:   return "W"
        case .bash:    return "$"
        case .search:  return "?"
        case .agent:   return "A"
        case .web:     return "W"
        case .message: return ">"
        }
    }
}

// MARK: - ClaudeOutputParser

/// Detects agent state from raw terminal output.
///
/// TUI agents (Claude Code, Amp) redraw the entire screen each frame.
/// Each redraw contains the full visible content, so we check each
/// incoming chunk independently — no buffering needed.
/// We strip ANSI escapes, collapse whitespace, extract all "words",
/// then match against known tokens.
final class ClaudeOutputParser {

    struct ActionEntry {
        let type: AgentActionType
        let target: String
        let timestamp: Date
    }

    private(set) var state: AgentState = .idle
    private(set) var actions: [ActionEntry] = []
    private let maxRetainedActions = 500
    var onStateChange: ((AgentState) -> Void)?
    var onAction: ((ActionEntry) -> Void)?
    var onTrustPrompt: (() -> Void)?

    private var idleTimer: Timer?
    private let idleTimeout: TimeInterval = 4.0
    private var trustPromptFired = false

    deinit {
        idleTimer?.invalidate()
        dedupeResetTimer?.invalidate()
    }

    // MARK: - Tool call extraction

    private static let toolCallPattern: NSRegularExpression = {
        // Matches patterns like "Edit(path/to/file.swift)" or "Bash(npm test)"
        let pattern = "\\b(Edit|Write|Read|Bash|Grep|Glob|Agent|WebSearch|WebFetch)\\(([^)]{1,200})\\)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let toolToActionType: [String: AgentActionType] = [
        "Edit": .edit, "Write": .write, "Read": .read,
        "Bash": .bash, "Grep": .search, "Glob": .search,
        "Agent": .agent, "WebSearch": .web, "WebFetch": .web,
    ]

    private var recentTargets: Set<String> = []
    private var dedupeResetTimer: Timer?

    private func extractActions(_ text: String) {
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.toolCallPattern.matches(in: text, range: range)

        for match in matches {
            guard let toolRange = Range(match.range(at: 1), in: text),
                  let argRange = Range(match.range(at: 2), in: text) else { continue }

            let tool = String(text[toolRange])
            let target = String(text[argRange])
            guard let type = Self.toolToActionType[tool] else { continue }

            // Dedupe -- terminal redraws repeat the same line many times
            let key = "\(tool):\(target)"
            guard !recentTargets.contains(key) else { continue }
            recentTargets.insert(key)

            // Clear dedupe set after 3s of no new matches
            dedupeResetTimer?.invalidate()
            dedupeResetTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.recentTargets.removeAll()
            }

            let entry = ActionEntry(type: type, target: target, timestamp: Date())
            actions.append(entry)
            if actions.count > maxRetainedActions {
                actions.removeFirst(actions.count - maxRetainedActions)
            }
            let e = entry
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(e)
            }
        }
    }

    // MARK: - ANSI stripping

    private static let ansiPattern: NSRegularExpression = {
        let pattern = "\\x1B(?:\\[[0-9;?]*[A-Za-z]|\\][^\u{07}]*\u{07}|\\([A-Z]|[>=<])"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private func stripAnsi(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Feed

    // Buffer for trust prompt detection across small chunks
    private var trustBuffer = ""

    func feed(_ text: String) {
        assert(Thread.isMainThread, "ClaudeOutputParser.feed must be called from main thread")
        let clean = stripAnsi(text)

        // Trust prompt detection: buffer text across chunks for reliable matching.
        // Claude's TUI uses cursor positioning, so after ANSI stripping words may
        // be concatenated without spaces. We normalize by lowercasing.
        if !trustPromptFired {
            trustBuffer += clean
            if trustBuffer.count > 4000 { trustBuffer = String(trustBuffer.suffix(2000)) }
            let lower = trustBuffer.lowercased()
            if lower.contains("trust this folder")
                || lower.contains("trustthisfolder")
                || lower.contains("i trust this")
                || lower.contains("safety check")
                || lower.contains("safetycheck") {
                trustPromptFired = true
                trustBuffer = ""
                // Small delay to let the TUI fully render before sending Enter
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.onTrustPrompt?()
                }
            }
        }

        guard clean.count > 5 else { return }  // skip tiny fragments

        // Collapse whitespace and extract a compact string to search
        let compact = clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                          .joined(separator: " ")
        guard !compact.isEmpty else { return }

        extractActions(compact)
        let detected = detectState(compact)

        // Only transition away from idle if we found something;
        // idle transitions happen via the timer
        if detected != .idle {
            resetIdleTimer()
            if detected != state {
                state = detected
                let s = detected
                DispatchQueue.main.async { [weak self] in
                    self?.onStateChange?(s)
                }
            }
        } else if state != .idle {
            // Still getting output but no patterns — reset idle timer
            resetIdleTimer()
        }
    }

    func reset() {
        idleTimer?.invalidate()
        idleTimer = nil
        dedupeResetTimer?.invalidate()
        recentTargets.removeAll()
        state = .idle
        actions.removeAll()
    }

    // MARK: - Detection

    private func detectState(_ text: String) -> AgentState {
        // Priority: waiting > error > writing > running > reading > thinking

        // Waiting / permission
        if text.contains("wants to") || text.contains("Permission")
            || text.localizedCaseInsensitiveContains("(y/n)")
            || text.localizedCaseInsensitiveContains("Yes, allow")
            || text.localizedCaseInsensitiveContains("No, deny")
            || text.contains("Do you want") {
            return .waiting
        }

        // Error
        if text.contains("Error:") || text.contains("error:")
            || text.contains("FAILED") || text.contains("API error")
            || text.contains("hit your limit") || text.contains("Rate limit") {
            return .error
        }

        // Writing
        if text.contains("Write(") || text.contains("Edit(")
            || text.contains("write_file") || text.contains("edit_file")
            || text.contains("create_file")
            || text.contains("Writing") || text.contains("Wrote ") {
            return .writing
        }

        // Running commands
        if text.contains("Bash(") || text.contains("running for")
            || text.contains("Executing") {
            return .running
        }

        // Reading
        if text.contains("Reading") || text.contains("Searching")
            || text.contains("Searched") || text.contains("Queried")
            || text.contains("Grep(") || text.contains("Read(")
            || text.contains("glob(") || text.contains("finder(") {
            return .reading
        }

        // Thinking — braille spinners are the most reliable signal
        if containsBraille(text) {
            return .thinking
        }

        // Text-based thinking
        if text.contains("Thinking") || text.contains("Reasoning")
            || text.contains("Thought for") || text.contains("Resolving") {
            return .thinking
        }

        return .idle
    }

    /// Check for braille spinner characters (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
    private func containsBraille(_ text: String) -> Bool {
        for c in text {
            let v = c.unicodeScalars.first?.value ?? 0
            if v >= 0x2800 && v <= 0x28FF {  // braille pattern range
                return true
            }
        }
        return false
    }

    // MARK: - Idle Timer

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.state != .idle else { return }
            self.state = .idle
            // Dispatch async to match the delivery pattern of all other state changes
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.idle)
            }
        }
    }
}
