import Cocoa

enum StatusPresentation {
    case customBar
    case renderedBar
}

@MainActor
final class ProviderStatusController: NSObject {
    private let providerID: ProviderID
    private let client: ProviderClient
    private let presentation: StatusPresentation
    private let healthyIconColor: NSColor
    private let logger = DiagnosticsLogger.shared
    private let menu = NSMenu()
    private let statusItem: NSStatusItem
    private let statusView: PassThroughStatusView
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var latestSnapshot: ProviderSnapshot?

    private let currentItem = NSMenuItem(title: "Current session: loading…", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "Weekly: loading…", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "Credits: loading…", action: nil, keyEquivalent: "")
    private let planItem = NSMenuItem(title: "Plan: loading…", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "Source: loading…", action: nil, keyEquivalent: "")
    private let featureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let logPathItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var enableFeatureItem: NSMenuItem?

    var onRefresh: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onQuit: (() -> Void)?
    var onEnableFeature: (() -> Void)?

    init(providerID: ProviderID, icon: NSImage?, client: ProviderClient, logURL: URL, presentation: StatusPresentation = .customBar) {
        self.providerID = providerID
        self.client = client
        self.presentation = presentation
        self.healthyIconColor = providerID == .codex
            ? NSColor(calibratedWhite: 0.96, alpha: 0.98)
            : .systemOrange
        self.statusView = PassThroughStatusView(icon: icon)
        self.statusItem = NSStatusBar.system.statusItem(withLength: statusView.intrinsicContentSize.width)
        super.init()
        statusView.loadingIconColor = healthyIconColor
        setupStatusItem()
        setupMenu(logURL: logURL)
    }

    func refresh() {
        if refreshTask != nil {
            logger.log("\(providerID.displayName) refresh skipped because a request is already in flight")
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        applyStatusPresentation(.loading)
        statusView.toolTip = "\(providerID.statusToolTipPrefix): loading"

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            do {
                let snapshot = try await self.client.fetchSnapshot()
                guard generation == self.refreshGeneration else {
                    return
                }
                self.apply(snapshot: snapshot)
            } catch {
                guard generation == self.refreshGeneration else {
                    return
                }
                self.apply(error: error)
            }
        }
    }

    func refreshCountdownOnly() {
        guard let snapshot = latestSnapshot else {
            return
        }
        apply(snapshot: snapshot, preserveMenuState: true)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        switch presentation {
        case .customBar:
            statusView.frame = NSRect(origin: .zero, size: statusView.intrinsicContentSize)
            statusView.onSizeChange = { [weak self] in
                self?.updateStatusItemWidth()
            }
            button.frame.size.width = statusView.intrinsicContentSize.width
            button.addSubview(statusView)
            updateStatusItemWidth()
        case .renderedBar:
            statusItem.length = max(1, ceil(statusView.intrinsicContentSize.width))
        }
    }

