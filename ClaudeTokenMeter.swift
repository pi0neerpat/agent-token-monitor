import Cocoa
import Foundation
import Security

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    let logURL: URL
    private let queue = DispatchQueue(label: "ClaudeTokenMeter.DiagnosticsLogger")
    private let isoFormatter = ISO8601DateFormatter()

    private init() {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.scribular.claude-token-meter"
        let baseDir = appSupportDir.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        logURL = baseDir.appendingPathComponent("ClaudeTokenMeter.log")
    }

    func log(_ message: String) {
        let line = "[\(isoFormatter.string(from: Date()))] \(message)\n"
        queue.async { [logURL] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
        fputs(line, stderr)
    }
}

struct ClaudeUsageResponse: Decodable {
    struct RateLimit: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct ExtraUsage: Decodable {
        let is_enabled: Bool
        let monthly_limit: Int?
        let used_credits: Int?
        let utilization: Double?
    }

    let five_hour: RateLimit?
    let seven_day: RateLimit?
    let seven_day_oauth_apps: RateLimit?
    let seven_day_opus: RateLimit?
    let seven_day_sonnet: RateLimit?
    let extra_usage: ExtraUsage?
}

struct OAuthTokens: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: String?
    let scopes: [String]?
    let subscriptionType: String?
    let rateLimitTier: String?
}

enum AppError: LocalizedError {
    case missingCredentials
    case unsupportedEndpoint
    case invalidUsageURL
    case invalidResponse
    case networkFailure(String)
    case httpFailure(status: Int)
    case decodeFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No supported Claude credentials were found in Keychain."
        case .unsupportedEndpoint:
            return "Release builds only allow requests to approved Anthropic hosts."
        case .invalidUsageURL:
            return "The usage API URL is invalid."
        case .invalidResponse:
            return "The usage API returned no data."
        case .networkFailure(let message):
            return "Network error: \(message)"
        case .httpFailure(let status):
            if status == 401 || status == 403 {
                return "Authorization failed. Reconnect Claude and try again."
            }
            return "Usage API returned HTTP \(status)."
        case .decodeFailure:
            return "The usage API response could not be parsed."
        }
    }
}

enum MeterState {
    case loading
    case loaded(usedPercent: Int, resetText: String, iconColor: NSColor)
    case error(String)
}

final class MeterBarView: NSView {
    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var percentText: String = "--" {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 82, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 1.0, alpha: 0.08).setFill()
        bgPath.fill()

