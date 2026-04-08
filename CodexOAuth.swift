import Foundation

struct CodexOAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?
    let lastRefresh: Date?
}

enum CodexOAuthCredentialsError: LocalizedError {
    case notFound(String)
    case authorizationRequired(String)
    case decodeFailed(String)
    case missingTokens

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Codex auth.json was not found at \(path). Run `codex` to log in."
        case .authorizationRequired(let message):
            return message
        case .decodeFailed(let message):
            return "Failed to decode Codex credentials: \(message)"
        case .missingTokens:
            return "Codex auth.json exists but contains no tokens."
        }
    }
}

enum CodexOAuthCredentialsStore {
    static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexOAuthCredentials {
        if CodexAuthAccess.hasAuthorizedFile() {
            return try CodexAuthAccess.withAuthorizedFile { url in
                let data = try Data(contentsOf: url)
                return try parse(data: data)
            }
        }

        let url = authFileURL(env: env)
        do {
            let data = try Data(contentsOf: url)
            return try parse(data: data)
        } catch let error as CodexOAuthCredentialsError {
            throw error
        } catch let error as CodexAuthAccessError {
            throw CodexOAuthCredentialsError.authorizationRequired(error.localizedDescription)
        } catch {
            throw mapReadError(error, url: url)
        }
    }

    static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexOAuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil
            )
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken"),
              let refreshToken = stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken"),
              !accessToken.isEmpty else {
            throw CodexOAuthCredentialsError.missingTokens
        }

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
            accountId: stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            lastRefresh: parseLastRefresh(from: json["last_refresh"])
        )
    }

    private static func authFileURL(env: [String: String]) -> URL {
        CodexAuthAccess.defaultAuthFileURL(env: env)
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(in dictionary: [String: Any], snakeCaseKey: String, camelCaseKey: String) -> String? {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    private static func mapReadError(_ error: Error, url: URL) -> CodexOAuthCredentialsError {
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return .notFound(url.path)
        }

        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
            || (nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))) {
            return .authorizationRequired(
                "Codex auth.json exists but this sandboxed app cannot read it yet. Use “Enable Codex…” in the Codex menu and choose \(url.path)."
            )
        }

        return .decodeFailed(nsError.localizedDescription)
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    let planType: PlanType?
    let rateLimit: RateLimitDetails?
    let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    enum PlanType: Sendable, Decodable {
        case guest
        case free
        case go
        case plus
        case pro
        case freeWorkspace
        case team
        case business
        case education
        case quorum
        case k12
        case enterprise
        case edu
        case unknown(String)

        var rawValue: String {
            switch self {
            case .guest: return "guest"
            case .free: return "free"
            case .go: return "go"
            case .plus: return "plus"
            case .pro: return "pro"
            case .freeWorkspace: return "free_workspace"
            case .team: return "team"
            case .business: return "business"
            case .education: return "education"
            case .quorum: return "quorum"
            case .k12: return "k12"
            case .enterprise: return "enterprise"
            case .edu: return "edu"
            case .unknown(let value): return value
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "guest": self = .guest
            case "free": self = .free
            case "go": self = .go
            case "plus": self = .plus
            case "pro": self = .pro
            case "free_workspace": self = .freeWorkspace
            case "team": self = .team
            case "business": self = .business
            case "education": self = .education
            case "quorum": self = .quorum
            case "k12": self = .k12
            case "enterprise": self = .enterprise
            case "edu": self = .edu
            default: self = .unknown(value)
            }
        }
    }

    struct RateLimitDetails: Decodable, Sendable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct WindowSnapshot: Decodable, Sendable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct CreditDetails: Decodable, Sendable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
            self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
            if let value = try? container.decode(Double.self, forKey: .balance) {
                self.balance = value
            } else if let stringValue = try? container.decode(String.self, forKey: .balance),
                      let value = Double(stringValue) {
                self.balance = value
            } else {
                self.balance = nil
            }
        }
    }
}

enum CodexOAuthFetchError: LocalizedError {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex OAuth token expired or invalid."
        case .invalidResponse:
            return "Invalid response from Codex usage API."
        case .serverError(let code, let message):
            if let message, !message.isEmpty {
                return "Codex API error \(code): \(message)"
            }
            return "Codex API error \(code)."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

enum CodexOAuthUsageFetcher {
    static func fetchUsage(
        accessToken: String,
        accountId: String?,
        session: URLSession = .shared
    ) async throws -> CodexUsageResponse {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexOAuthFetchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeTokenMeter", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexOAuthFetchError.invalidResponse
            }

            switch http.statusCode {
            case 200 ... 299:
                do {
                    return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
                } catch {
                    throw CodexOAuthFetchError.invalidResponse
                }
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(http.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch {
            throw CodexOAuthFetchError.networkError(error)
        }
    }
}
