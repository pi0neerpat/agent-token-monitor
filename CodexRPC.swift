import Foundation

struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
}

struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct RPCCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RPCAccountResponse: Decodable {
    let account: RPCAccountDetails?
}

enum RPCAccountDetails: Decodable {
    case apiKey
    case chatgpt(email: String?, planType: String?)

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type.lowercased() {
        case "apikey":
            self = .apiKey
        case "chatgpt":
            self = .chatgpt(
                email: try container.decodeIfPresent(String.self, forKey: .email),
                planType: try container.decodeIfPresent(String.self, forKey: .planType)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown account type \(type)")
        }
    }
}

private enum RPCWireError: LocalizedError {
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .startFailed(let message):
            return "Codex CLI RPC failed to start: \(message)"
        case .requestFailed(let message):
            return "Codex CLI RPC failed: \(message)"
        case .malformed(let message):
            return "Codex CLI RPC returned invalid data: \(message)"
        case .timedOut:
            return "Codex CLI RPC timed out."
        }
    }
}

final class CodexRPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1
    private let logger = DiagnosticsLogger.shared

    private final class LineBuffer {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
    }

    init(environment: [String: String]) throws {
        var continuation: AsyncStream<Data>.Continuation!
        stdoutLineStream = AsyncStream<Data> { streamContinuation in
            continuation = streamContinuation
        }
        stdoutLineContinuation = continuation

        guard let binary = BinaryLocator.resolveCodexBinary(environment: environment) else {
            throw RPCWireError.startFailed("Codex CLI not found.")
        }

        process.environment = environment
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RPCWireError.startFailed(error.localizedDescription)
        }

        let buffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutLineContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLineContinuation.finish()
                return
            }
            for line in buffer.appendAndDrainLines(data) {
                stdoutLineContinuation.yield(line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty {
                self?.logger.log("Codex RPC stderr: \(text)")
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await withTimeout(seconds: 5) {
            try await self.request(
                method: "initialize",
                params: ["clientInfo": ["name": clientName, "version": clientVersion]]
            )
        }
        try sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> RPCAccountResponse {
        let message = try await withTimeout(seconds: 5) {
            try await self.request(method: "account/read")
        }
        return try decodeResult(from: message)
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        let message = try await withTimeout(seconds: 5) {
            try await self.request(method: "account/rateLimits/read")
        }
        return try decodeResult(from: message)
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try sendRequest(id: id, method: method, params: params)

        while true {
            let message = try await readNextMessage()

            if message["id"] == nil, let notification = message["method"] as? String {
                logger.log("Codex RPC notification: \(notification)")
                continue
            }

            guard let messageID = jsonID(message["id"]), messageID == id else {
                continue
            }

            if let error = message["error"] as? [String: Any],
               let messageText = error["message"] as? String {
                throw RPCWireError.requestFailed(messageText)
            }

            return message
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        let payload: [String: Any] = [
            "method": method,
            "params": params ?? [:]
        ]
        try sendPayload(payload)
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]? = nil) throws {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params ?? [:]
        ]
        try sendPayload(payload)
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await lineData in stdoutLineStream {
            if lineData.isEmpty {
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        throw RPCWireError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw RPCWireError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}
