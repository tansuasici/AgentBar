import Foundation
import SQLite3

/// Reads local data from Cursor.app (Electron-based VS Code fork)
/// Data sources:
/// - state.vscdb SQLite (plan, subscription status, email, model preferences)
enum CursorLocalReader {

    struct LocalData {
        let email: String?
        let plan: String           // "free", "pro", "business"
        let subscriptionStatus: String? // "active", "canceled", "trialing", etc.
        let lastModel: String?     // e.g., "kimi-k2.5:cloud"
        let ensembleModels: [String]?
    }

    // MARK: - Public API

    static func readLocalData() throws -> LocalData {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stateDBPath = appSupport.appendingPathComponent("Cursor/User/globalStorage/state.vscdb").path

        guard FileManager.default.fileExists(atPath: stateDBPath) else {
            throw ReadError.dataNotFound
        }

        // Copy to avoid lock issues
        let tempPath = NSTemporaryDirectory() + "agentbar_cursor_\(UUID().uuidString).db"
        do {
            try FileManager.default.copyItem(atPath: stateDBPath, toPath: tempPath)
            for ext in ["-wal", "-shm"] {
                let src = stateDBPath + ext
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tempPath + ext)
                }
            }
        } catch {
            throw ReadError.sqliteError("Cannot copy database: \(error.localizedDescription)")
        }
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReadError.sqliteError("Cannot open database")
        }
        defer { sqlite3_close(db) }

        let email = readValue(db: db, key: "cursorAuth/cachedEmail")
        let plan = readValue(db: db, key: "cursorAuth/stripeMembershipType") ?? "unknown"
        let subStatus = readValue(db: db, key: "cursorAuth/stripeSubscriptionStatus")
        let lastModel = parseLastModel(readValue(db: db, key: "cursor/lastSingleModelPreference"))
        let ensemble = parseEnsembleModels(readValue(db: db, key: "cursor/bestOfNEnsemblePreferences"))

        return LocalData(
            email: email,
            plan: plan,
            subscriptionStatus: subStatus,
            lastModel: lastModel,
            ensembleModels: ensemble
        )
    }

    /// Convert local data to usage buckets for display
    static func toBuckets(_ data: LocalData) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        // Plan + subscription status
        let planLabel = data.plan.capitalized
        let statusText: String
        if let status = data.subscriptionStatus {
            statusText = status == "active" ? "Active" : status.capitalized
        } else {
            statusText = ""
        }

        buckets.append(UsageBucket(
            label: "Plan: \(planLabel)",
            percentUsed: 0,
            resetText: statusText
        ))

        // Last model used
        if let model = data.lastModel {
            buckets.append(UsageBucket(
                label: "Last Model",
                percentUsed: 0,
                resetText: model
            ))
        }

        // Ensemble models
        if let models = data.ensembleModels, !models.isEmpty {
            buckets.append(UsageBucket(
                label: "Ensemble (\(models.count) models)",
                percentUsed: 0,
                resetText: models.joined(separator: ", ")
            ))
        }

        // Account email
        if let email = data.email {
            buckets.append(UsageBucket(
                label: "Account",
                percentUsed: 0,
                resetText: email
            ))
        }

        return buckets
    }

    // MARK: - SQLite Helpers

    private static func readValue(db: OpaquePointer?, key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let valuePtr = sqlite3_column_text(stmt, 0) else { return nil }

        return String(cString: valuePtr)
    }

    // MARK: - JSON Parsing

    private static func parseLastModel(_ jsonString: String?) -> String? {
        // Format: {"composer":"kimi-k2.5:cloud"}
        guard let str = jsonString,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["composer"] as? String else {
            return nil
        }
        return model
    }

    private static func parseEnsembleModels(_ jsonString: String?) -> [String]? {
        // Format: {"2":["model-a","model-b"],"3":["model-a","model-b","model-c"]}
        guard let str = jsonString,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Get the highest count ensemble
        let sorted = json.keys.compactMap { Int($0) }.sorted()
        guard let maxKey = sorted.last,
              let models = json[String(maxKey)] as? [String] else {
            return nil
        }
        return models
    }

    // MARK: - Errors

    enum ReadError: LocalizedError {
        case dataNotFound
        case sqliteError(String)

        var errorDescription: String? {
            switch self {
            case .dataNotFound: "Cursor data not found. Open Cursor once first."
            case .sqliteError(let msg): "Cursor data error: \(msg)"
            }
        }
    }
}
