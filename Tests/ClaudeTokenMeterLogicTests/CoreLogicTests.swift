import XCTest

@testable import ClaudeTokenMeterLogic

final class CoreLogicTests: XCTestCase {
    func testUsageFormatterCountdownNil() {
        XCTAssertEqual(UsageFormatter.countdownText(to: nil), "reset unknown")
    }

    func testUsageFormatterNormalized() {
        XCTAssertNil(UsageFormatter.normalized(nil))
        XCTAssertNil(UsageFormatter.normalized(""))
        XCTAssertNil(UsageFormatter.normalized("   "))
        XCTAssertEqual(UsageFormatter.normalized("  pro  "), "pro")
    }

    func testUsageFormatterPlanDisplayName() {
        XCTAssertNil(UsageFormatter.planDisplayName(nil))
        XCTAssertEqual(UsageFormatter.planDisplayName("max_plan"), "Max Plan")
    }

    func testShellEscaping() {
        XCTAssertEqual(ShellEscaping.escape("hello"), "'hello'")
        XCTAssertEqual(ShellEscaping.escape("it's"), "'it'\"'\"'s'")
    }

    func testTextParsingStripANSI() {
        let raw = "\u{001B}[1;32mOK\u{001B}[0m plain"
        XCTAssertEqual(TextParsing.stripANSICodes(raw), "OK plain")
    }

    func testTextParsingPercentAndReset() {
        let line = "5h limit 82% left (resets at 18:00)"
        XCTAssertEqual(TextParsing.percentLeft(fromLine: line), 82)
        // Parenthetical capture drops the optional "resets"/"reset" prefix.
        XCTAssertEqual(TextParsing.resetString(fromLine: line), "at 18:00")
    }

    func testTextParsingFirstNumber() {
        XCTAssertEqual(TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: "Credits: 1,234.5"), 1234.5)
        XCTAssertNil(TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: "no credits here"))
    }

    func testTTYWhichFindsShOnPath() {
        let shPath = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shPath) else {
            XCTFail("expected \(shPath) on macOS")
            return
        }
        XCTAssertEqual(TTYWhich.which("sh"), shPath)
    }

    func testProviderIDDisplayNames() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertTrue(ProviderID.claude.statusToolTipPrefix.contains("Claude"))
    }

    func testAppErrorDescriptions() {
        XCTAssertTrue(AppError.missingCredentials.errorDescription?.contains("credentials") ?? false)
        XCTAssertTrue(AppError.httpFailure(status: 404).errorDescription?.contains("404") ?? false)
        XCTAssertTrue(AppError.httpFailure(status: 401).errorDescription?.contains("Authorization") ?? false)
    }

    func testProviderFetchErrorDescription() {
        let err = ProviderFetchError.allSourcesFailed(provider: .claude, messages: ["a", "b"])
        XCTAssertTrue(err.errorDescription?.contains("Claude") ?? false)
        XCTAssertTrue(err.errorDescription?.contains("a | b") ?? false)
    }

    func testCodexStatusProbeParseExtractsCreditsAndPercents() throws {
        let text = """
        Welcome
        Credits: 42.5
        5h limit 75% left (resets at 18:00)
        Weekly limit 60% left (resets in 2d)
        """
        let snap = try CodexStatusProbe.parse(text: text, now: Date())
        XCTAssertEqual(snap.credits, 42.5)
        XCTAssertEqual(snap.fiveHourPercentLeft, 75)
        XCTAssertEqual(snap.weeklyPercentLeft, 60)
        XCTAssertFalse(snap.rawText.isEmpty)
    }

    func testCodexStatusProbeParseEmptyThrows() {
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: "", now: Date())) { error in
            guard let probeError = error as? CodexStatusProbeError else {
                XCTFail("expected CodexStatusProbeError, got \(error)")
                return
            }
            if case .timedOut = probeError { return }
            XCTFail("expected timedOut, got \(probeError)")
        }
    }

    func testCodexStatusProbeParseMissingSignalsThrows() {
        let text = "nothing useful in this blob"
        XCTAssertThrowsError(try CodexStatusProbe.parse(text: text, now: Date())) { error in
            XCTAssertTrue(error is CodexStatusProbeError)
        }
    }
}
