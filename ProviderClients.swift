import Foundation

protocol ProviderClient {
    var providerID: ProviderID { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
}

struct ClaudeProviderClient: ProviderClient {
    let providerID: ProviderID = .claude
    private let service = ClaudeUsageService()

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let usage = try await service.fetchUsage()
        let token = service.resolveTokenForMetadata()

        return ProviderSnapshot(
            primary: makeWindow(from: usage.five_hour),
            secondary: makeWindow(from: usage.seven_day),
            updatedAt: Date(),
            plan: UsageFormatter.planDisplayName(token?.subscriptionType ?? token?.rateLimitTier),
            credits: makeCredits(from: usage.extra_usage),
            sourceLabel: "anthropic-api",
            accountEmail: nil
        )
    }

    private func makeWindow(from limit: ClaudeUsageResponse.RateLimit?) -> ProviderWindowSnapshot? {
        guard let limit else { return nil }
        return ProviderWindowSnapshot(
            usedPercent: service.clampPercent(limit.utilization),
            windowMinutes: nil,
            resetsAt: service.parseDate(from: limit.resets_at),
            resetDescription: service.countdownText(from: limit.resets_at)
        )
    }

    private func makeCredits(from extra: ClaudeUsageResponse.ExtraUsage?) -> ProviderCreditsSnapshot? {
        guard let extra else { return nil }
        guard extra.is_enabled else { return nil }
        let used = extra.used_credits.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "unknown"
        let limit = extra.monthly_limit.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "unknown"
        let utilization = extra.utilization.map { "\(service.clampPercent($0))%" } ?? "unknown"
        return ProviderCreditsSnapshot(
            text: "\(used) / \(limit), \(utilization)",
            remainingBalance: nil
        )
    }
}

struct CodexProviderClient: ProviderClient {
    let providerID: ProviderID = .codex
    private let logger = DiagnosticsLogger.shared
    private let environment = ProcessInfo.processInfo.environment

    func fetchSnapshot() async throws -> ProviderSnapshot {
        var failures: [String] = []

        do {
            let snapshot = try await fetchFromOAuth()
            logger.log("Codex snapshot loaded from oauth")
            return snapshot
        } catch {
            let message = "oauth: \(error.localizedDescription)"
            logger.log("Codex OAuth failed: \(error.localizedDescription)")
            failures.append(message)
        }

        do {
            let snapshot = try await fetchFromRPC()
            logger.log("Codex snapshot loaded from cli rpc")
            return snapshot
        } catch {
            let message = "rpc: \(error.localizedDescription)"
            logger.log("Codex RPC failed: \(error.localizedDescription)")
            failures.append(message)
        }

        do {
            let snapshot = try await fetchFromStatus()
            logger.log("Codex snapshot loaded from cli status")
            return snapshot
        } catch {
            let message = "status: \(error.localizedDescription)"
            logger.log("Codex status fallback failed: \(error.localizedDescription)")
            failures.append(message)
        }

        throw ProviderFetchError.allSourcesFailed(provider: .codex, messages: failures)
    }

    private func fetchFromOAuth() async throws -> ProviderSnapshot {
        let credentials = try CodexOAuthCredentialsStore.load(env: environment)
        let usage = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId
        )

        let normalized = normalizeCodexWindows(
            primary: makeOAuthWindow(usage.rateLimit?.primaryWindow),
            secondary: makeOAuthWindow(usage.rateLimit?.secondaryWindow)
        )

        guard normalized.primary != nil || normalized.secondary != nil else {
            throw AppError.noRateLimitsFound("Codex OAuth returned no rate-limit windows.")
        }

