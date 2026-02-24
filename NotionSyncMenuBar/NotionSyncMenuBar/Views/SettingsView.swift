import SwiftUI
import ServiceManagement
import Observation

// MARK: - APISettings

/// Observable store for Notion API credentials.
///
/// Loads from the Keychain on initialisation and persists to the Keychain
/// whenever `token` or `dataSourceId` are mutated.
@Observable
@MainActor
final class APISettings {

    // MARK: Properties

    /// Notion Integration Token (secret_…).
    var token: String = "" {
        didSet { persistToken() }
    }

    /// Notion data source (database) ID.
    var dataSourceId: String = "" {
        didSet { persistDataSourceId() }
    }

    // MARK: Init

    init() {
        token = KeychainManager.load(key: "notionToken") ?? ""
        dataSourceId = KeychainManager.load(key: "dataSourceId") ?? ""
    }

    // MARK: Private

    private func persistToken() {
        do {
            if token.isEmpty {
                KeychainManager.delete(key: "notionToken")
            } else {
                try KeychainManager.save(key: "notionToken", value: token)
            }
        } catch {
            // Non-fatal: log and continue — UI should not crash on Keychain errors.
            print("[APISettings] Failed to persist token: \(error.localizedDescription)")
        }
    }

    private func persistDataSourceId() {
        do {
            if dataSourceId.isEmpty {
                KeychainManager.delete(key: "dataSourceId")
            } else {
                try KeychainManager.save(key: "dataSourceId", value: dataSourceId)
            }
        } catch {
            print("[APISettings] Failed to persist dataSourceId: \(error.localizedDescription)")
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    var apiSettings: APISettings
    var bookmarkManager: BookmarkManager
    var configFilePath: String = ""

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            APISettingsView(apiSettings: apiSettings)
                .tabItem { Label("API", systemImage: "key") }

            SyncTargetsSettingsView(bookmarkManager: bookmarkManager, configFilePath: configFilePath)
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
                SecureField("Integration Token (secret_…)", text: $apiSettings.token)
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

    @State private var selectedTargetID: UUID?
    @State private var editDisplayName: String = ""
    @State private var editNoteId: String = ""

    private var selectedTarget: SyncTarget? {
        guard let id = selectedTargetID else { return nil }
        return bookmarkManager.targets.first { $0.id == id }
    }

    var body: some View {
        Form {
            if !configFilePath.isEmpty {
                Section {
                    Label("Targets loaded from sync_targets.json", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(configFilePath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Section("Watched Directories") {
                if bookmarkManager.targets.isEmpty {
                    Text("No directories added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $selectedTargetID) {
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
                                    if selectedTargetID == target.id {
                                        selectedTargetID = nil
                                    }
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .tag(target.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minHeight: 80)
                }

                Button("Add Directory…") {
                    _ = bookmarkManager.addDirectory()
                }
                .disabled(!configFilePath.isEmpty)
            }

            if let target = selectedTarget {
                Section("Edit — \(target.displayName)") {
                    TextField("Display Name", text: $editDisplayName)
                        .onSubmit { commitEdits() }

                    TextField("Note ID (optional)", text: $editNoteId)
                        .onSubmit { commitEdits() }

                    Button("Save") {
                        commitEdits()
                    }
                    .disabled(editDisplayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .onAppear { loadEdits(for: target) }
                .onChange(of: selectedTargetID) { _, _ in
                    if let t = selectedTarget { loadEdits(for: t) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func loadEdits(for target: SyncTarget) {
        editDisplayName = target.displayName
        editNoteId = target.noteId ?? ""
    }

    private func commitEdits() {
        guard var target = selectedTarget else { return }
        let trimmed = editDisplayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        target.displayName = trimmed
        target.noteId = editNoteId.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : editNoteId.trimmingCharacters(in: .whitespaces)
        bookmarkManager.updateTarget(target)
    }
}
