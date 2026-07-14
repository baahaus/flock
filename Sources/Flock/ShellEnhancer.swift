import Foundation

/// Sets up a temporary ZDOTDIR that chains the user's zsh config
/// then loads Flock shell enhancements (autosuggestions, etc.)
enum ShellEnhancer {
    /// Path to the bundled zsh-autosuggestions plugin
    private static var pluginPath: String? {
        // Check app bundle first, then fall back to Resources dir next to binary
        if let bundled = Bundle.main.path(forResource: "zsh-autosuggestions", ofType: "zsh") {
            return bundled
        }
        // Fallback: look relative to executable (handles both .app bundle and direct binary)
        let execDir = (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent
        let relative = (execDir as NSString).appendingPathComponent("../Resources/zsh-autosuggestions.zsh")
        if FileManager.default.fileExists(atPath: relative) {
            return relative
        }
        // When running via CLI symlink (.build/release/Flock), look at project root Resources/
        let resolvedExec = (ProcessInfo.processInfo.arguments[0] as NSString).resolvingSymlinksInPath
        let resolvedDir = (resolvedExec as NSString).deletingLastPathComponent
        for ancestor in ["../../Resources/zsh-autosuggestions.zsh", "../../../Resources/zsh-autosuggestions.zsh"] {
            let path = (resolvedDir as NSString).appendingPathComponent(ancestor)
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }

    /// Clean up stale ZDOTDIR entries from previous crashed sessions
    static func cleanupStale() {
        let tmpBase = NSTemporaryDirectory() + "flock-shell"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: tmpBase) else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        for entry in entries {
            // Each entry is named "<pid>-<random>"
            let parts = entry.split(separator: "-")
            if let pidStr = parts.first, let pid = Int32(pidStr), pid != myPid {
                // Check if that PID is still running
                if kill(pid, 0) != 0 {
                    try? fm.removeItem(atPath: "\(tmpBase)/\(entry)")
                }
            }
        }
    }

    /// Creates a temp ZDOTDIR and returns the environment array for startProcess.
    /// Returns nil if the shell isn't zsh or plugin isn't found.
    static func enhancedEnvironment(workingDirectory: String?, restoreDraft: String? = nil) -> (env: [String], zdotdir: String)? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasSuffix("/zsh") else { return nil }
        guard let plugin = pluginPath else {
            NSLog("[Flock] zsh-autosuggestions plugin not found; shell enhancements disabled")
            return nil
        }

        // Create temp ZDOTDIR
        let tmpBase = NSTemporaryDirectory() + "flock-shell"
        try? FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        let zdotdir = tmpBase + "/\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 1000...9999))"
        try? FileManager.default.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

        // .zshenv — chain user's .zshenv
        let zshenv = """
        [[ -f "\(home)/.zshenv" ]] && ZDOTDIR="\(home)" source "\(home)/.zshenv"
        """
        try? zshenv.write(toFile: zdotdir + "/.zshenv", atomically: true, encoding: .utf8)

        // .zshrc — chain user's .zshrc, then load enhancements.
        // The Flock block uses the absolute zdotdir path (not $ZDOTDIR, which is
        // reassigned to the user's home above) and is fully guarded so it can
        // never break shell startup on an older zsh.
        let zshrc = """
        ZDOTDIR="\(home)"
        [[ -f "\(home)/.zshrc" ]] && source "\(home)/.zshrc"
        source "\(plugin)"
        ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=244"
        ZSH_AUTOSUGGEST_STRATEGY=(history completion)

        # Flock: mirror the current command line so it can be restored next launch
        _flock_buf="\(zdotdir)/buffer"
        _flock_save() { printf '%s' "$BUFFER" > "$_flock_buf" 2>/dev/null }
        _flock_clear() { : > "$_flock_buf" 2>/dev/null }
        autoload -Uz add-zle-hook-widget 2>/dev/null
        add-zle-hook-widget zle-line-pre-redraw _flock_save 2>/dev/null
        add-zle-hook-widget zle-line-finish _flock_clear 2>/dev/null
        # Flock: restore a draft command line saved from a previous session
        if [[ -s "\(zdotdir)/restore" ]]; then
          print -z -- "$(cat "\(zdotdir)/restore" 2>/dev/null)" 2>/dev/null
          rm -f "\(zdotdir)/restore" 2>/dev/null
        fi
        """
        try? zshrc.write(toFile: zdotdir + "/.zshrc", atomically: true, encoding: .utf8)

        // Seed the draft to restore at the next prompt (read by the block above).
        if let draft = restoreDraft, !draft.isEmpty {
            try? draft.write(toFile: zdotdir + "/restore", atomically: true, encoding: .utf8)
        }

        // Build environment array
        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = zdotdir
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Flock"
        env["TERM_PROGRAM_VERSION"] = "1.0"
        if let dir = workingDirectory {
            env["HOME_OVERRIDE"] = dir  // not used, just for reference
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        return (env: envArray, zdotdir: zdotdir)
    }

    /// Clean up a temp ZDOTDIR
    static func cleanup(zdotdir: String) {
        try? FileManager.default.removeItem(atPath: zdotdir)
    }
}
