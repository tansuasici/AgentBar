import SwiftUI

struct CostSectionView: View {
    let costData: CostData
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Cost")
                        .font(.system(.caption, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            // Summary
            VStack(spacing: 2) {
                HStack {
                    Text("Today:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatCost(costData.todayCost))
                        .font(.system(.caption2, design: .monospaced))
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(formatTokens(costData.todayTokens))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                HStack {
                    Text("30 days:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatCost(costData.last30DaysCost))
                        .font(.system(.caption2, design: .monospaced))
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(formatTokens(costData.last30DaysTokens))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            // Expanded: per-model breakdown
            if isExpanded && !costData.perModelBreakdown.isEmpty {
                Divider()
                    .padding(.horizontal, 14)
                VStack(spacing: 4) {
                    ForEach(costData.perModelBreakdown) { model in
                        HStack {
                            Text(shortModelName(model.id))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatCost(model.cost))
                                .font(.system(size: 9, design: .monospaced))
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                            Text(formatTokens(model.inputTokens + model.outputTokens))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 && value > 0 { return "< $0.01" }
        return String(format: "$%.2f", value)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.0fK tokens", Double(count) / 1000)
        }
        return "\(count) tokens"
    }

    private func shortModelName(_ name: String) -> String {
        if name.contains("opus") { return "Opus" }
        if name.contains("sonnet") { return "Sonnet" }
        if name.contains("haiku") { return "Haiku" }
        return name
    }
}
