import Foundation

struct CodexStatusSnapshot: Sendable {
    let credits: Double?
    let fiveHourPercentLeft: Int?
    let weeklyPercentLeft: Int?
    let fiveHourResetDescription: String?
    let weeklyResetDescription: String?
    let fiveHourResetsAt: Date?
    let weeklyResetsAt: Date?
    let rawText: String
}

enum CodexStatusProbeError: LocalizedError {
    case codexNotInstalled
    case parseFailed(String)
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            return "Codex CLI missing."
        case .parseFailed(let message):
            return "Could not parse Codex status: \(message)"
        case .timedOut:
            return "Codex status probe timed out."
        case .commandFailed(let message):
            return message
        }
    }
}

struct CodexStatusProbe {
    let timeout: TimeInterval
    let environment: [String: String]

    init(timeout: TimeInterval = 8.0, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.timeout = timeout
        self.environment = environment
    }

    func fetch() async throws -> CodexStatusSnapshot {
        guard let binary = BinaryLocator.resolveCodexBinary(environment: environment) else {
            throw CodexStatusProbeError.codexNotInstalled
        }

        let probeEnvironment = statusEnvironment()
        let text = try await PTYRunner.runInteractive(
            executable: binary,
            arguments: ["-s", "read-only", "-a", "untrusted"],
            environment: probeEnvironment,
            timeout: timeout,
            scriptedInput: ["/status", "/quit"]
        )
        if let message = Self.detectFailure(in: text) {
            throw CodexStatusProbeError.commandFailed(message)
        }
        return try Self.parse(text: text)
    }

    static func parse(text: String, now: Date = Date()) throws -> CodexStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexStatusProbeError.timedOut
        }

        let credits = TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: clean)
        let fiveLine = TextParsing.firstLine(matching: #"5h limit[^\n]*"#, text: clean)
        let weekLine = TextParsing.firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)
        let fivePct = fiveLine.flatMap(TextParsing.percentLeft(fromLine:))
        let weekPct = weekLine.flatMap(TextParsing.percentLeft(fromLine:))
        let fiveReset = fiveLine.flatMap(TextParsing.resetString(fromLine:))
        let weekReset = weekLine.flatMap(TextParsing.resetString(fromLine:))

        if credits == nil, fivePct == nil, weekPct == nil {
            throw CodexStatusProbeError.parseFailed(String(clean.prefix(300)))
        }

        return CodexStatusSnapshot(
            credits: credits,
            fiveHourPercentLeft: fivePct,
            weeklyPercentLeft: weekPct,
            fiveHourResetDescription: fiveReset,
            weeklyResetDescription: weekReset,
            fiveHourResetsAt: parseResetDate(from: fiveReset, now: now),
            weeklyResetsAt: parseResetDate(from: weekReset, now: now),
            rawText: clean
        )
    }

    private static func parseResetDate(from text: String?, now: Date) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        if let match = TextParsing.firstMatch(pattern: #"^([0-9]{1,2}:[0-9]{2}) on ([0-9]{1,2} [A-Za-z]{3})$"#, text: raw),
           match.count == 3 {
            formatter.dateFormat = "d MMM HH:mm"
            if let date = formatter.date(from: "\(match[2]) \(match[1])") {
                return bumpYearIfNeeded(date, now: now, calendar: calendar)
            }
        }

        if let match = TextParsing.firstMatch(pattern: #"^([0-9]{1,2}:[0-9]{2}) on ([A-Za-z]{3} [0-9]{1,2})$"#, text: raw),
           match.count == 3 {
            formatter.dateFormat = "MMM d HH:mm"
            if let date = formatter.date(from: "\(match[2]) \(match[1])") {
                return bumpYearIfNeeded(date, now: now, calendar: calendar)
            }
        }

        for format in ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                guard let anchored = calendar.date(
                    bySettingHour: parts.hour ?? 0,
                    minute: parts.minute ?? 0,
                    second: 0,
                    of: now
                ) else {
                    return nil
                }
                if anchored >= now {
                    return anchored
                }
                return calendar.date(byAdding: .day, value: 1, to: anchored)
            }
        }

        return nil
    }

    private static func bumpYearIfNeeded(_ date: Date, now: Date, calendar: Calendar) -> Date? {
        if date >= now {
            return date
        }
        return calendar.date(byAdding: .year, value: 1, to: date)
    }

    private func statusEnvironment() -> [String: String] {
        var merged = environment
        if UsageFormatter.normalized(merged["TERM"]) == nil || merged["TERM"] == "dumb" {
            merged["TERM"] = "xterm-256color"
        }
        if UsageFormatter.normalized(merged["COLORTERM"]) == nil {
            merged["COLORTERM"] = "truecolor"
        }
        return merged
    }

    private static func detectFailure(in text: String) -> String? {
        let clean = TextParsing.stripANSICodes(text).lowercased()
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "/status\n/quit" || trimmed == "/status\r\n/quit" {
            return "Codex CLI /status produced no readable output."
        }
        if clean.contains("term is set to \"dumb\"") || clean.contains("refusing to start the interactive tui") {
            return "Codex CLI /status requires an interactive terminal."
        }
        if clean.contains("stdin is not a terminal") {
            return "Codex CLI /status did not receive a PTY-backed stdin."
        }
        if clean.contains("authentication required")
            || clean.contains("not authenticated")
            || clean.contains("run `codex login`")
            || clean.contains("run codex login")
            || clean.contains("please login")
            || clean.contains("log in") {
            return "Codex CLI authentication required for /status."
        }
        return nil
    }
}
