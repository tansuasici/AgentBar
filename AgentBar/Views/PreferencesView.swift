import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPane()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            ProvidersPane()
                .tabItem {
                    Label("Providers", systemImage: "square.stack.3d.up")
                }
                .tag("providers")

            AboutPane()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 420, height: 280)
    }
}

// MARK: - General

struct GeneralPane: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300

    private let intervals: [(String, Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }

            Section("Refresh") {
                Picker("Check usage every", selection: $refreshInterval) {
                    ForEach(intervals, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
            }

            Section("Keyboard Shortcut") {
                HStack {
                    Text("Toggle menu")
                    Spacer()
                    Text("⌃⌥M")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Providers

struct ProvidersPane: View {
    @AppStorage("enabledProviders") private var enabledProvidersData: Data = Data()

    private var allProviders: [(id: String, name: String, icon: String)] {
        [
            ("claude", "Claude", "brain.head.profile"),
            ("chatgpt", "ChatGPT", "bubble.left.and.bubble.right"),
        ]
    }

    private var enabledIds: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: enabledProvidersData)) ?? Set(allProviders.map(\.id))
        }
    }

    var body: some View {
        Form {
            Section("Active Providers") {
                ForEach(allProviders, id: \.id) { provider in
                    let isEnabled = enabledIds.contains(provider.id)
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            var ids = enabledIds
                            if newValue { ids.insert(provider.id) } else { ids.remove(provider.id) }
                            enabledProvidersData = (try? JSONEncoder().encode(ids)) ?? Data()
                        }
                    )) {
                        Label(provider.name, systemImage: provider.icon)
                    }
                }
            }

            Section {
                Text("More providers coming soon: Cursor, Gemini, Copilot...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutPane: View {
    private let sparkleUpdater = SparkleUpdater()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("AgentBar")
                .font(.title2.bold())

            Text("v\(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Track your AI coding assistant usage from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/tansuasici/AgentBar") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Button("Check for Updates") {
                    sparkleUpdater.checkForUpdates()
                }
                .buttonStyle(.link)
                .disabled(!sparkleUpdater.canCheckForUpdates)
            }
            .font(.caption)

            Spacer()
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
    }
}
