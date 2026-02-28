import SwiftUI

@main
struct ToukanApp: App {
    @State private var engine: SyncEngine
    @State private var apiSettings: APISettings
    @State private var languageManager: LanguageManager
    @State private var logStore: SyncLogStore
    private let bookmarkManager: BookmarkManager

    init() {
        let bm = BookmarkManager()
        let api = APISettings()
        let ls = SyncLogStore()
        let lm = LanguageManager()
        let eng = SyncEngine(bookmarkManager: bm, apiSettings: api, logStore: ls, languageManager: lm)

        self.bookmarkManager = bm
        self._apiSettings = State(initialValue: api)
        self._engine = State(initialValue: eng)
        self._languageManager = State(initialValue: lm)
        self._logStore = State(initialValue: ls)
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
            SettingsView(apiSettings: apiSettings, bookmarkManager: bookmarkManager, languageManager: languageManager, logStore: logStore)
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
                engine.start()
            }
            .disabled(apiSettings.token.isEmpty || apiSettings.dataSourceId.isEmpty)
        }

        Divider()

        Button(strings.menuSettings) {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(strings.menuQuit) {
            engine.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}
