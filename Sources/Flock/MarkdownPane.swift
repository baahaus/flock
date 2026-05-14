import AppKit
import Foundation

class MarkdownPane: FlockPane, NSTextViewDelegate {
    let filePath: String

    private let scrollView = NSScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private var reloadTimer: Timer?
    private var saveTimer: Timer?
    private var lastModifiedAt: Date?
    private var pendingExternalModification: Date?
    private var hasPendingLocalEdits = false
    private var isApplyingDiskContent = false
    private var isPresentingConflictAlert = false
    private var fileMissingHandled = false

    override var firstResponderView: NSView { textView }

    init(filePath: String, manager: PaneManager) {
        self.filePath = filePath
        super.init(type: .markdown, manager: manager)

        currentDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path

        setupScrollView()
        updateTitleBar()
        loadFromDisk()
        startWatchingFile()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: Settings.didChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reloadTimer?.invalidate()
        saveTimer?.invalidate()
    }

    override func updateTitleBar() {
        let url = URL(fileURLWithPath: filePath)
        titleProcessLabel.stringValue = customName ?? url.lastPathComponent

        let dir = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        titleCwdLabel.stringValue = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    override func layoutContent() {
        let pad: CGFloat = 8
        scrollView.frame = CGRect(
            x: pad,
            y: titleBarHeight,
            width: clipView.bounds.width - pad * 2,
            height: clipView.bounds.height - titleBarHeight - pad
        )
    }

    override func themeDidChange() {
        applyTextViewTheme()
    }

    override func matchesSearchTerm(_ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        return textView.string.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    override func shutdown() {
        saveTimer?.invalidate()
        saveTimer = nil
        flushPendingSave(force: true)
        reloadTimer?.invalidate()
        reloadTimer = nil
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String, key == "fontSize" else { return }
        applyTextViewTheme()
    }

    private func setupScrollView() {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [.foregroundColor: Theme.accent]
        applyTextViewTheme()

        scrollView.documentView = textView
        clipView.addSubview(scrollView)
    }

    private func applyTextViewTheme() {
        textView.font = NSFont.monospacedSystemFont(ofSize: Settings.shared.fontSize, weight: .regular)
        textView.insertionPointColor = Theme.textPrimary
        textView.textColor = Theme.textPrimary
        textView.backgroundColor = .clear
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: Settings.shared.fontSize, weight: .regular),
            .foregroundColor: Theme.textPrimary,
        ]
    }

    private func startWatchingFile() {
        lastModifiedAt = fileModificationDate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: self.filePath) {
                self.handleFileDeleted()
                return
            }
            self.fileMissingHandled = false
            let modifiedAt = self.fileModificationDate()
            guard modifiedAt != self.lastModifiedAt else { return }

            guard !self.hasPendingLocalEdits else {
                self.pendingExternalModification = modifiedAt
                self.presentExternalChangeConflictAlertIfNeeded()
                return
            }
            self.lastModifiedAt = modifiedAt
            self.loadFromDisk()
        }
    }

    private func handleFileDeleted() {
        guard !fileMissingHandled else { return }
        fileMissingHandled = true
        textView.isEditable = false

        let alert = NSAlert()
        alert.messageText = "Markdown File Deleted"
        alert.informativeText = "\(URL(fileURLWithPath: filePath).lastPathComponent) was removed from disk. Save a new copy here, or close this pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Here")
        alert.addButton(withTitle: "Close Pane")

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.textView.isEditable = true
                self.hasPendingLocalEdits = true
                self.flushPendingSave(force: true)
                self.fileMissingHandled = false
                self.lastModifiedAt = self.fileModificationDate()
            } else if let mgr = self.manager,
                      let idx = mgr.panes.firstIndex(where: { $0 === self }) {
                mgr.closePane(at: idx)
            }
        }
        if let win = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: win, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func fileModificationDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        return attrs?[.modificationDate] as? Date
    }

    private func loadFromDisk() {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            isApplyingDiskContent = true
            textView.string = "Could not read file:\n\(filePath)"
            isApplyingDiskContent = false
            textView.isEditable = false
            pendingExternalModification = nil
            lastModifiedAt = fileModificationDate()
            return
        }

        textView.isEditable = true
        isApplyingDiskContent = true
        textView.string = content
        isApplyingDiskContent = false
        hasPendingLocalEdits = false
        pendingExternalModification = nil
        lastModifiedAt = fileModificationDate()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDiskContent else { return }
        hasPendingLocalEdits = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.flushPendingSave(force: false)
        }
    }

    private func flushPendingSave(force: Bool) {
        guard hasPendingLocalEdits else { return }
        guard force || pendingExternalModification == nil else {
            presentExternalChangeConflictAlertIfNeeded()
            return
        }
        let content = textView.string
        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            hasPendingLocalEdits = false
            pendingExternalModification = nil
            lastModifiedAt = fileModificationDate()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Save Markdown File"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let win = window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: win)
            } else {
                alert.runModal()
            }
        }
    }

    private func presentExternalChangeConflictAlertIfNeeded() {
        guard pendingExternalModification != nil, !isPresentingConflictAlert else { return }
        isPresentingConflictAlert = true

        let alert = NSAlert()
        alert.messageText = "Markdown File Changed on Disk"
        alert.informativeText = "This file changed outside Flock while you also have local edits. Keep your version to overwrite the disk copy, or reload to discard your local edits."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reload")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isPresentingConflictAlert = false

            if response == .alertFirstButtonReturn {
                self.flushPendingSave(force: true)
            } else {
                self.loadFromDisk()
            }
        }

        if let win = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: win, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}
