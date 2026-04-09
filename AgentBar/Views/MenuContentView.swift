import SwiftUI

struct MenuContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {

            // ── Usage Area ────────────────────────────────
            VStack(spacing: 0) {
                ForEach(Array(viewModel.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        Divider()
                    }

                    ServiceHeaderView(
                        name: provider.displayName,
                        isConnected: provider.usageData.status == .loaded && !provider.usageData.buckets.isEmpty,
                        onDisconnect: (provider.usageData.status == .loaded && !provider.usageData.buckets.isEmpty) ? {
                            provider.disconnect()
                        } : nil
                    )
                    Divider()
                    UsageSectionView(
                        usageData: provider.usageData,
                        isDesktopInstalled: provider.id == "claude" && ChromiumCookieReader.isClaudeDesktopInstalled,
                        desktopHint: provider.id == "claude" ? "Open Claude Desktop or sign in below" : nil,
                        signInLabel: "Sign in to \(provider.displayName)",
                        onSignIn: {
                            LoginWindowController.shared.open(
                                config: provider.loginConfig,
                                loginManager: provider.loginManager,
                                onComplete: { Task { await provider.refresh() } }
                            )
                        }
                    )
                }
            }

            // ── Update Banner ───────────────────────────
            if viewModel.updateChecker.isUpdateAvailable,
               let version = viewModel.updateChecker.latestVersion {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("v\(version) available")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Download") {
                        viewModel.updateChecker.openDownload()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.blue)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            Divider()

            // ── Settings ────────────────────────────────
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.launchAtLogin = $0 }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider()

            // ── Footer ──────────────────────────────────
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }
}

// MARK: - Service Header

struct ServiceHeaderView: View {
    let name: String
    let isConnected: Bool
    var onDisconnect: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? .green : .gray)
                .frame(width: 7, height: 7)

            Text(name)
                .font(.system(.headline, design: .rounded))

            Spacer()

            if let onDisconnect {
                Button("Disconnect") {
                    onDisconnect()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Usage Section (reusable for any service)

struct UsageSectionView: View {
    let usageData: LiveUsageData
    let isDesktopInstalled: Bool
    let desktopHint: String?
    let signInLabel: String
    let onSignIn: () -> Void

    var body: some View {
        switch usageData.status {
        case .loaded where !usageData.buckets.isEmpty:
            VStack(spacing: 10) {
                ForEach(usageData.buckets) { bucket in
                    UsageBarView(bucket: bucket)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

        case .loaded:
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("No usage in current windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

        case .loading:
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading usage...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

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
            .padding(.vertical, 12)

        case .needsLogin:
            VStack(spacing: 6) {
                if isDesktopInstalled, let hint = desktopHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button(signInLabel) {
                    onSignIn()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 10)
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
