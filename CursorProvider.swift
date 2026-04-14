import Foundation
import Security

struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: PlanUsage?
    let spendLimitUsage: SpendLimitUsage?
    let enabled: Bool?
    let displayMessage: String?

    struct PlanUsage: Decodable {
        let totalSpend: Int?
        let includedSpend: Int?
        let bonusSpend: Int?
        let remaining: Int?
        let limit: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct SpendLimitUsage: Decodable {
        let totalSpend: Int?
        let individualUsed: Int?
        let individualRemaining: Int?
        let individualLimit: Int?
        let limitType: String?
    }
}

struct CursorPlanResponse: Decodable {
    let planInfo: PlanInfo?

    struct PlanInfo: Decodable {
        let planName: String?
        let includedAmountCents: Int?
        let price: String?
        let billingCycleEnd: String?
    }
}

struct CursorCreditGrantsResponse: Decodable {
    let hasCreditGrants: Bool?
    let creditBalanceCents: String?
    let totalCents: String?
    let usedCents: String?
}

final class CursorUsageService {
    private static let apiBase = "https://api2.cursor.sh"
    private static let releaseAllowedHosts: Set<String> = ["api2.cursor.sh"]

    private let logger = DiagnosticsLogger.shared
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func fetchUsage() async throws -> CursorUsageResponse {
        try await rpcCall(
            method: "aiserver.v1.DashboardService/GetCurrentPeriodUsage",
            as: CursorUsageResponse.self
        )
    }

    func fetchPlan() async throws -> CursorPlanResponse {
        try await rpcCall(
            method: "aiserver.v1.DashboardService/GetPlanInfo",
            as: CursorPlanResponse.self
        )
    }

    func fetchCreditGrants() async throws -> CursorCreditGrantsResponse {
        try await rpcCall(
            method: "aiserver.v1.DashboardService/GetCreditGrantsBalance",
            as: CursorCreditGrantsResponse.self
        )
    }

    func resolveAccountEmail() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/cli-config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authInfo = json["authInfo"] as? [String: Any],
              let email = authInfo["email"] as? String else {
            return nil
        }
        return UsageFormatter.normalized(email)
    }

    private func rpcCall<T: Decodable>(method: String, as type: T.Type) async throws -> T {
        guard let token = resolveAccessToken() else {
            throw AppError.missingCredentials
        }

        let urlString = "\(Self.apiBase)/\(method)"
        guard let url = URL(string: urlString) else {
            throw AppError.invalidUsageURL
        }

        guard isAllowedEndpoint(url) else {
            logger.log("Blocked Cursor request to non-allowlisted host \(url.host ?? "<unknown>")")
            throw AppError.unsupportedEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentTokenMonitor/1.0", forHTTPHeaderField: "x-cursor-client-type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            logger.log("Cursor HTTP failure \(http.statusCode) for \(method)")
            throw AppError.httpFailure(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.log("Cursor JSON decode failed for \(method): \(error.localizedDescription)")
            throw AppError.decodeFailure
        }
    }

    private func resolveAccessToken() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["CURSOR_API_KEY"], !envToken.isEmpty {
            logger.log("Using CURSOR_API_KEY from environment")
            return envToken
        }

        if let keychainToken = readKeychainToken() {
            logger.log("Using Cursor access token from Keychain")
            return keychainToken
        }

        logger.log("No Cursor token found in environment or Keychain")
        return nil
    }

    private func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-access-token",
            kSecAttrAccount as String: "cursor-user",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            if status == errSecItemNotFound {
                logger.log("Cursor keychain item not found")
            } else if status != errSecSuccess {
                logger.log("Cursor keychain lookup failed with status \(status)")
            }
            return nil
        }

        return token
    }

    private func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            return false
        }
        return Self.releaseAllowedHosts.contains(host)
    }
}
