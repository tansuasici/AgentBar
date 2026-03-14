import Foundation

/// Reads local data from Codex.app (native macOS app by OpenAI)
/// Data sources:
/// - Log files (session count, active days, auth method)
/// - UserDefaults (basic app info)
enum CodexLocalReader {

    struct LocalData {
        let sessionCount: Int
        let activeDays: Int
        let authMethod: String?   // e.g., "chatgpt"
        let hasPlan: Bool
    }

    // MARK: - Public API

    static func readLocalData() throws -> LocalData {
        guard FileManager.default.fileExists(atPath: "/Applications/Codex.app") else {
            throw ReadError.appNotInstalled
        }

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex")

        let sessions = countSessions(logsDir: logsDir)
        let days = countActiveDays(logsDir: logsDir)
        let authInfo = readAuthInfo(logsDir: logsDir)

        return LocalData(
            sessionCount: sessions,
            activeDays: days,
            authMethod: authInfo.method,
            hasPlan: authInfo.hasPlan
        )
    }

    /// Convert local data to usage buckets for display
    static func toBuckets(_ data: LocalData) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        // Auth method
        if let auth = data.authMethod {
            let label = auth == "chatgpt" ? "Auth: ChatGPT" : "Auth: \(auth.capitalized)"
            buckets.append(UsageBucket(
                label: label,
                percentUsed: 0,
                resetText: data.hasPlan ? "Plan active" : ""
            ))
        }

        // Session stats
        if data.sessionCount > 0 {
            buckets.append(UsageBucket(
                label: "\(data.sessionCount) sessions",
                percentUsed: 0,
                resetText: "\(data.activeDays) active days"
            ))
        }

        return buckets
    }

    // MARK: - Log Analysis

    /// Count unique sessions from log filenames
    /// Format: codex-desktop-{uuid}-{pid}-t{n}-i{n}-{time}-{n}.log
    private static func countSessions(logsDir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: logsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var sessionIds = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "log" else { continue }
            let name = url.lastPathComponent
            // Extract session UUID from filename
            // codex-desktop-{uuid}-{pid}-t0-i1-{time}-0.log
            if name.hasPrefix("codex-desktop-") {
                let parts = name.dropFirst("codex-desktop-".count)
                // UUID is 36 chars (8-4-4-4-12)
                if parts.count >= 36 {
                    let uuid = String(parts.prefix(36))
                    sessionIds.insert(uuid)
                }
            }
        }
        return sessionIds.count
    }

    /// Count active days by counting date directories
    private static func countActiveDays(logsDir: URL) -> Int {
        // Structure: .../2026/03/14/
        guard let yearDirs = try? FileManager.default.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }

        var count = 0
        for yearDir in yearDirs {
            guard let monthDirs = try? FileManager.default.contentsOfDirectory(
                at: yearDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for monthDir in monthDirs {
                guard let dayDirs = try? FileManager.default.contentsOfDirectory(
                    at: monthDir,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }

                count += dayDirs.count
            }
        }
        return count
    }

    /// Read auth info from the most recent log file
    private static func readAuthInfo(logsDir: URL) -> (method: String?, hasPlan: Bool) {
        // Find the most recent log file
        guard let recentLog = findMostRecentLog(logsDir: logsDir) else {
            return (nil, false)
        }

        guard let content = try? String(contentsOf: recentLog, encoding: .utf8) else {
            return (nil, false)
        }

        // Parse: Statsig: auth context ready summary="authMethod=chatgpt, hasUserId=true, ..., hasPlan=true"
        var method: String?
        var hasPlan = false

        for line in content.components(separatedBy: .newlines) {
            guard line.contains("Statsig: auth context ready") else { continue }

            if let range = line.range(of: "authMethod=") {
                let after = line[range.upperBound...]
                if let comma = after.firstIndex(of: ",") {
                    method = String(after[..<comma])
                } else if let quote = after.firstIndex(of: "\"") {
                    method = String(after[..<quote])
                }
            }

            if line.contains("hasPlan=true") {
                hasPlan = true
            }
        }

        return (method, hasPlan)
    }

    private static func findMostRecentLog(logsDir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var mostRecent: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "log" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = values.contentModificationDate else { continue }

            if mostRecent == nil || modDate > mostRecent!.date {
                mostRecent = (url, modDate)
            }
        }
        return mostRecent?.url
    }

    // MARK: - Errors

    enum ReadError: LocalizedError {
        case appNotInstalled

        var errorDescription: String? {
            switch self {
            case .appNotInstalled: "Codex not installed"
            }
        }
    }
}
