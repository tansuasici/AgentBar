import Foundation

/// Scans Claude Code JSONL session files under ~/.claude/projects/ to compute token costs.
/// Uses incremental parsing: tracks last read byte offset per file to avoid re-reading.
@MainActor @Observable
final class ClaudeCodeCostScanner {
    var costData: CostData = .empty
    var isScanning = false

    private var fileOffsets: [String: UInt64] = [:]
    private var accumulated: [String: AccumulatedModel] = [:]

    private struct AccumulatedModel {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
    }

    private let claudeDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }()

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        await Task.detached(priority: .utility) { [claudeDir, fileOffsets] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: claudeDir.path) else { return }

            let cutoff30Days = Date().addingTimeInterval(-30 * 24 * 3600)
            let todayStart = Calendar.current.startOfDay(for: Date())

            var allModels: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]
            var todayModels: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]

            // Find all JSONL files
            guard let enumerator = fm.enumerator(
                at: claudeDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            var offsets = fileOffsets

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }

                // Skip files not modified in last 30 days
                if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate < cutoff30Days { continue }

                let path = fileURL.path
                let startOffset = offsets[path] ?? 0

                guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      UInt64(fileSize) > startOffset else { continue }

                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { handle.closeFile() }

                if startOffset > 0 {
                    handle.seek(toFileOffset: startOffset)
                }

                guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
                offsets[path] = startOffset + UInt64(data.count)

                // Parse line by line
                data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var lineStart = 0
                    let count = data.count

                    while lineStart < count {
                        // Find end of line
                        var lineEnd = lineStart
                        while lineEnd < count && base.load(fromByteOffset: lineEnd, as: UInt8.self) != 0x0A {
                            lineEnd += 1
                        }

                        let lineData = Data(bytes: base + lineStart, count: lineEnd - lineStart)
                        lineStart = lineEnd + 1

                        // Quick check: does line contain "usage"?
                        guard lineData.range(of: Data("\"usage\"".utf8)) != nil,
                              lineData.range(of: Data("\"assistant\"".utf8)) != nil else { continue }

                        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              json["type"] as? String == "assistant",
                              let message = json["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { continue }

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

                        // Check if today
                        if let timestamp = json["timestamp"] as? String {
                            let fmt = ISO8601DateFormatter()
                            if let date = fmt.date(from: timestamp), date >= todayStart {
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
            }

            // Build result
            var todayCost = 0.0
            var todayTokens = 0
            var totalCost = 0.0
            var totalTokens = 0
            var breakdown: [ModelCost] = []

            for (model, counts) in allModels.sorted(by: { $0.key < $1.key }) {
                let cost = ClaudePricing.cost(
                    model: model,
                    input: counts.input,
                    output: counts.output,
                    cacheRead: counts.cacheRead,
                    cacheWrite: counts.cacheWrite
                )
                totalCost += cost
                totalTokens += counts.input + counts.output + counts.cacheRead + counts.cacheWrite

                breakdown.append(ModelCost(
                    id: model,
                    inputTokens: counts.input,
                    outputTokens: counts.output,
                    cacheReadTokens: counts.cacheRead,
                    cacheWriteTokens: counts.cacheWrite,
                    cost: cost
                ))
            }

            for (model, counts) in todayModels {
                let cost = ClaudePricing.cost(
                    model: model,
                    input: counts.input,
                    output: counts.output,
                    cacheRead: counts.cacheRead,
                    cacheWrite: counts.cacheWrite
                )
                todayCost += cost
                todayTokens += counts.input + counts.output + counts.cacheRead + counts.cacheWrite
            }

            let result = CostData(
                todayCost: todayCost,
                todayTokens: todayTokens,
                last30DaysCost: totalCost,
                last30DaysTokens: totalTokens,
                perModelBreakdown: breakdown.sorted { $0.cost > $1.cost }
            )

            await MainActor.run { [offsets] in
                self.costData = result
                self.fileOffsets = offsets
            }
        }.value
    }
}
