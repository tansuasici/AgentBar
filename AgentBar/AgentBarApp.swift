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
            HStack(spacing: 4) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
