import SwiftUI

/// Menu bar label that reflects aggregate provider status.
/// - Loading: pulsing opacity animation
/// - Error: exclamation mark badge
/// - High usage (>80%): red tint dot
/// - Normal: static icon
struct MenuBarIconView: View {
    let providers: [any UsageProvider]

    private var isAnyRefreshing: Bool {
        providers.contains { $0.isRefreshing }
    }

    private var hasError: Bool {
        providers.contains {
            if case .error = $0.usageData.status { return true }
            return false
        }
    }

    private var maxUsage: Double {
        providers.flatMap(\.usageData.buckets).map(\.percentUsed).max() ?? 0
    }

    private var statusColor: Color? {
        if hasError { return .orange }
        if maxUsage > 0.9 { return .red }
        if maxUsage > 0.8 { return .orange }
        return nil
    }

    var body: some View {
        HStack(spacing: 2) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(isAnyRefreshing ? 0.5 : 1.0)
                .animation(
                    isAnyRefreshing
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isAnyRefreshing
                )

            if let color = statusColor {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
            }
        }
    }
}
