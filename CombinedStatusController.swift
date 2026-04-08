import Cocoa

@MainActor
final class CombinedStatusController: NSObject {
    private let logger = DiagnosticsLogger.shared
    private let menu = NSMenu()
    private let statusItem: NSStatusItem
    private let statusView: CombinedStatusItemView
    private let claudeClient: ProviderClient
    private let codexClient: ProviderClient
    private var claudeEnabled = ProviderVisibilityPreferences.isEnabled(.claude)
    private var codexEnabled = ProviderVisibilityPreferences.isEnabled(.codex)
    private var codexAccessEnabled = false

    private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
    private var refreshGenerations: [ProviderID: Int] = [.claude: 0, .codex: 0]
    private var latestSnapshots: [ProviderID: ProviderSnapshot] = [:]
    private var latestErrors: [ProviderID: Error] = [:]

    private let claudeHeaderItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
    private let claudeCurrentItem = NSMenuItem(title: "Current session: loading…", action: nil, keyEquivalent: "")
    private let claudeWeeklyItem = NSMenuItem(title: "Weekly: loading…", action: nil, keyEquivalent: "")
    private let claudeCreditsItem = NSMenuItem(title: "Credits: loading…", action: nil, keyEquivalent: "")
    private let claudePlanSourceItem = NSMenuItem(title: "Plan: loading… | Source: loading…", action: nil, keyEquivalent: "")
    private let claudeErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let claudeToggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let codexHeaderItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
    private let codexCurrentItem = NSMenuItem(title: "Current session: loading…", action: nil, keyEquivalent: "")
    private let codexWeeklyItem = NSMenuItem(title: "Weekly: loading…", action: nil, keyEquivalent: "")
    private let codexCreditsItem = NSMenuItem(title: "Credits: loading…", action: nil, keyEquivalent: "")
    private let codexPlanSourceItem = NSMenuItem(title: "Plan: loading… | Source: loading…", action: nil, keyEquivalent: "")
    private let codexErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexToggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexAuthorizeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var onOpenLog: (() -> Void)?
    var onQuit: (() -> Void)?
    var onEnableCodex: (() -> Void)?

    init(claudeIcon: NSImage?, codexIcon: NSImage?, logURL: URL) {
        self.claudeClient = ClaudeProviderClient()
        self.codexClient = CodexProviderClient()
        self.statusView = CombinedStatusItemView(claudeIcon: claudeIcon, codexIcon: codexIcon)
        self.statusItem = NSStatusBar.system.statusItem(withLength: statusView.intrinsicContentSize.width)
        super.init()
        setupStatusItem()
        setupMenu(logURL: logURL)
        setClaudeEnabled(claudeEnabled, persist: false)
        setCodexEnabled(codexEnabled, persist: false)
        setCodexAccessEnabled(CodexAuthAccess.hasAuthorizedFile())
    }

    func refreshAll() {
        if claudeEnabled {
            refresh(providerID: .claude)
        }
        if codexEnabled && codexAccessEnabled {
            refresh(providerID: .codex)
        }
    }

    func refreshCountdownOnly() {
        if claudeEnabled, let snapshot = latestSnapshots[.claude] {
            apply(snapshot: snapshot, providerID: .claude, preserveMenuState: true)
        }
        if codexEnabled, codexAccessEnabled, let snapshot = latestSnapshots[.codex] {
            apply(snapshot: snapshot, providerID: .codex, preserveMenuState: true)
        }
    }

    func refreshCodex(force: Bool) {
        guard codexEnabled, codexAccessEnabled else {
            return
        }
        if force {
            refreshGenerations[.codex, default: 0] += 1
            refreshTasks[.codex]?.cancel()
            refreshTasks[.codex] = nil
        }
        refresh(providerID: .codex)
    }

    func setCodexAccessEnabled(_ enabled: Bool) {
        codexAccessEnabled = enabled
        codexAuthorizeItem.title = enabled ? "Reauthorize Codex…" : "Enable Codex Access…"
        updateProviderVisibility()
        if enabled {
            codexCurrentItem.title = "Current session: loading…"
            codexWeeklyItem.title = "Weekly: loading…"
            codexCreditsItem.title = "Credits: loading…"
            codexPlanSourceItem.title = "Plan: loading… | Source: loading…"
            codexErrorItem.isHidden = true
        } else {
            refreshTasks[.codex]?.cancel()
            refreshTasks[.codex] = nil
            latestSnapshots[.codex] = nil
            latestErrors[.codex] = nil
            codexCurrentItem.title = "Current session: enable Codex to view usage"
            codexWeeklyItem.title = "Weekly: enable Codex to view usage"
            codexCreditsItem.title = "Credits: unavailable"
            codexPlanSourceItem.title = "Plan: unavailable | Source: unavailable"
            codexErrorItem.isHidden = true
            statusView.codexState = .loading
        }
        updateSectionVisibility(for: .codex)
        updateTooltip()
    }