    private func updateStatusItemWidth() {
        let width = max(1, ceil(statusView.fittingSize.width))
        statusItem.length = width
        statusItem.button?.frame.size.width = width
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: 22)
    }

    private func setupMenu(logURL: URL) {
        errorItem.isHidden = true
        logPathItem.title = "Log: \(logURL.lastPathComponent)"

        menu.addItem(currentItem)
        menu.addItem(weeklyItem)
        menu.addItem(creditsItem)
        menu.addItem(planItem)
        menu.addItem(sourceItem)
        menu.addItem(errorItem)
        menu.addItem(logPathItem)

        if providerID == .codex {
            menu.addItem(featureStatusItem)
            menu.addItem(.separator())

            let enableItem = NSMenuItem(title: "Enable Codex…", action: #selector(enableFeature), keyEquivalent: "")
            enableItem.target = self
            menu.addItem(enableItem)
            menu.addItem(.separator())
            enableFeatureItem = enableItem
        } else {
            featureStatusItem.isHidden = true
        }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openLogItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile), keyEquivalent: "l")
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Agent Token Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func refreshNow() {
        onRefresh?()
    }

    @objc private func openLogFile() {
        onOpenLog?()
    }

    @objc private func enableFeature() {
        onEnableFeature?()
    }

    @objc private func quitApp() {
        onQuit?()
    }

    func refresh(force: Bool) {
        if force {
            refreshGeneration += 1
            refreshTask?.cancel()
            refreshTask = nil
        }
        refresh()
    }

    func setEnableFeatureEnabled(_ enabled: Bool) {
        enableFeatureItem?.title = enabled ? "Reauthorize Codex…" : "Enable Codex…"
        featureStatusItem.title = "Codex Access: \(enabled ? "enabled" : "not enabled")"
    }

    private func apply(snapshot: ProviderSnapshot, preserveMenuState: Bool = false) {
        latestSnapshot = snapshot

        let displayWindow = snapshot.primary ?? snapshot.secondary
        if let displayWindow {
            let used = displayWindow.usedPercent
            let resetText = UsageFormatter.countdownText(to: displayWindow.resetsAt)
            let iconColor = iconColor(for: used)
            applyStatusPresentation(.loaded(usedPercent: used, resetText: resetText, iconColor: iconColor))
            let lane = snapshot.primary != nil ? "session" : "weekly"
            statusView.toolTip = "\(providerID.statusToolTipPrefix): \(lane) \(used)% used, reset \(resetText)"
        } else {
            applyStatusPresentation(.error("No active window"))
            statusView.toolTip = "\(providerID.statusToolTipPrefix): no active window"
        }

        if preserveMenuState {
            currentItem.title = currentRowTitle(from: snapshot.primary)
            weeklyItem.title = weeklyRowTitle(from: snapshot.secondary)
            return
        }

        currentItem.title = currentRowTitle(from: snapshot.primary)
        weeklyItem.title = weeklyRowTitle(from: snapshot.secondary)
        creditsItem.title = "Credits: \(snapshot.credits?.text ?? "unavailable")"
        planItem.title = "Plan: \(snapshot.plan ?? "unavailable")"
        sourceItem.title = "Source: \(snapshot.sourceLabel)"
        errorItem.isHidden = true
    }

    private func apply(error: Error) {
        latestSnapshot = nil
        applyStatusPresentation(.error(error.localizedDescription))
        statusView.toolTip = error.localizedDescription
        currentItem.title = "Current session: unavailable"
        weeklyItem.title = "Weekly: unavailable"
        creditsItem.title = "Credits: unavailable"
        planItem.title = "Plan: unavailable"
        sourceItem.title = "Source: unavailable"
        errorItem.title = "Error: \(error.localizedDescription)"
        errorItem.isHidden = false
    }

    private func currentRowTitle(from window: ProviderWindowSnapshot?) -> String {
        guard let window else { return "Current session: unavailable" }
        return "Current session: \(window.usedPercent)% used (\(UsageFormatter.countdownText(to: window.resetsAt)))"
    }

    private func weeklyRowTitle(from window: ProviderWindowSnapshot?) -> String {
        guard let window else { return "Weekly: unavailable" }
        return "Weekly: \(window.usedPercent)% used (\(UsageFormatter.countdownText(to: window.resetsAt)))"
    }

    private func iconColor(for usedPercent: Int) -> NSColor {
        let remainingPercent = max(0, 100 - usedPercent)
        if remainingPercent <= 10 {
            return .systemRed
        }
        if remainingPercent <= 20 {
            return .systemYellow
        }
        return healthyIconColor
    }

    private func applyStatusPresentation(_ state: MeterState) {
        switch presentation {
        case .customBar:
            statusView.state = state
        case .renderedBar:
            guard let button = statusItem.button else { return }
            statusView.state = state
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = statusView.snapshotImage()
            if let image = button.image {
                statusItem.length = max(1, ceil(image.size.width))
            }
        }
    }
}
