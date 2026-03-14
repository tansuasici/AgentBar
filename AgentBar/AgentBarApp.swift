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

        // Login window as a separate Window scene
        Window("AgentBar Login", id: "login") {
            LoginWindowView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 640)
    }
}

/// Wraps the WebLoginView so it can be used as a standalone Window scene
struct LoginWindowView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let config = viewModel.loginManager.currentLoginService {
                WebLoginView(
                    config: config,
                    loginManager: viewModel.loginManager,
                    onDismiss: {
                        viewModel.loginManager.isLoginWindowOpen = false
                        viewModel.loginManager.currentLoginService = nil
                        viewModel.refreshAll()
                        dismissWindow(id: "login")
                    }
                )
            } else {
                VStack {
                    Text("No login in progress")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 480, height: 640)
            }
        }
    }
}
