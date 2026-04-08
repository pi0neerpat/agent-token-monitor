import Cocoa
import Foundation
import Security

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

final class ClaudeUsageService {
    private static let releaseAllowedHosts: Set<String> = ["api.anthropic.com"]

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
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    @discardableResult
    func fetchUsage(completion: @escaping (Result<ClaudeUsageResponse, Error>) -> Void) -> URLSessionDataTask? {
        logger.log("Starting Claude usage refresh")

        guard let token = resolveToken() else {
            logger.log("Claude token resolution failed")
            completion(.failure(AppError.missingCredentials))
            return nil
        }

        guard let url = usageURL() else {
            completion(.failure(AppError.invalidUsageURL))
            return nil
        }

        guard isAllowedEndpoint(url) else {
            logger.log("Blocked request to non-allowlisted host \(url.host ?? "<unknown>")")
            completion(.failure(AppError.unsupportedEndpoint))
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeTokenMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                self.logger.log("Claude network error: \(error.localizedDescription)")
                completion(.failure(AppError.networkFailure(error.localizedDescription)))
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.logger.log("Claude HTTP failure \(http.statusCode)")
                completion(.failure(AppError.httpFailure(status: http.statusCode)))
                return
            }

            guard let data else {
                self.logger.log("Claude usage API returned no body")
                completion(.failure(AppError.invalidResponse))
                return
            }

            do {
                let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
                self.logger.log("Claude usage fetch succeeded")
                completion(.success(usage))
            } catch {
                self.logger.log("Claude JSON decode failed: \(error.localizedDescription)")
                completion(.failure(AppError.decodeFailure))
            }
        }
        task.resume()
        return task
    }

    func fetchUsage() async throws -> ClaudeUsageResponse {
        try await withCheckedThrowingContinuation { continuation in
            _ = fetchUsage { result in
                continuation.resume(with: result)
            }
        }
    }

    func resolveTokenForMetadata() -> OAuthTokens? {
        resolveToken()
    }

    func parseDate(from isoString: String?) -> Date? {
        guard let isoString else { return nil }
        return isoFormatter.date(from: isoString) ?? fallbackISOFormatter.date(from: isoString)
    }

    func countdownText(from isoString: String?) -> String {
        countdownText(to: parseDate(from: isoString))
    }

    func countdownText(to date: Date?) -> String {
        UsageFormatter.countdownText(to: date)
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

    func clampPercent(_ value: Double?) -> Int {
        guard let value else { return 0 }
        return max(0, min(100, Int(round(value))))
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

        logger.log("No Claude token found in environment or supported Keychain storage")
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
            guard let root = raw, let oauth = root["claudeAiOauth"] as? [String: Any] else {
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
