import SwiftUI
import ServiceManagement
import Observation

// MARK: - APISettings

/// Observable store for Notion API credentials.
///
/// Uses UserDefaults for storage. Keychain is avoided in development builds
/// because ad-hoc code signing causes macOS to prompt for Keychain password
/// on every rebuild.
///
/// TODO: Switch to Keychain for production/App Store builds with proper code signing.
@Observable
@MainActor
final class APISettings {

    private static let tokenKey = "notionToken"
    private static let dataSourceIdKey = "notionDataSourceId"

    // MARK: Properties

    var token: String = "" {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    var dataSourceId: String = "" {
        didSet { UserDefaults.standard.set(dataSourceId, forKey: Self.dataSourceIdKey) }
    }

    private(set) var isLoaded = false

    // MARK: Init

    init() {
        token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        dataSourceId = UserDefaults.standard.string(forKey: Self.dataSourceIdKey) ?? ""
        isLoaded = true
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    var apiSettings: APISettings
    var bookmarkManager: BookmarkManager
    var configFilePath: String = ""
    var configTargets: [SyncTargetConfig] = []

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            APISettingsView(apiSettings: apiSettings)
                .tabItem { Label("API", systemImage: "key") }

            SyncTargetsSettingsView(bookmarkManager: bookmarkManager, configFilePath: configFilePath, configTargets: configTargets)
                .tabItem { Label("Sync Targets", systemImage: "folder") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - GeneralSettingsView

struct GeneralSettingsView: View {

    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $isLaunchAtLoginEnabled)
                    .onChange(of: isLaunchAtLoginEnabled) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle if the system call fails.
            isLaunchAtLoginEnabled = !enable
        }
    }
}

// MARK: - ConnectionStatus

private enum ConnectionStatus: Equatable {
    case untested
    case testing
    case success
    case failed(String)

    var label: String {
        switch self {
        case .untested:  return "Not tested"
        case .testing:   return "Testing…"
        case .success:   return "Connected"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .untested:  return .secondary
        case .testing:   return .secondary
        case .success:   return .green
        case .failed:    return .red
        }
    }
}

// MARK: - APISettingsView

struct APISettingsView: View {

    @Bindable var apiSettings: APISettings

    @State private var connectionStatus: ConnectionStatus = .untested

    var body: some View {
        Form {
            Section("Notion Integration") {
                SecureField("内部インテグレーションシークレット (ntn_…)", text: $apiSettings.token)
                    .textContentType(.password)
                    .onChange(of: apiSettings.token) { _, _ in
                        connectionStatus = .untested
                    }

                TextField("Data Source ID", text: $apiSettings.dataSourceId)
                    .onChange(of: apiSettings.dataSourceId) { _, _ in
                        connectionStatus = .untested
                    }
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        runConnectionTest()
                    }
                    .disabled(
                        apiSettings.token.isEmpty ||
                        connectionStatus == .testing
                    )

                    Spacer()

                    if connectionStatus != .untested {
                        Label(connectionStatus.label, systemImage: statusIcon)
                            .foregroundStyle(connectionStatus.color)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusIcon: String {
        switch connectionStatus {
        case .untested:  return "circle"
        case .testing:   return "clock"
        case .success:   return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private func runConnectionTest() {
        connectionStatus = .testing
        let token = apiSettings.token
        Task {
            do {
                _ = try await NotionAPIClient(token: token).testConnection()
                connectionStatus = .success
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - SyncTargetsSettingsView

struct SyncTargetsSettingsView: View {

    var bookmarkManager: BookmarkManager
    var configFilePath: String = ""
    var configTargets: [SyncTargetConfig] = []

    var body: some View {
        Form {
            if !configFilePath.isEmpty {
                Section {
                    Label("sync_targets.json から読み込み", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(configFilePath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Section("同期ディレクトリ") {
                    if configTargets.isEmpty {
                        Text("ターゲットが設定されていません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(configTargets, id: \.directory) { target in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: target.directory).lastPathComponent)
                                    .fontWeight(.medium)
                                Text(target.directory)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let noteId = target.resolvedNoteId {
                                    Text("Lit Note: \(target.litNote ?? noteId)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section("Watched Directories") {
                    if bookmarkManager.targets.isEmpty {
                        Text("No directories added yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(bookmarkManager.targets) { target in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.displayName)
                                            .fontWeight(.medium)
                                        if let noteId = target.noteId, !noteId.isEmpty {
                                            Text("Note ID: \(noteId)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Remove") {
                                        bookmarkManager.removeTarget(target)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                }
                            }
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 80)
                    }

                    Button("Add Directory…") {
                        _ = bookmarkManager.addDirectory()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
