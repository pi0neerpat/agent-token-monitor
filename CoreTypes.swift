import Foundation

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    let logURL: URL
    private let queue = DispatchQueue(label: "AgentTokenMonitor.DiagnosticsLogger")
    private let isoFormatter = ISO8601DateFormatter()

    private init() {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.scribular.agent-token-monitor"
        let baseDir = appSupportDir.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        logURL = baseDir.appendingPathComponent("AgentTokenMonitor.log")
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

enum ProviderID: String {
    case claude
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .cursor:
            return "Cursor"
        }
    }

    var statusToolTipPrefix: String {
        "\(displayName) usage"
    }
}

enum ProviderVisibilityPreferences {
    private static func key(for providerID: ProviderID) -> String {
        "ProviderVisibility.\(providerID.rawValue).enabled"
    }

    static func isEnabled(_ providerID: ProviderID) -> Bool {
        let key = key(for: providerID)
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, for providerID: ProviderID) {
        UserDefaults.standard.set(enabled, forKey: key(for: providerID))
    }
}

struct ProviderWindowSnapshot: Sendable {
    let usedPercent: Int
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
}

struct ProviderCreditsSnapshot: Sendable {
    let text: String
    let remainingBalance: Double?
}

struct ProviderSnapshot: Sendable {
    let primary: ProviderWindowSnapshot?
    let secondary: ProviderWindowSnapshot?
    let updatedAt: Date
    let plan: String?
    let credits: ProviderCreditsSnapshot?
    let sourceLabel: String
    let accountEmail: String?
}

enum ProviderFetchError: LocalizedError {
    case allSourcesFailed(provider: ProviderID, messages: [String])

    var errorDescription: String? {
        switch self {
        case .allSourcesFailed(let provider, let messages):
            let summary = messages.joined(separator: " | ")
            return "\(provider.displayName) unavailable: \(summary)"
        }
    }
}

enum AppError: LocalizedError {
    case missingCredentials
    case unsupportedEndpoint
    case invalidUsageURL
    case invalidResponse
    case networkFailure(String)
    case httpFailure(status: Int)
    case decodeFailure
    case commandUnavailable(String)
    case commandFailed(String)
    case timedOut(String)
    case malformedResponse(String)
    case noRateLimitsFound(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No supported credentials were found."
        case .unsupportedEndpoint:
            return "Release builds only allow requests to approved hosts."
        case .invalidUsageURL:
            return "The usage API URL is invalid."
        case .invalidResponse:
            return "The usage API returned no data."
        case .networkFailure(let message):
            return "Network error: \(message)"
        case .httpFailure(let status):
            if status == 401 || status == 403 {
                return "Authorization failed. Reconnect and try again."
            }
            return "Usage API returned HTTP \(status)."
        case .decodeFailure:
            return "The usage API response could not be parsed."
        case .commandUnavailable(let message):
            return message
        case .commandFailed(let message):
            return message
        case .timedOut(let message):
            return message
        case .malformedResponse(let message):
            return message
        case .noRateLimitsFound(let message):
            return message
        }
    }
}
