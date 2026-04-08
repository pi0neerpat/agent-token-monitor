import Foundation

enum CodexAuthAccessError: LocalizedError {
    case authorizationRequired(String)
    case invalidSelection(String)
    case bookmarkCreationFailed(String)
    case bookmarkResolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired(let message):
            return message
        case .invalidSelection(let message):
            return message
        case .bookmarkCreationFailed(let message):
            return "Could not save Codex access: \(message)"
        case .bookmarkResolutionFailed(let message):
            return "Could not reopen Codex access: \(message)"
        }
    }
}

enum CodexAuthAccess {
    private static let bookmarkKey = "CodexAuthAccess.Bookmark"
    private static let pathKey = "CodexAuthAccess.Path"

    static func defaultAuthFileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let trimmed = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func hasAuthorizedFile() -> Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func authorize(url: URL) throws {
        guard url.lastPathComponent == "auth.json" else {
            throw CodexAuthAccessError.invalidSelection("Choose the Codex auth.json file to enable Codex.")
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(url.path, forKey: pathKey)
        } catch {
            let nsError = error as NSError
            throw CodexAuthAccessError.bookmarkCreationFailed("\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]")
        }
    }

    static func bookmarkedFileURL() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw CodexAuthAccessError.authorizationRequired(
                "Codex access has not been enabled. Use “Enable Codex…” in the Codex menu to grant one-time read access to auth.json."
            )
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                try authorize(url: url)
            }
            return url
        } catch let error as CodexAuthAccessError {
            throw error
        } catch {
            throw CodexAuthAccessError.bookmarkResolutionFailed(error.localizedDescription)
        }
    }

    static func withAuthorizedFile<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try bookmarkedFileURL()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }
}
