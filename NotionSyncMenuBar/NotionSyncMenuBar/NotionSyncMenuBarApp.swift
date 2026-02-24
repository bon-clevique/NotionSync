import SwiftUI

@main
struct NotionSyncMenuBarApp: App {
    @State private var engine: SyncEngine
    @State private var apiSettings: APISettings
    private let bookmarkManager: BookmarkManager

    init() {
        let bm = BookmarkManager()
        let api = APISettings()
        let eng = SyncEngine(bookmarkManager: bm)
        eng.configure(token: api.token, dataSourceId: api.dataSourceId)

        self.bookmarkManager = bm
        self._apiSettings = State(initialValue: api)
        self._engine = State(initialValue: eng)
    }

    var body: some Scene {
        MenuBarExtra {
            if engine.isRunning {
                Text("NotionSync: Running (\(engine.activeTargetCount) dirs)")
            } else {
                Text("NotionSync: Stopped")
            }

            if let file = engine.lastSyncedFile, let date = engine.lastSyncedDate {
                Text("Last: \(file) (\(date, format: .relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            }

            if let error = engine.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }

            Divider()

            if engine.isRunning {
                Button("Stop") {
                    engine.stop()
                }
            } else {
                Button("Start") {
                    engine.configure(token: apiSettings.token, dataSourceId: apiSettings.dataSourceId)
                    engine.start()
                }
                .disabled(apiSettings.token.isEmpty || apiSettings.dataSourceId.isEmpty)
            }

            Divider()

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(engine.isRunning ? "Running" : "Stopped")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(apiSettings: apiSettings, bookmarkManager: bookmarkManager)
        }
    }
}