        return ProviderSnapshot(
            primary: normalized.primary,
            secondary: normalized.secondary,
            updatedAt: Date(),
            plan: UsageFormatter.planDisplayName(resolvePlan(from: usage, credentials: credentials)),
            credits: makeOAuthCredits(usage.credits),
            sourceLabel: "oauth",
            accountEmail: resolveEmail(from: credentials)
        )
    }

    private func fetchFromRPC() async throws -> ProviderSnapshot {
        let rpc = try CodexRPCClient(environment: environment)
        defer { rpc.shutdown() }

        try await rpc.initialize(clientName: "agent-token-monitor", clientVersion: "1.1.0")
        let limits = try await rpc.fetchRateLimits().rateLimits
        let account = try? await rpc.fetchAccount()
        let normalized = normalizeCodexWindows(
            primary: makeRPCWindow(limits.primary),
            secondary: makeRPCWindow(limits.secondary)
        )

        guard normalized.primary != nil || normalized.secondary != nil else {
            throw AppError.noRateLimitsFound("Codex CLI RPC returned no rate-limit windows.")
        }

        let accountDetails = account?.account
        return ProviderSnapshot(
            primary: normalized.primary,
            secondary: normalized.secondary,
            updatedAt: Date(),
            plan: UsageFormatter.planDisplayName(rpcPlan(from: accountDetails)),
            credits: makeRPCCredits(limits.credits),
            sourceLabel: "codex-cli-rpc",
            accountEmail: rpcEmail(from: accountDetails)
        )
    }

    private func fetchFromStatus() async throws -> ProviderSnapshot {
        let status = try await CodexStatusProbe(environment: environment).fetch()
        let normalized = normalizeCodexWindows(
            primary: status.fiveHourPercentLeft.map {
                ProviderWindowSnapshot(
                    usedPercent: max(0, min(100, 100 - $0)),
                    windowMinutes: 300,
                    resetsAt: status.fiveHourResetsAt,
                    resetDescription: status.fiveHourResetDescription
                )
            },
            secondary: status.weeklyPercentLeft.map {
                ProviderWindowSnapshot(
                    usedPercent: max(0, min(100, 100 - $0)),
                    windowMinutes: 10_080,
                    resetsAt: status.weeklyResetsAt,
                    resetDescription: status.weeklyResetDescription
                )
            }
        )

        guard normalized.primary != nil || normalized.secondary != nil else {
            throw AppError.noRateLimitsFound("Codex CLI /status returned no rate-limit windows.")
        }

        return ProviderSnapshot(
            primary: normalized.primary,
            secondary: normalized.secondary,
            updatedAt: Date(),
            plan: nil,
            credits: status.credits.map {
                ProviderCreditsSnapshot(
                    text: String(format: "%.2f remaining", $0),
                    remainingBalance: $0
                )
            },
            sourceLabel: "codex-cli-status",
            accountEmail: nil
        )
    }

    private func makeOAuthWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> ProviderWindowSnapshot? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        return ProviderWindowSnapshot(
            usedPercent: max(0, min(100, window.usedPercent)),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: UsageFormatter.countdownText(to: resetDate)
        )
    }

    private func makeRPCWindow(_ window: RPCRateLimitWindow?) -> ProviderWindowSnapshot? {
        guard let window else { return nil }
        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return ProviderWindowSnapshot(
            usedPercent: max(0, min(100, Int(round(window.usedPercent)))),
            windowMinutes: window.windowDurationMins,
            resetsAt: resetDate,
            resetDescription: UsageFormatter.countdownText(to: resetDate)
        )
    }

    private func makeOAuthCredits(_ credits: CodexUsageResponse.CreditDetails?) -> ProviderCreditsSnapshot? {
        guard let credits else { return nil }
        if credits.unlimited {
            return ProviderCreditsSnapshot(text: "Unlimited", remainingBalance: nil)
        }
        guard let balance = credits.balance else { return nil }
        return ProviderCreditsSnapshot(
            text: String(format: "%.2f remaining", balance),
            remainingBalance: balance
        )
    }

    private func makeRPCCredits(_ credits: RPCCreditsSnapshot?) -> ProviderCreditsSnapshot? {
        guard let credits else { return nil }
        if credits.unlimited {
            return ProviderCreditsSnapshot(text: "Unlimited", remainingBalance: nil)
        }
        guard let balance = credits.balance, let value = Double(balance) else {
            return credits.hasCredits ? ProviderCreditsSnapshot(text: "Available", remainingBalance: nil) : nil
        }
        return ProviderCreditsSnapshot(
            text: String(format: "%.2f remaining", value),
            remainingBalance: value
        )
    }

    private func resolveEmail(from credentials: CodexOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken, let payload = parseJWT(idToken) else {
            return nil
        }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return UsageFormatter.normalized((payload["email"] as? String) ?? (profile?["email"] as? String))
    }

    private func resolvePlan(from usage: CodexUsageResponse, credentials: CodexOAuthCredentials) -> String? {
        if let plan = usage.planType?.rawValue {
            return plan
        }
        guard let idToken = credentials.idToken, let payload = parseJWT(idToken) else {
            return nil
        }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return UsageFormatter.normalized((auth?["chatgpt_plan_type"] as? String) ?? (payload["chatgpt_plan_type"] as? String))
    }

    private func rpcEmail(from account: RPCAccountDetails?) -> String? {
        guard let account else { return nil }
        switch account {
        case .apiKey:
            return nil
        case .chatgpt(let email, _):
            return UsageFormatter.normalized(email)
        }
    }

    private func rpcPlan(from account: RPCAccountDetails?) -> String? {
        guard let account else { return nil }
        switch account {
        case .apiKey:
            return nil
        case .chatgpt(_, let planType):
            return UsageFormatter.normalized(planType)
        }
    }

    private func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func normalizeCodexWindows(
        primary: ProviderWindowSnapshot?,
        secondary: ProviderWindowSnapshot?
    ) -> (primary: ProviderWindowSnapshot?, secondary: ProviderWindowSnapshot?) {
        let windows = [primary, secondary].compactMap { $0 }
        guard !windows.isEmpty else {
            return (nil, nil)
        }

        let sessionCandidates = windows.filter { isSessionWindow($0.windowMinutes) }
        let weeklyCandidates = windows.filter { isWeeklyWindow($0.windowMinutes) }
        let otherCandidates = windows.filter { !isSessionWindow($0.windowMinutes) && !isWeeklyWindow($0.windowMinutes) }

        let normalizedPrimary = sessionCandidates.first ?? otherCandidates.first
        let normalizedSecondary = weeklyCandidates.first
            ?? otherCandidates.dropFirst(normalizedPrimary == nil ? 0 : 1).first

        if normalizedPrimary == nil, let weeklyOnly = weeklyCandidates.first {
            return (nil, weeklyOnly)
        }
        return (normalizedPrimary, normalizedSecondary)
    }

    private func isSessionWindow(_ minutes: Int?) -> Bool {
        guard let minutes else { return false }
        return minutes <= 720
    }

    private func isWeeklyWindow(_ minutes: Int?) -> Bool {
        guard let minutes else { return false }
        return minutes >= 10_080
    }
}
