import SwiftUI

struct MenuContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header: Claude + status
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.hasUsageData ? .green : .gray)
                    .frame(width: 7, height: 7)

                Text("Claude")
                    .font(.system(.headline, design: .rounded))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Usage content
            switch viewModel.usageData.status {
            case .loaded where !viewModel.usageData.buckets.isEmpty:
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(viewModel.usageData.buckets) { bucket in
                            UsageBarView(bucket: bucket)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 320)

            case .loading:
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading usage...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)

            case .error(let msg):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)

            case .needsLogin:
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Sign in to see usage")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if viewModel.isClaudeDesktopInstalled {
                        Text("Open Claude Desktop or sign in below")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Button("Sign in to Claude") {
                        viewModel.startLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }
                .padding(.vertical, 16)

            default:
                EmptyView()
            }

            Divider()

            // Footer
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if viewModel.hasUsageData && viewModel.loginManager.isConnected {
                    Button("Disconnect") {
                        viewModel.disconnect()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .sheet(isPresented: Binding(
            get: { viewModel.loginManager.isLoginWindowOpen },
            set: { viewModel.loginManager.isLoginWindowOpen = $0 }
        )) {
            WebLoginView(
                config: WebLoginManager.claudeConfig,
                loginManager: viewModel.loginManager,
                onDismiss: {
                    viewModel.loginManager.isLoginWindowOpen = false
                    if viewModel.loginManager.isConnected {
                        viewModel.onLoginCompleted()
                    }
                }
            )
        }
    }

}

// MARK: - Usage Bar

struct UsageBarView: View {
    let bucket: UsageBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

                    if bucket.percentUsed > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geometry.size.width * bucket.percentUsed, height: 4)
                    }
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
