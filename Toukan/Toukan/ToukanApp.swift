import SwiftUI

@main
struct ToukanApp: App {
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
            MenuBarContent(engine: engine, apiSettings: apiSettings)
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

// MARK: - MenuBarContent

private struct MenuBarContent: View {

    var engine: SyncEngine
    var apiSettings: APISettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if engine.isRunning {
            Text("Toukan: Running (\(engine.activeTargetCount) dirs)")
        } else {
            Text("Toukan: Stopped")
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

        Button("Settings...") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit") {
            engine.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}