    private func refresh(providerID: ProviderID) {
        if refreshTasks[providerID] != nil {
            logger.log("\(providerID.displayName) refresh skipped because a request is already in flight")
            return
        }

        refreshGenerations[providerID, default: 0] += 1
        let generation = refreshGenerations[providerID, default: 0]
        applyLoadingState(for: providerID)

        let client = providerID == .claude ? claudeClient : codexClient
        refreshTasks[providerID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshTasks[providerID] = nil }
            do {
                let snapshot = try await client.fetchSnapshot()
                guard generation == self.refreshGenerations[providerID, default: 0] else {
                    return
                }
                self.apply(snapshot: snapshot, providerID: providerID)
            } catch {
                guard generation == self.refreshGenerations[providerID, default: 0] else {
                    return
                }
                self.apply(error: error, providerID: providerID)
            }
        }
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = "CTM"
        button.image = nil
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        logger.log("Combined status item setup; button available with initial width \(statusView.intrinsicContentSize.width)")
        statusView.onSizeChange = { [weak self] in
            self?.renderStatusItem()
        }
        renderStatusItem()
        statusItem.menu = menu
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let fittingSize = statusView.intrinsicContentSize
        let image = statusView.snapshotImage()

        if statusView.hasVisibleProviders, let image {
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = image
            let width = max(1, ceil(image.size.width))
            statusItem.length = width
            button.frame = NSRect(x: button.frame.origin.x, y: button.frame.origin.y, width: width, height: button.frame.height)
            button.needsLayout = true
            logger.log(
                "Combined status rendered image \(Int(image.size.width))x\(Int(image.size.height)); " +
                "fitting \(Int(fittingSize.width))x\(Int(fittingSize.height)); " +
                "buttonWidth=\(Int(button.frame.width)); codexVisible=\(statusView.codexVisible)"
            )
        } else {
            button.image = nil
            button.title = "CTM"
            button.imagePosition = .noImage
            statusItem.length = NSStatusItem.variableLength
            button.needsLayout = true
            logger.log(
                "Combined status snapshot returned nil; falling back to title. " +
                "fitting \(Int(fittingSize.width))x\(Int(fittingSize.height)); " +
                "buttonWidth=\(Int(button.frame.width)); codexVisible=\(statusView.codexVisible)"
            )
        }
    }

    private func setupMenu(logURL: URL) {
        let claudeSubmenu = NSMenu(title: "Claude")
        claudeToggleItem.target = self
        claudeToggleItem.action = #selector(toggleClaudeEnabled)
        claudeSubmenu.addItem(claudeToggleItem)
        claudeHeaderItem.submenu = claudeSubmenu

        let codexSubmenu = NSMenu(title: "Codex")
        codexToggleItem.target = self
        codexToggleItem.action = #selector(toggleCodexEnabled)
        codexSubmenu.addItem(codexToggleItem)
        codexSubmenu.addItem(.separator())
        codexAuthorizeItem.target = self
        codexAuthorizeItem.action = #selector(enableCodex)
        codexSubmenu.addItem(codexAuthorizeItem)
        codexHeaderItem.submenu = codexSubmenu

        claudeErrorItem.isHidden = true
        codexErrorItem.isHidden = true
        _ = logURL

        menu.addItem(claudeHeaderItem)
        menu.addItem(claudeCurrentItem)
        menu.addItem(claudeWeeklyItem)
        menu.addItem(claudeCreditsItem)
        menu.addItem(claudePlanSourceItem)
        menu.addItem(claudeErrorItem)
        menu.addItem(.separator())

        menu.addItem(codexHeaderItem)
        menu.addItem(codexCurrentItem)
        menu.addItem(codexWeeklyItem)
        menu.addItem(codexCreditsItem)
        menu.addItem(codexPlanSourceItem)
        menu.addItem(codexErrorItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openLogItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile), keyEquivalent: "l")
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Token Meter", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func refreshNow() {
        refreshAll()
    }

    @objc private func openLogFile() {
        onOpenLog?()
    }

    @objc private func enableCodex() {
        onEnableCodex?()
    }

    @objc private func toggleClaudeEnabled() {
        setClaudeEnabled(!claudeEnabled)
    }

    @objc private func toggleCodexEnabled() {
        setCodexEnabled(!codexEnabled)
    }

    @objc private func quitApp() {
        onQuit?()
    }

    private func applyLoadingState(for providerID: ProviderID) {
        switch providerID {
        case .claude:
            statusView.claudeState = .loading
        case .codex:
            statusView.codexState = .loading
        }
        updateTooltip()
    }

    private func apply(snapshot: ProviderSnapshot, providerID: ProviderID, preserveMenuState: Bool = false) {
        latestSnapshots[providerID] = snapshot
        latestErrors[providerID] = nil

        let displayWindow = snapshot.primary ?? snapshot.secondary
        let state: MeterState
        if let displayWindow {
            let used = displayWindow.usedPercent
            let resetText = UsageFormatter.countdownText(to: displayWindow.resetsAt)
            let iconColor = iconColor(for: providerID, usedPercent: used)
            state = .loaded(usedPercent: used, resetText: resetText, iconColor: iconColor)
        } else {
            state = .error("No active window")
        }

        switch providerID {
        case .claude:
            statusView.claudeState = state
        case .codex:
            statusView.codexState = state
        }
        updateTooltip()

        let currentTitle = currentRowTitle(from: snapshot.primary)
        let weeklyTitle = weeklyRowTitle(from: snapshot.secondary)

        if preserveMenuState {
            switch providerID {
            case .claude:
                claudeCurrentItem.title = currentTitle
                claudeWeeklyItem.title = weeklyTitle
            case .codex:
                codexCurrentItem.title = currentTitle
                codexWeeklyItem.title = weeklyTitle
            }
            return
        }

        switch providerID {
        case .claude:
            claudeCurrentItem.title = currentTitle
            claudeWeeklyItem.title = weeklyTitle
            claudeCreditsItem.title = "Credits: \(snapshot.credits?.text ?? "unavailable")"
            claudeCreditsItem.isHidden = snapshot.credits == nil
            claudePlanSourceItem.title = "Plan: \(snapshot.plan ?? "unavailable") | Source: \(snapshot.sourceLabel)"
            claudeErrorItem.isHidden = true
        case .codex:
            codexCurrentItem.title = currentTitle
            codexWeeklyItem.title = weeklyTitle
            codexCreditsItem.title = "Credits: \(snapshot.credits?.text ?? "unavailable")"
            codexCreditsItem.isHidden = snapshot.credits == nil
            codexPlanSourceItem.title = "Plan: \(snapshot.plan ?? "unavailable") | Source: \(snapshot.sourceLabel)"
            codexErrorItem.isHidden = true
        }
    }

    private func apply(error: Error, providerID: ProviderID) {
        latestSnapshots[providerID] = nil
        latestErrors[providerID] = error
        switch providerID {
        case .claude:
            statusView.claudeState = .error(error.localizedDescription)
            claudeCurrentItem.title = "Current session: unavailable"
            claudeWeeklyItem.title = "Weekly: unavailable"
            claudeCreditsItem.title = "Credits: unavailable"
            claudeCreditsItem.isHidden = false
            claudePlanSourceItem.title = "Plan: unavailable | Source: unavailable"
            claudeErrorItem.title = "Error: \(error.localizedDescription)"
            claudeErrorItem.isHidden = false
        case .codex:
            statusView.codexState = .error(error.localizedDescription)
            codexCurrentItem.title = "Current session: unavailable"
            codexWeeklyItem.title = "Weekly: unavailable"
            codexCreditsItem.title = "Credits: unavailable"
            codexCreditsItem.isHidden = false
            codexPlanSourceItem.title = "Plan: unavailable | Source: unavailable"
            codexErrorItem.title = "Error: \(error.localizedDescription)"
            codexErrorItem.isHidden = false
        }
        updateTooltip()
    }

    private func updateTooltip() {
        let claudeTooltip = tooltipText(for: .claude, snapshot: latestSnapshots[.claude], error: latestErrors[.claude])
        let codexTooltip = tooltipText(for: .codex, snapshot: latestSnapshots[.codex], error: latestErrors[.codex])
        statusView.toolTip = "\(claudeTooltip)\n\(codexTooltip)"
    }

    private func tooltipText(for providerID: ProviderID, snapshot: ProviderSnapshot?, error: Error?) -> String {
        if !isProviderEnabled(providerID) {
            return "\(providerID.statusToolTipPrefix): disabled"
        }
        if providerID == .codex && !codexAccessEnabled {
            return "\(providerID.statusToolTipPrefix): access not enabled"
        }
        if let error {
            return "\(providerID.statusToolTipPrefix): \(error.localizedDescription)"
        }
        guard let snapshot else {
            return "\(providerID.statusToolTipPrefix): loading"
        }
        let displayWindow = snapshot.primary ?? snapshot.secondary
        guard let displayWindow else {
            return "\(providerID.statusToolTipPrefix): no active window"
        }
        let lane = snapshot.primary != nil ? "session" : "weekly"
        let resetText = UsageFormatter.countdownText(to: displayWindow.resetsAt)
        return "\(providerID.statusToolTipPrefix): \(lane) \(displayWindow.usedPercent)% used, reset \(resetText)"
    }

    private func currentRowTitle(from window: ProviderWindowSnapshot?) -> String {
        guard let window else { return "Current session: unavailable" }
        return "Current session: \(window.usedPercent)% used (\(UsageFormatter.countdownText(to: window.resetsAt)))"
    }

    private func weeklyRowTitle(from window: ProviderWindowSnapshot?) -> String {
        guard let window else { return "Weekly: unavailable" }
        return "Weekly: \(window.usedPercent)% used (\(UsageFormatter.countdownText(to: window.resetsAt)))"
    }

    private func iconColor(for providerID: ProviderID, usedPercent: Int) -> NSColor {
        let remainingPercent = max(0, 100 - usedPercent)
        if remainingPercent <= 10 {
            return .systemRed
        }
        if remainingPercent <= 20 {
            return .systemYellow
        }
        if providerID == .codex {
            return NSColor(calibratedWhite: 0.96, alpha: 0.98)
        }
        return .systemOrange
    }

    private func setClaudeEnabled(_ enabled: Bool, persist: Bool = true) {
        claudeEnabled = enabled
        if persist {
            ProviderVisibilityPreferences.setEnabled(enabled, for: .claude)
        }
        claudeToggleItem.title = enabled ? "Disable Claude" : "Enable Claude"
        if !enabled {
            refreshTasks[.claude]?.cancel()
            refreshTasks[.claude] = nil
        }
        updateProviderVisibility()
        updateSectionVisibility(for: .claude)
        updateTooltip()
        if enabled {
            refresh(providerID: .claude)
        }
    }

    private func setCodexEnabled(_ enabled: Bool, persist: Bool = true) {
        codexEnabled = enabled
        if persist {
            ProviderVisibilityPreferences.setEnabled(enabled, for: .codex)
        }
        codexToggleItem.title = enabled ? "Disable Codex" : "Enable Codex"
        if !enabled {
            refreshTasks[.codex]?.cancel()
            refreshTasks[.codex] = nil
        }
        updateProviderVisibility()
        updateSectionVisibility(for: .codex)
        updateTooltip()
        if enabled, codexAccessEnabled {
            refresh(providerID: .codex)
        }
    }

    private func updateProviderVisibility() {
        statusView.claudeVisible = claudeEnabled
        statusView.codexVisible = codexEnabled && codexAccessEnabled
    }

    private func updateSectionVisibility(for providerID: ProviderID) {
        let isVisible = isSectionVisible(providerID)
        switch providerID {
        case .claude:
            for item in claudeSectionItems {
                item.isHidden = !isVisible
            }
        case .codex:
            for item in codexSectionItems {
                item.isHidden = !isVisible
            }
        }
    }

    private func isProviderEnabled(_ providerID: ProviderID) -> Bool {
        switch providerID {
        case .claude:
            return claudeEnabled
        case .codex:
            return codexEnabled
        }
    }

    private func isSectionVisible(_ providerID: ProviderID) -> Bool {
        switch providerID {
        case .claude:
            return claudeEnabled
        case .codex:
            return codexEnabled && codexAccessEnabled
        }
    }

    private var claudeSectionItems: [NSMenuItem] {
        [claudeCurrentItem, claudeWeeklyItem, claudeCreditsItem, claudePlanSourceItem, claudeErrorItem]
    }

    private var codexSectionItems: [NSMenuItem] {
        [codexCurrentItem, codexWeeklyItem, codexCreditsItem, codexPlanSourceItem, codexErrorItem]
    }
}
