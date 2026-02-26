import SwiftUI

@main
struct ToukanApp: App {
    @State private var engine: SyncEngine
    @State private var apiSettings: APISettings
    @State private var languageManager: LanguageManager
    private let bookmarkManager: BookmarkManager

    init() {
        let bm = BookmarkManager()
        let api = APISettings()
        let eng = SyncEngine(bookmarkManager: bm)
        eng.configure(token: api.token, dataSourceId: api.dataSourceId)
        let lm = LanguageManager()

        self.bookmarkManager = bm
        self._apiSettings = State(initialValue: api)
        self._engine = State(initialValue: eng)
        self._languageManager = State(initialValue: lm)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(engine: engine, apiSettings: apiSettings, languageManager: languageManager)
        } label: {
            Image(engine.isRunning ? "Running" : "Stopped")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(apiSettings: apiSettings, bookmarkManager: bookmarkManager, languageManager: languageManager)
        }
    }
}

// MARK: - MenuBarContent

private struct MenuBarContent: View {

    var engine: SyncEngine
    var apiSettings: APISettings
    var languageManager: LanguageManager
    @Environment(\.openSettings) private var openSettings

    private var strings: Strings { languageManager.strings }

    var body: some View {
        if engine.isRunning {
            Text(strings.menuRunning(count: engine.activeTargetCount))
        } else {
            Text(strings.menuStopped)
        }

        if let file = engine.lastSyncedFile, let date = engine.lastSyncedDate {
            Text("\(strings.lastLabel): \(file) (\(date, format: .relative(presentation: .named)))")
                .foregroundStyle(.secondary)
        }

        if let error = engine.errorMessage {
            Text(error)
                .foregroundStyle(.red)
        }

        Divider()

        if engine.isRunning {
            Button(strings.menuStop) {
                engine.stop()
            }
        } else {
            Button(strings.menuStart) {
                engine.configure(token: apiSettings.token, dataSourceId: apiSettings.dataSourceId)
                engine.start()
            }
            .disabled(apiSettings.token.isEmpty || apiSettings.dataSourceId.isEmpty)
        }

        Divider()

        Button(strings.menuSettings) {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(strings.menuQuit) {
            engine.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}
