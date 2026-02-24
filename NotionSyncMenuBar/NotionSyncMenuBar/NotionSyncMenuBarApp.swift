import SwiftUI

@main
struct NotionSyncMenuBarApp: App {
    @StateObject private var manager = SyncManager()

    var body: some Scene {
        MenuBarExtra {
            if manager.isRunning {
                Text("NotionSync: Running")
            } else {
                Text("NotionSync: Stopped")
            }

            Divider()

            if manager.isRunning {
                Button("Stop") {
                    manager.stop()
                }
            } else {
                Button("Start") {
                    manager.start()
                }
            }

            Divider()

            Button("Edit Config...") {
                manager.editConfig()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(manager.isRunning ? "Running" : "Stopped")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
    }
}
