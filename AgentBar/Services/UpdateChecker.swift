import Foundation
import AppKit

@MainActor @Observable
final class UpdateChecker {
    var latestVersion: String?
    var downloadURL: URL?
    var isUpdateAvailable = false
    var isChecking = false

    private let repo = "tansuasici/AgentBar"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }

            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else { return }

                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                latestVersion = version

                // Find DMG asset
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.hasSuffix(".dmg"),
                           let urlStr = asset["browser_download_url"] as? String,
                           let assetURL = URL(string: urlStr) {
                            downloadURL = assetURL
                            break
                        }
                    }
                }

                // Fallback: release page
                if downloadURL == nil, let htmlURL = json["html_url"] as? String {
                    downloadURL = URL(string: htmlURL)
                }

                isUpdateAvailable = isNewerVersion(version, than: currentVersion)
            } catch {
                // Update check is non-critical
            }
        }
    }

    func openDownload() {
        guard let url = downloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
