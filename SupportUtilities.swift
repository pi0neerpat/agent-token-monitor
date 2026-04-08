import Darwin
import Foundation

enum UsageFormatter {
    static func countdownText(to date: Date?) -> String {
        guard let date else {
            return "reset unknown"
        }

        let remaining = max(0, Int(date.timeIntervalSinceNow))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func planDisplayName(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum BinaryLocator {
    static func resolveCodexBinary(environment: [String: String]) -> String? {
        let candidates: [String?] = [
            environment["CODEX_CLI_PATH"],
            environment["CODEX_BINARY"],
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Application Support/codex/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            TTYWhich.which("codex")
        ]

        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

enum TTYWhich {
    static func which(_ binary: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let resolved = "\(component)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }
}

enum ShellEscaping {
    static func escape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AppError.commandFailed(error.localizedDescription)
        }

        do {
            try await withTimeout(seconds: timeout) {
                await Task.detached(priority: .utility) {
                    process.waitUntilExit()
                }.value
            }
        } catch is TimeoutError {
            if process.isRunning {
                process.terminate()
            }
            throw AppError.timedOut("Command timed out.")
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: stdout, encoding: .utf8) ?? "")
            + "\n"
            + (String(data: stderr, encoding: .utf8) ?? "")
        return combined
    }
}

enum PTYRunner {
    static func runInteractive(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        scriptedInput: [String],
        initialDelay: TimeInterval = 0.5,
        interCommandDelay: TimeInterval = 1.5
    ) async throws -> String {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &windowSize) == 0 else {
            throw AppError.commandFailed("Failed to allocate PTY: \(posixErrorDescription(errno))")
        }

        let process = Process()
        let stdinHandle = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinHandle
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let readerTask = Task.detached(priority: .utility) { () throws -> Data in
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let count = Darwin.read(masterFD, &buffer, buffer.count)
                if count > 0 {
                    output.append(buffer, count: count)
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EIO || errno == EBADF {
                    break
                }
                throw AppError.commandFailed("PTY read failed: \(posixErrorDescription(errno))")
            }

            return output
        }

        do {
            try process.run()
        } catch {
            stdinHandle.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            Darwin.close(masterFD)
            throw AppError.commandFailed(error.localizedDescription)
        }

        // The child inherited the slave side at spawn time. Close the parent's
        // copies so the master sees EOF once the child exits.
        stdinHandle.closeFile()
        stdoutHandle.closeFile()
        stderrHandle.closeFile()

        let writerTask = Task.detached(priority: .utility) {
            if initialDelay > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds(initialDelay))
            }

            for (index, line) in scriptedInput.enumerated() {
                guard !Task.isCancelled else { return }
                let data = Data((line + "\n").utf8)
                data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < data.count {
                        let written = Darwin.write(masterFD, baseAddress.advanced(by: offset), data.count - offset)
                        if written <= 0 {
                            return
                        }
                        offset += written
                    }
                }

                if index < scriptedInput.count - 1, interCommandDelay > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds(interCommandDelay))
                }
            }
        }

        do {
            try await withTimeout(seconds: timeout) {
                await Task.detached(priority: .utility) {
                    process.waitUntilExit()
                }.value
            }
        } catch is TimeoutError {
            writerTask.cancel()
            if process.isRunning {
                process.terminate()
            }
            Darwin.close(masterFD)
            throw AppError.timedOut("Command timed out.")
        }

        writerTask.cancel()
        let output = try await readerTask.value
        Darwin.close(masterFD)
        return String(data: output, encoding: .utf8) ?? ""
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        if let posixCode = POSIXErrorCode(rawValue: code) {
            return POSIXError(posixCode).localizedDescription
        }
        return String(cString: strerror(code))
    }
}

enum TextParsing {
    static func stripANSICodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
    }

    static func firstNumber(pattern: String, text: String) -> Double? {
        guard let match = firstMatch(pattern: pattern, text: text), match.count >= 2 else {
            return nil
        }
        let normalized = match[1].replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    static func firstMatch(pattern: String, text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var results: [String] = []
        for index in 0 ..< match.numberOfRanges {
            let nsRange = match.range(at: index)
            if let swiftRange = Range(nsRange, in: text) {
                results.append(String(text[swiftRange]))
            } else {
                results.append("")
            }
        }
        return results
    }

    static func percentLeft(fromLine line: String) -> Int? {
        guard let match = firstMatch(pattern: #"([0-9]{1,3})%\s*left"#, text: line), match.count >= 2 else {
            return nil
        }
        return Int(match[1])
    }

    static func resetString(fromLine line: String) -> String? {
        guard let match = firstMatch(pattern: #"\((?:resets?\s*)?([^)]+)\)"#, text: line), match.count >= 2 else {
            return nil
        }
        return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TimeoutError: Error {
    case timedOut
}

func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
