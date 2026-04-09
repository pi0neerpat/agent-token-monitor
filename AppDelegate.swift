import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DiagnosticsLogger.shared
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var combinedController: CombinedStatusController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("Application launched")
        setupProviders()
        refreshAllProviders()

        refreshTimer = Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(handleRefreshTimer), userInfo: nil, repeats: true)
        countdownTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(handleCountdownTimer), userInfo: nil, repeats: true)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
    }

    @MainActor
    private func setupProviders() {
        let claudeIcon = NSImage(named: "ClaudeMenuIcon") ?? Bundle.main.image(forResource: "clawd")
        let codexIcon = NSImage(named: "CodexMenuIcon") ?? Bundle.main.image(forResource: "codex-icon")
        let controller = CombinedStatusController(
            claudeIcon: claudeIcon,
            codexIcon: codexIcon,
            logURL: logger.logURL
        )
        controller.onOpenLog = { [weak self] in
            self?.openLogFile()
        }
        controller.onQuit = { [weak self] in
            self?.quitApp()
        }
        controller.onEnableCodex = { [weak self] in
            self?.enableCodex()
        }
        combinedController = controller
    }

    @MainActor
    private func refreshAllProviders() {
        combinedController?.refreshAll()
    }

    @MainActor
    private func refreshCountdownOnly() {
        combinedController?.refreshCountdownOnly()
    }

    @MainActor
    @objc private func handleRefreshTimer() {
        refreshAllProviders()
    }

    @MainActor
    @objc private func handleCountdownTimer() {
        refreshCountdownOnly()
    }

    @MainActor
    private func openLogFile() {
        NSWorkspace.shared.open(logger.logURL)
    }

    @MainActor
    private func quitApp() {
        logger.log("Application quitting")
        NSApp.terminate(nil)
    }

    @MainActor
    private func enableCodex() {
        let authURL = CodexAuthAccess.defaultAuthFileURL()

        let alert = NSAlert()
        alert.messageText = "Enable Codex"
        alert.informativeText = """
        Agent Token Monitor is sandboxed, so macOS requires one-time permission before it can read your Codex credentials. The next panel will ask you to choose your Codex auth file, usually \(authURL.path).

        The app stores a security-scoped bookmark for that file and only uses it to read Codex usage data.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Codex auth.json"
        panel.message = "Select the Codex auth.json file to enable Codex usage tracking."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = authURL.deletingLastPathComponent()
        panel.nameFieldStringValue = authURL.lastPathComponent

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try CodexAuthAccess.authorize(url: url)
            logger.log("Codex auth file access granted for \(url.path)")
            combinedController?.setCodexAccessEnabled(true)
            combinedController?.refreshCodex(force: true)
        } catch {
            logger.log("Failed to enable Codex: \(error.localizedDescription)")
            let errorAlert = NSAlert(error: error)
            errorAlert.runModal()
        }
    }
}
