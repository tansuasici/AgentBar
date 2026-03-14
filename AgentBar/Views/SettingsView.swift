import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("AgentBar")
                        .font(.title3.bold())
                    Text("Detected AI apps on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Detected apps list
            if viewModel.detectedApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No AI apps found")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Install Claude, ChatGPT, Cursor or Codex\nto start tracking usage automatically.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(viewModel.detectedApps) { app in
                            DetectedAppRow(app: app, liveData: viewModel.usage(for: app))
                        }
                    }
                    .padding(.horizontal)
                }
            }

            Divider()

            // Footer
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("All data stays on your device. No servers, no accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 400, height: 320)
    }
}

// MARK: - Detected App Row

struct DetectedAppRow: View {
    let app: AppPreset
    let liveData: LiveUsageData?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: app.iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(.body, weight: .medium))

                HStack(spacing: 4) {
                    if app.supportsLiveTracking {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Live tracking active")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                        Text("Detected · tracking coming soon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let liveData = liveData, case .loaded = liveData.status {
                let maxUsage = liveData.buckets.map(\.percentUsed).max() ?? 0
                Text("\(Int(maxUsage * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(maxUsage > 0.7 ? .orange : .primary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
