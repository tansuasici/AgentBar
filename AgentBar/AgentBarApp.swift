import SwiftUI

@main
struct AgentBarApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.startAutoRefresh()
                }
        } label: {
            MenuBarIconView(providers: viewModel.providers)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
        }
    }
}
