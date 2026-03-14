import SwiftUI

struct MenuContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AgentBar")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Text(viewModel.lastRefreshText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Detected apps
            if viewModel.hasAnyDetected {
                VStack(spacing: 0) {
                    ForEach(viewModel.detectedApps) { app in
                        AppRowView(
                            app: app,
                            liveData: viewModel.usage(for: app)
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        if app != viewModel.detectedApps.last {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                // Empty state
                VStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No AI apps detected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Install Claude, ChatGPT, Cursor or Codex")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 16)
            }

            Divider()

            // Actions
            VStack(spacing: 0) {
                if viewModel.hasAnyDetected {
                    actionButton(icon: "arrow.clockwise", title: "Refresh") {
                        viewModel.refreshAll()
                    }
                    .disabled(viewModel.isRefreshing)
                    .overlay(alignment: .trailing) {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 14)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                actionButton(icon: "xmark.circle", title: "Quit AgentBar") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 300)
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Row

struct AppRowView: View {
    let app: AppPreset
    let liveData: LiveUsageData?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: icon + name + status
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(app.displayName)
                    .font(.system(.body, design: .default))

                Spacer()

                statusBadge
            }

            // Live usage bars
            if let liveData = liveData {
                switch liveData.status {
                case .loaded where !liveData.buckets.isEmpty:
                    VStack(spacing: 3) {
                        ForEach(liveData.buckets) { bucket in
                            UsageBarView(bucket: bucket)
                        }
                    }
                    .padding(.leading, 20)

                case .loading:
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)

                case .error(let msg):
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(.leading, 20)

                case .notSupported:
                    Text("Live tracking coming soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)

                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let liveData = liveData {
            switch liveData.status {
            case .loaded:
                let maxUsage = liveData.buckets.map(\.percentUsed).max() ?? 0
                Text("\(Int(maxUsage * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(percentColor(maxUsage))
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .notSupported:
                Text("Detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        guard let liveData = liveData else { return .gray }
        switch liveData.status {
        case .loaded:
            let maxUsage = liveData.buckets.map(\.percentUsed).max() ?? 0
            if maxUsage > 0.9 { return .red }
            if maxUsage > 0.7 { return .orange }
            return .green
        case .loading: return .orange
        case .error: return .red
        case .notSupported: return .blue
        }
    }

    private func percentColor(_ value: Double) -> Color {
        if value > 0.9 { return .red }
        if value > 0.7 { return .orange }
        return .primary
    }
}

// MARK: - Usage Bar

struct UsageBarView: View {
    let bucket: UsageBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(bucket.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(bucket.percentUsed * 100))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(barColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geometry.size.width * bucket.percentUsed, height: 4)
                }
            }
            .frame(height: 4)

            if !bucket.resetText.isEmpty {
                Text(bucket.resetText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        if bucket.percentUsed > 0.9 { return .red }
        if bucket.percentUsed > 0.7 { return .orange }
        if bucket.percentUsed > 0.5 { return .yellow }
        return .blue
    }
}
