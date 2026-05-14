import AppKit

final class UpdateChecker {
    static let shared = UpdateChecker()
    static let updateAvailable = Notification.Name("FlockUpdateAvailable")

    private let versionURL = URL(string: "https://baahaus.github.io/flock/version.json")!
    private var hasCheckedThisLaunch = false

    struct Release: Decodable {
        let version: String
        let url: String
        let notes: String?
    }

    struct ChangelogEntry {
        let version: String
        let date: String
        let changes: [String]
    }

    // Local changelog - update manually when cutting a release
    static let localChangelog: [ChangelogEntry] = [
        ChangelogEntry(version: "0.10.0", date: "2026-05-14", changes: [
            "Removed agent mode -- the kanban task queue is gone in favor of just running Claude sessions directly in panes",
            "Removed the memory system and .flock-context.md syncing",
            "Fixed the ~15-minute crash: cost tracker now reads session JSONL incrementally instead of reloading the whole file every 2s",
            "Action history bounded to 500 entries to prevent unbounded growth",
            "Broadcast mode now skips Claude panes showing a confirmation prompt so a stray Enter can't auto-accept it",
            "Markdown panes now detect when a file is deleted on disk and prompt to save here or close the pane",
            "Find bar shows running match cursor in accent color with a flash on each step",
        ]),
        ChangelogEntry(version: "0.9.6", date: "2026-04-13", changes: [
            "Welcome card with animated pixel bird on first launch",
            "File menu: New Markdown File (⌘N), Open Markdown File (⌘O)",
            "Preferences now opens as an overlay instead of a separate window",
            "Live font-size preview -- terminals update as you drag the slider",
            "Agent activity shown as a clean dot instead of a red star",
            "Empty-state hints in agent sidebar, memory panel, and status bar",
            "Long-running commands turn accent at 5min, bold at 15min",
            "Renamed \"Add Agent\" to \"New Task\" for clarity",
            "Tab bar opacity and hover color consistency fixes",
        ]),
        ChangelogEntry(version: "0.9.5", date: "2026-04-06", changes: [
            "Fixed cost tracker double-counting cache tokens",
            "Fixed memory edits silently lost due to lock semantics",
            "Tab close animation now works (was broken since launch)",
            "Find bar no longer disappears permanently after first use",
            "Fixed potential deadlock in Wren compression on large pastes",
            "Fixed mobile scrollbar on landing page",
            "17 total bug fixes from comprehensive audit",
        ]),
        ChangelogEntry(version: "0.9.4", date: "2026-04-06", changes: [
            "Fixed 13 thread safety, process cleanup, and error handling issues",
            "Launch docs and release hardening",
            "Fixed Info.plist corruption in release pipeline",
        ]),
        ChangelogEntry(version: "0.9.3", date: "2026-03-30", changes: [
            "New watercolor flock-of-birds logo",
            "Transparent icon background across all pages",
            "Cache-busted icons for immediate update visibility",
        ]),
        ChangelogEntry(version: "0.9.2", date: "2026-03-30", changes: [
            "Fixed SIGPIPE crash when writing to terminated process pipes",
            "Fixed AppleScript injection vulnerability in notification pane names",
            "Arrow key navigation now works correctly with split panes",
            "Fixed WrenCompressor deadlock on large output",
            "Fixed Close Others closing the wrong tab",
            "Pane focus tracking now uses identity instead of fragile indices",
            "Token usage no longer double-counts cache tokens",
            "31 total bug fixes from comprehensive audit",
        ]),
        ChangelogEntry(version: "0.9.1", date: "2026-03-29", changes: [
            "Wren prompt compression -- toggle in Preferences to compress messages before sending, saving tokens automatically",
            "Works on paste in terminal panes and message input in agent mode",
        ]),
        ChangelogEntry(version: "0.9.0", date: "2026-03-27", changes: [
            "Theme swatches -- color chip picker replaces segmented control",
            "Ember and Vesper dark themes",
            "Memory context now syncs on every change (was write-once)",
            "Change log overlay for Claude panes (Cmd+Shift+L)",
            "Post-update changelog display",
        ]),
        ChangelogEntry(version: "0.8.0", date: "2026-03-15", changes: [
            "Agent mode with parallel task execution",
            "Memory system for persistent context across sessions",
            "Usage tracking dashboard",
            "Session restore improvements",
            "Global hotkey (Ctrl+`) to summon Flock from anywhere",
        ]),
    ]

    // MARK: - Public

    /// Check on launch (once per session, respects setting)
    func checkOnLaunchIfNeeded() {
        guard Settings.shared.autoCheckUpdates, !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        check(silent: true)
    }

    /// Manual check from menu (always shows result)
    func checkNow() {
        check(silent: false)
    }

    // MARK: - Post-update detection

    /// Returns true if app version changed since last launch (user just updated)
    func detectPostUpdate() -> Bool {
        let current = currentVersion
        let last = Settings.shared.lastRunVersion

        // First run with this feature - save version, skip changelog
        guard let last else {
            Settings.shared.lastRunVersion = current
            return false
        }

        if last != current {
            Settings.shared.lastRunVersion = current
            return true
        }

        return false
    }

    /// Build formatted changelog text for terminal display.
    /// Shows all entries between previousVersion and currentVersion.
    func formattedChangelog(previousVersion: String?) -> String {
        let current = currentVersion
        let entries = Self.localChangelog.filter { entry in
            if let prev = previousVersion {
                return isNewer(entry.version, than: prev)
                    && !isNewer(entry.version, than: current)
            }
            return entry.version == current
        }

        let bold = "\u{1B}[1m"
        let dim = "\u{1B}[2m"
        let cyan = "\u{1B}[36m"
        let green = "\u{1B}[32m"
        let reset = "\u{1B}[0m"
        let white = "\u{1B}[37m"

        var lines: [String] = []
        lines.append("")
        lines.append("  \(bold)\(cyan)Flock v\(current) - What's New\(reset)")
        lines.append("  \(dim)Updated successfully\(reset)")
        lines.append("")

        if entries.isEmpty {
            lines.append("  \(white)Bug fixes and improvements.\(reset)")
        } else {
            for entry in entries {
                if entries.count > 1 {
                    lines.append("  \(bold)\(white)v\(entry.version)\(reset) \(dim)(\(entry.date))\(reset)")
                }
                for change in entry.changes {
                    lines.append("  \(green)+\(reset) \(white)\(change)\(reset)")
                }
                if entries.count > 1 { lines.append("") }
            }
        }

        lines.append("")
        lines.append("  \(dim)Close this tab anytime (Cmd+W)\(reset)")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Core

    private func check(silent: Bool) {
        let request = URLRequest(url: versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else {  return }
            guard let data, error == nil else {
                if !silent { self.showNoUpdate() }
                return
            }
            guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
                if !silent { self.showNoUpdate() }
                return
            }
            if self.isNewer(release.version, than: self.currentVersion) {
                DispatchQueue.main.async { self.showUpdateAlert(release) }
            } else if !silent {
                DispatchQueue.main.async { self.showNoUpdate() }
            }
        }.resume()
    }

    // MARK: - Version comparison

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? FlockVersion.current
    }

    func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - UI

    private func showUpdateAlert(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Flock v\(release.version) Available"
        alert.informativeText = release.notes ?? "A new version of Flock is available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: release.url),
               let scheme = url.scheme,
               scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showNoUpdate() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "You're Up to Date"
            alert.informativeText = "Flock v\(self.currentVersion) is the latest version."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// Fallback version constant (used when not running as .app bundle)
enum FlockVersion {
    static let current = "0.9.6"
}
