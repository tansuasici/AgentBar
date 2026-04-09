import Foundation

/// Scans Claude Code JSONL session files under ~/.claude/projects/ to compute token costs.
/// Deduplicates by requestId to avoid counting the same API call multiple times
/// (each request produces multiple JSONL lines for thinking/text/tool_use blocks).
@MainActor @Observable
final class ClaudeCodeCostScanner {
    var costData: CostData = .empty
    var isScanning = false

    private let claudeDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }()

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        await Task.detached(priority: .utility) { [claudeDir] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: claudeDir.path) else { return }

            let cutoff30Days = Date().addingTimeInterval(-30 * 24 * 3600)
            let todayStart = Calendar.current.startOfDay(for: Date())

            // ISO8601 formatters — one with fractional seconds, one without
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]

            // Track seen requestIds to avoid double-counting
            var seenRequests = Set<String>()

            var allModels: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]
            var todayModels: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]

            guard let enumerator = fm.enumerator(
                at: claudeDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }

                if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate < cutoff30Days { continue }

                guard let data = try? Data(contentsOf: fileURL) else { continue }

                data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var lineStart = 0
                    let count = data.count

                    while lineStart < count {
                        var lineEnd = lineStart
                        while lineEnd < count && base.load(fromByteOffset: lineEnd, as: UInt8.self) != 0x0A {
                            lineEnd += 1
                        }

                        let lineData = Data(bytes: base + lineStart, count: lineEnd - lineStart)
                        lineStart = lineEnd + 1

                        guard lineData.range(of: Data("\"usage\"".utf8)) != nil,
                              lineData.range(of: Data("\"assistant\"".utf8)) != nil else { continue }

                        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              json["type"] as? String == "assistant",
                              let message = json["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { continue }

                        // Deduplicate: skip if we've already seen this requestId
                        if let requestId = json["requestId"] as? String {
                            guard seenRequests.insert(requestId).inserted else { continue }
                        }

                        let model = message["model"] as? String ?? "unknown"
                        let inputTok = usage["input_tokens"] as? Int ?? 0
                        let outputTok = usage["output_tokens"] as? Int ?? 0
                        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0

                        // Accumulate for 30-day window
                        var existing = allModels[model] ?? (0, 0, 0, 0)
                        existing.input += inputTok
                        existing.output += outputTok
                        existing.cacheRead += cacheRead
                        existing.cacheWrite += cacheWrite
                        allModels[model] = existing

                        // Check if today — try both timestamp formats
                        if let timestamp = json["timestamp"] as? String,
                           let date = fmtFrac.date(from: timestamp) ?? fmtPlain.date(from: timestamp),
                           date >= todayStart {
                            var todayExisting = todayModels[model] ?? (0, 0, 0, 0)
                            todayExisting.input += inputTok
                            todayExisting.output += outputTok
                            todayExisting.cacheRead += cacheRead
                            todayExisting.cacheWrite += cacheWrite
                            todayModels[model] = todayExisting
                        }
                    }
                }
            }

            // Build result
            var todayCost = 0.0
            var todayTokens = 0
            var totalCost = 0.0
            var totalTokens = 0
            var breakdown: [ModelCost] = []

            for (model, counts) in allModels.sorted(by: { $0.key < $1.key }) {
                let cost = ClaudePricing.cost(
                    model: model, input: counts.input, output: counts.output,
                    cacheRead: counts.cacheRead, cacheWrite: counts.cacheWrite
                )
                totalCost += cost
                totalTokens += counts.input + counts.output + counts.cacheRead + counts.cacheWrite
                breakdown.append(ModelCost(
                    id: model, inputTokens: counts.input, outputTokens: counts.output,
                    cacheReadTokens: counts.cacheRead, cacheWriteTokens: counts.cacheWrite, cost: cost
                ))
            }

            for (model, counts) in todayModels {
                let cost = ClaudePricing.cost(
                    model: model, input: counts.input, output: counts.output,
                    cacheRead: counts.cacheRead, cacheWrite: counts.cacheWrite
                )
                todayCost += cost
                todayTokens += counts.input + counts.output + counts.cacheRead + counts.cacheWrite
            }

            let result = CostData(
                todayCost: todayCost, todayTokens: todayTokens,
                last30DaysCost: totalCost, last30DaysTokens: totalTokens,
                perModelBreakdown: breakdown.sorted { $0.cost > $1.cost }
            )

            await MainActor.run {
                self.costData = result
            }
        }.value
    }
}