        let clamped = max(0.0, min(1.0, progress))
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * clamped, height: rect.height)
        if fillRect.width > 0 {
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            let fillGradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.98, alpha: 1.0),
                NSColor(calibratedRed: 0.03, green: 0.44, blue: 0.90, alpha: 1.0)
            ])
            fillGradient?.draw(in: fillPath, angle: 0)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 0.98),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: percentText, attributes: attrs)
        attributed.draw(with: NSRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: rect.height + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

final class PassThroughStatusView: NSView {
    var onSizeChange: (() -> Void)?

    var state: MeterState = .loading {
        didSet {
            applyState()
        }
    }

    private let icon: NSImage?
    private let iconView = NSImageView()
    private let meterView = MeterBarView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

    override var intrinsicContentSize: NSSize {
        let size = stackView.fittingSize
        return NSSize(width: ceil(size.width), height: 22)
    }

    init(icon: NSImage?) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 166, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Claude Token Meter"
        configureSubviews()
        applyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15)
        ])

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.setContentHuggingPriority(.required, for: .horizontal)
        meterView.setContentCompressionResistancePriority(.required, for: .horizontal)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        timeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        timeLabel.alignment = .left
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 3
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(meterView)
        stackView.addArrangedSubview(timeLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyState() {
        switch state {
        case .loading:
            iconView.image = tintedImage(color: .systemOrange)
            meterView.progress = 0.18
            meterView.percentText = "--"
            timeLabel.stringValue = "sync"
            timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        case .loaded(let usedPercent, let resetText, let iconColor):
            iconView.image = tintedImage(color: iconColor)
            meterView.progress = CGFloat(usedPercent) / 100.0
            meterView.percentText = "\(usedPercent)%"
            timeLabel.stringValue = resetText
            timeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 0.95)
        case .error:
            iconView.image = tintedImage(color: NSColor(calibratedWhite: 0.62, alpha: 0.95))
            meterView.progress = 0.0
            meterView.percentText = "--"
            timeLabel.stringValue = "err"
            timeLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 0.95)
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onSizeChange?()
    }

    private func tintedImage(color: NSColor) -> NSImage? {
        guard let icon else { return nil }
        let image = icon.copy() as? NSImage ?? icon
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

final class UsageService {
    private static let releaseAllowedHosts: Set<String> = [
        "api.anthropic.com"
    ]
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private let logger = DiagnosticsLogger.shared

    @discardableResult
    func fetchUsage(completion: @escaping (Result<ClaudeUsageResponse, Error>) -> Void) -> URLSessionDataTask? {
        logger.log("Starting usage refresh")

        guard let token = resolveToken() else {
            logger.log("Token resolution failed")
            completion(.failure(AppError.missingCredentials))
            return nil
        }

        logger.log("Resolved token from supported credential source")

        guard let url = usageURL() else {
            completion(.failure(AppError.invalidUsageURL))
            return nil
        }

        guard isAllowedEndpoint(url) else {
            logger.log("Blocked request to non-allowlisted host \(url.host ?? "<unknown>")")
            completion(.failure(AppError.unsupportedEndpoint))
            return nil
        }

        logger.log("Requesting usage from allowlisted host \(url.host ?? "<unknown>")")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeTokenMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                self.logger.log("Network error: \(error.localizedDescription)")
                completion(.failure(AppError.networkFailure(error.localizedDescription)))
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.logger.log("HTTP failure \(http.statusCode)")
                completion(.failure(AppError.httpFailure(status: http.statusCode)))
                return
            }

            guard let data else {
                self.logger.log("Usage API returned no body")
                completion(.failure(AppError.invalidResponse))
                return
            }

            do {
                let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
                self.logger.log("Usage fetch succeeded")
                completion(.success(usage))
            } catch {
                self.logger.log("JSON decode failed: \(error.localizedDescription)")
                completion(.failure(AppError.decodeFailure))
            }
        }
        task.resume()
        return task
    }

    func resetText(from isoString: String?) -> String {
        guard let isoString else {
            return "reset unknown"
        }

        guard let resetDate = isoFormatter.date(from: isoString) ?? fallbackISOFormatter.date(from: isoString) else {
            logger.log("Failed to parse reset timestamp: \(isoString)")
            return "reset unknown"
        }

        let remaining = max(0, Int(resetDate.timeIntervalSinceNow))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    func iconColor(for usedPercent: Int) -> NSColor {
        let remainingPercent = max(0, 100 - usedPercent)
        if remainingPercent <= 10 {
            return NSColor.systemRed
        }
        if remainingPercent <= 20 {
            return NSColor.systemYellow
        }
        return NSColor.systemOrange
    }

    private func resolveToken() -> OAuthTokens? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            logger.log("Using CLAUDE_CODE_OAUTH_TOKEN from environment")
            return OAuthTokens(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                scopes: ["user:inference"],
                subscriptionType: nil,
                rateLimitTier: nil
            )
        }

        if let oauth = readKeychainStorage() {
            logger.log("Using Claude OAuth token from Keychain service \(keychainServiceName())")
            return oauth
        }

        logger.log("No token found in environment or supported Keychain storage")
        return nil
    }

    private func readKeychainStorage() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainUsername(),
            kSecAttrService as String: keychainServiceName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            logger.log("Keychain item not found for service \(keychainServiceName())")
            return nil
        }

        guard status == errSecSuccess else {
            logger.log("Keychain lookup failed for service \(keychainServiceName()) with status \(status)")
            return nil
        }

        guard let data = item as? Data, !data.isEmpty else {
            logger.log("Keychain lookup returned empty data for service \(keychainServiceName())")
            return nil
        }
        return parseOAuthTokens(from: data, sourceLabel: "Keychain")
    }

    private func keychainUsername() -> String {
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty {
            return user
        }
        return NSUserName()
    }

    private func keychainServiceName() -> String {
        "Claude Code-credentials"
    }

    private func usageURL() -> URL? {
        URL(string: "https://api.anthropic.com/api/oauth/usage")
    }

    private func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            return false
        }
        return Self.releaseAllowedHosts.contains(host)
    }

    private func parseOAuthTokens(from data: Data, sourceLabel: String) -> OAuthTokens? {
        do {
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let root = raw,
                  let oauth = root["claudeAiOauth"] as? [String: Any] else {
                logger.log("Credential payload missing claudeAiOauth in \(sourceLabel)")
                return nil
            }

            guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
                logger.log("Credential payload missing accessToken in \(sourceLabel)")
                return nil
            }

            let refreshToken = oauth["refreshToken"] as? String
            let expiresAtString = oauth["expiresAt"] as? String
            let expiresAtNumber = oauth["expiresAt"].map { String(describing: $0) }
            let expiresAt = expiresAtString ?? expiresAtNumber
            let scopes = oauth["scopes"] as? [String]
            let subscriptionType = oauth["subscriptionType"] as? String
            let rateLimitTier = oauth["rateLimitTier"] as? String

            logger.log("Parsed credentials from \(sourceLabel)")

            return OAuthTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: scopes,
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier
            )
        } catch {
            logger.log("Failed parsing credentials from \(sourceLabel): \(error.localizedDescription)")
            return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: PassThroughStatusView!
    private let usageService = UsageService()
    private let logger = DiagnosticsLogger.shared
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var refreshTask: URLSessionDataTask?
    private var refreshGeneration = 0
    private var lastUsedPercent: Int?
    private var lastResetAt: String?
    private let menu = NSMenu()
    private var sessionItem = NSMenuItem(title: "Current session: loading…", action: nil, keyEquivalent: "")
    private var weeklyItem = NSMenuItem(title: "Weekly: loading…", action: nil, keyEquivalent: "")
    private var sonnetItem = NSMenuItem(title: "Weekly Sonnet: loading…", action: nil, keyEquivalent: "")
    private var extraUsageItem = NSMenuItem(title: "Extra usage: loading…", action: nil, keyEquivalent: "")
    private var errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var logPathItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("Application launched")
        setupStatusItem()
        setupMenu()
        fetchUsage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshCountdownOnly()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
        refreshTask?.cancel()
    }

    private func setupStatusItem() {
        let icon = Bundle.main.image(forResource: "clawd")
        statusView = PassThroughStatusView(icon: icon)
        statusItem = NSStatusBar.system.statusItem(withLength: statusView.intrinsicContentSize.width)
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        statusView.frame = NSRect(origin: .zero, size: statusView.intrinsicContentSize)
        statusView.onSizeChange = { [weak self] in
            self?.updateStatusItemWidth()
        }
        button.frame.size.width = statusView.intrinsicContentSize.width
        button.addSubview(statusView)
        updateStatusItemWidth()
    }

    private func updateStatusItemWidth() {
        let width = max(1, ceil(statusView.fittingSize.width))
        statusItem.length = width
        statusItem.button?.frame.size.width = width
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: 22)
    }

    private func setupMenu() {
        errorItem.isHidden = true
        logPathItem.title = "Log: \(logger.logURL.lastPathComponent)"
        menu.addItem(sessionItem)
        menu.addItem(weeklyItem)
        menu.addItem(sonnetItem)
        menu.addItem(extraUsageItem)
        menu.addItem(errorItem)
        menu.addItem(logPathItem)
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

        statusItem.menu = menu
    }

    @objc private func refreshNow() {
        logger.log("Manual refresh triggered")
        fetchUsage()
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(logger.logURL)
    }

    @objc private func quitApp() {
        logger.log("Application quitting")
        NSApp.terminate(nil)
    }

    private func fetchUsage() {
        if refreshTask != nil {
            logger.log("Refresh skipped because a request is already in flight")
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        statusView.state = .loading
        statusView.toolTip = "Claude Token Meter: loading"
        refreshTask = usageService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.refreshGeneration else {
                    self.logger.log("Ignoring stale refresh response \(generation)")
                    return
                }
                self.refreshTask = nil
                self.handle(result: result)
            }
        }
    }

    private func handle(result: Result<ClaudeUsageResponse, Error>) {
        switch result {
        case .success(let usage):
            let currentLimit = usage.five_hour
            let used = clampPercent(currentLimit?.utilization)
            lastUsedPercent = used
            lastResetAt = currentLimit?.resets_at
            let resetText = usageService.resetText(from: lastResetAt)
            let iconColor = usageService.iconColor(for: used)
            statusView.state = .loaded(usedPercent: used, resetText: resetText, iconColor: iconColor)
            statusView.toolTip = "Claude usage \(used)% used, reset \(resetText)"
            logger.log("UI updated with success state, used=\(used)% reset=\(resetText)")

            sessionItem.title = "Current session: \(used)% used"
            weeklyItem.title = "Weekly used: \(usedString(for: usage.seven_day))"
            sonnetItem.title = "Weekly Sonnet used: \(usedString(for: usage.seven_day_sonnet))"
            extraUsageItem.title = extraUsageString(usage.extra_usage)
            errorItem.isHidden = true

        case .failure(let error):
            lastUsedPercent = nil
            lastResetAt = nil
            statusView.state = .error(error.localizedDescription)
            statusView.toolTip = error.localizedDescription
            logger.log("UI updated with error state: \(error.localizedDescription)")
            sessionItem.title = "Current session: unavailable"
            weeklyItem.title = "Weekly: unavailable"
            sonnetItem.title = "Weekly Sonnet: unavailable"
            extraUsageItem.title = "Extra usage: unavailable"
            errorItem.title = error.localizedDescription
            errorItem.isHidden = false
        }
    }

    private func refreshCountdownOnly() {
        guard let used = lastUsedPercent, let resetAt = lastResetAt else {
            return
        }

        let resetText = usageService.resetText(from: resetAt)
        let iconColor = usageService.iconColor(for: used)
        statusView.state = .loaded(usedPercent: used, resetText: resetText, iconColor: iconColor)
        statusView.toolTip = "Claude usage \(used)% used, reset \(resetText)"
        logger.log("Countdown display updated locally, used=\(used)% reset=\(resetText)")
    }

    private func usedString(for limit: ClaudeUsageResponse.RateLimit?) -> String {
        guard let utilization = limit?.utilization else {
            return "unknown"
        }
        let used = clampPercent(utilization)
        let reset = usageService.resetText(from: limit?.resets_at)
        return "\(used)% (\(reset))"
    }

    private func extraUsageString(_ extra: ClaudeUsageResponse.ExtraUsage?) -> String {
        guard let extra else {
            return "Extra usage: not available"
        }

        let enabled = extra.is_enabled ? "enabled" : "disabled"
        let usedDollars = extra.used_credits.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "unknown"
        let limitDollars = extra.monthly_limit.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "unknown"
        let utilization = extra.utilization.map { "\(clampPercent($0))%" } ?? "unknown"
        return "Extra usage: \(enabled), \(usedDollars) / \(limitDollars), \(utilization)"
    }

    private func clampPercent(_ value: Double?) -> Int {
        guard let value else { return 0 }
        return max(0, min(100, Int(round(value))))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
