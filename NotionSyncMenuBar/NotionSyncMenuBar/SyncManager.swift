import Foundation
import AppKit

@MainActor
final class SyncManager: ObservableObject {
    @Published var isRunning = false

    private var timer: Timer?

    private let nsyncPath: String
    private let configPath: String
    private let serviceLabel: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        nsyncPath = home.appendingPathComponent("dev/NotionSync/nsync").path
        configPath = home.appendingPathComponent("dev/NotionSync/sync_targets.json").path
        serviceLabel = "com.\(NSUserName()).notionsync"

        Task { await refreshStatus() }
        startPolling()
    }

    nonisolated func invalidateTimer() {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }

    deinit {
        invalidateTimer()
    }

    // MARK: - Polling

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshStatus()
            }
        }
    }

    /// バックグラウンドで launchctl を実行し、結果を MainActor で反映
    private func refreshStatus() async {
        let label = serviceLabel
        let running = await Task.detached {
            let output = Self.runShell("/bin/launchctl", "list")
            return output.split(separator: "\n").contains { $0.hasSuffix(label) }
        }.value
        isRunning = running
    }

    // MARK: - Actions

    func start() {
        guard ensureNsyncExists() else { return }
        // 楽観的 UI 更新
        isRunning = true
        Task.detached { [nsyncPath] in
            Self.runShell(nsyncPath, "--start")
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        }
    }

    func stop() {
        guard ensureNsyncExists() else { return }
        isRunning = false
        Task.detached { [nsyncPath] in
            Self.runShell(nsyncPath, "--stop")
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        }
    }

    func editConfig() {
        let kittyPath = "/Applications/kitty.app/Contents/MacOS/kitty"

        if FileManager.default.fileExists(atPath: kittyPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kittyPath)
            process.arguments = ["vi", configPath]
            try? process.run()
        } else {
            // パスをエスケープして AppleScript インジェクションを防止
            let escapedPath = configPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Terminal"
                activate
                do script "vi \\\"\(escapedPath)\\\""
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error {
                    NSLog("AppleScript error: %@", error)
                }
            }
        }
    }

    // MARK: - Validation

    private func ensureNsyncExists() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: nsyncPath) else {
            let alert = NSAlert()
            alert.messageText = "nsync が見つかりません"
            alert.informativeText = "パス: \(nsyncPath)\nsetup.sh を実行してください。"
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
        return true
    }

    // MARK: - Shell

    @discardableResult
    private nonisolated static func runShell(_ command: String, _ arguments: String...) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
