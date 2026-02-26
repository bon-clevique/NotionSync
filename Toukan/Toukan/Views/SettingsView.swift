import SwiftUI
import ServiceManagement
import Observation

// MARK: - APISettings

/// Observable store for Notion API credentials.
///
/// The API token is stored in macOS Keychain (encrypted, app-scoped).
/// The data source ID is stored in UserDefaults (non-secret configuration value).
///
/// On first launch after migration, any token previously stored in UserDefaults
/// is moved to Keychain and the old entry is deleted.
@Observable
@MainActor
final class APISettings {

    private static let tokenKey = "notionToken"
    private static let dataSourceIdKey = "notionDataSourceId"
    private static let migrationDoneKey = "keychainMigrationDone_v1"

    // MARK: Properties

    var token: String = "" {
        didSet {
            guard isLoaded else { return }
            if token.isEmpty {
                KeychainManager.delete(key: Self.tokenKey)
            } else {
                try? KeychainManager.save(key: Self.tokenKey, value: token)
            }
        }
    }

    var dataSourceId: String = "" {
        didSet {
            guard isLoaded else { return }
            UserDefaults.standard.set(dataSourceId, forKey: Self.dataSourceIdKey)
        }
    }

    private(set) var isLoaded = false

    // MARK: Init

    init() {
        migrateFromUserDefaultsIfNeeded()
        token = KeychainManager.load(key: Self.tokenKey) ?? ""
        dataSourceId = UserDefaults.standard.string(forKey: Self.dataSourceIdKey) ?? ""
        isLoaded = true
    }

    /// Removes all stored credentials from Keychain and UserDefaults.
    func clearCredentials() {
        token = ""
        dataSourceId = ""
    }

    // MARK: - Migration

    /// One-time migration: moves token from UserDefaults to Keychain, then deletes the old entry.
    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return }

        if let legacyToken = defaults.string(forKey: Self.tokenKey), !legacyToken.isEmpty {
            do {
                try KeychainManager.save(key: Self.tokenKey, value: legacyToken)
                defaults.removeObject(forKey: Self.tokenKey)
            } catch {
                // Keychain save failed — keep the legacy token in UserDefaults for next attempt.
                return
            }
        }

        defaults.set(true, forKey: Self.migrationDoneKey)
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    var apiSettings: APISettings
    var bookmarkManager: BookmarkManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            APISettingsView(apiSettings: apiSettings)
                .tabItem { Label("API", systemImage: "key") }

            SyncTargetsSettingsView(bookmarkManager: bookmarkManager)
                .tabItem { Label("Sync Targets", systemImage: "folder") }
        }
        .frame(width: 480, height: 520)
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
    case success(databaseName: String?)
    case failed(String)

    var label: String {
        switch self {
        case .untested:  return "Not tested"
        case .testing:   return "Testing…"
        case .success(let name):
            if let name, !name.isEmpty {
                return "Connected — \(name)"
            }
            return "Connected"
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

// MARK: - ResolveStatus

private enum ResolveStatus: Equatable {
    case idle
    case resolving
    case resolved(name: String)
    case failed(String)
}

// MARK: - APISettingsView

struct APISettingsView: View {

    @Bindable var apiSettings: APISettings

    @State private var connectionStatus: ConnectionStatus = .untested
    @State private var showClearConfirmation = false
    @State private var shareLink: String = ""
    @State private var resolveStatus: ResolveStatus = .idle

    var body: some View {
        Form {
            Section("Notion Integration") {
                SecureField("内部インテグレーションシークレット (ntn_…)", text: $apiSettings.token)
                    .textContentType(.password)
                    .onChange(of: apiSettings.token) { _, _ in
                        connectionStatus = .untested
                        resolveStatus = .idle
                    }

                TextField("Data Source ID", text: $apiSettings.dataSourceId)
                    .onChange(of: apiSettings.dataSourceId) { _, _ in
                        connectionStatus = .untested
                    }
            }

            Section("共有リンクから Data Source ID を取得") {
                TextField("https://notion.so/… を貼り付け", text: $shareLink)
                    .textContentType(.URL)
                    .onChange(of: shareLink) { _, _ in
                        resolveStatus = .idle
                    }

                HStack {
                    Button("取得") {
                        resolveShareLink()
                    }
                    .disabled(
                        apiSettings.token.isEmpty ||
                        shareLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        resolveStatus == .resolving
                    )

                    Spacer()

                    switch resolveStatus {
                    case .idle:
                        EmptyView()
                    case .resolving:
                        ProgressView()
                            .controlSize(.small)
                    case .resolved(let name):
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
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

            Section {
                Button("資格情報を削除", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(apiSettings.token.isEmpty && apiSettings.dataSourceId.isEmpty)
                .confirmationDialog(
                    "保存済みのAPIトークンとData Source IDを削除しますか？",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("削除", role: .destructive) {
                        apiSettings.clearCredentials()
                        connectionStatus = .untested
                    }
                }
            }

            Section {
                DisclosureGroup("キーチェーンについて") {
                    VStack(alignment: .leading, spacing: 12) {
                        keychainInfoRow(
                            icon: "questionmark.circle",
                            title: "なぜシステムがパスワードを求めるのか",
                            body: "ToukanはAPIトークンの安全な保管にmacOS標準のキーチェーンを使用します。初回アクセス時やアプリの署名が変わった際に、macOSがアクセス許可を確認するダイアログを表示することがあります。これはmacOSのセキュリティ機構による正常な動作です。"
                        )

                        keychainInfoRow(
                            icon: "lock.shield",
                            title: "何を使い、何の目的か",
                            body: "macOSキーチェーン（システム標準の暗号化された資格情報保管庫）にAPIトークンを保存します。キーチェーンに保存されたデータはmacOSにより暗号化され、Toukanのみがアクセスできます。"
                        )

                        keychainInfoRow(
                            icon: "xmark.shield",
                            title: "何をしないか",
                            body: "APIトークンを外部サーバーに送信しません（Notion APIへの通信のみ）。他のアプリのキーチェーン項目にアクセスしません。Data Source IDは機密情報ではないため、キーチェーンではなく設定値として保存します。"
                        )
                    }
                    .padding(.vertical, 4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func keychainInfoRow(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        switch connectionStatus {
        case .untested:  return "circle"
        case .testing:   return "clock"
        case .success:   return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private func resolveShareLink() {
        resolveStatus = .resolving
        let input = shareLink.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let databaseId = Self.extractDatabaseId(from: input) else {
            resolveStatus = .failed("リンクからIDを抽出できません")
            return
        }

        let token = apiSettings.token
        Task { @MainActor in
            do {
                let db = try await NotionAPIClient(token: token).fetchDatabase(databaseId: databaseId)
                guard let ds = db.dataSources.first else {
                    resolveStatus = .failed("Data Source が見つかりません")
                    return
                }
                apiSettings.dataSourceId = ds.id
                resolveStatus = .resolved(name: ds.name ?? db.databaseName)
            } catch {
                resolveStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Extracts a Notion database ID (UUID) from a share link or raw ID string.
    private static func extractDatabaseId(from input: String) -> String? {
        // Already a UUID with dashes
        if input.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return input.lowercased()
        }

        // 32 hex chars without dashes
        if input.range(of: #"^[0-9a-f]{32}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return formatAsUUID(input.lowercased())
        }

        // Notion share URL — extract 32 hex chars from last path component
        guard let url = URL(string: input),
              let host = url.host,
              host.contains("notion") else {
            return nil
        }
        let lastComponent = url.lastPathComponent
        guard let match = lastComponent.range(
            of: #"[0-9a-f]{32}"#,
            options: [.regularExpression, .caseInsensitive, .backwards]
        ) else {
            return nil
        }
        return formatAsUUID(String(lastComponent[match]).lowercased())
    }

    private static func formatAsUUID(_ hex: String) -> String {
        let h = Array(hex)
        return [
            String(h[0..<8]),
            String(h[8..<12]),
            String(h[12..<16]),
            String(h[16..<20]),
            String(h[20..<32]),
        ].joined(separator: "-")
    }

    private func runConnectionTest() {
        connectionStatus = .testing
        let token = apiSettings.token
        let dataSourceId = apiSettings.dataSourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let client = NotionAPIClient(token: token)
                _ = try await client.testConnection()

                if !dataSourceId.isEmpty {
                    let name = try await client.fetchDataSourceName(dataSourceId: dataSourceId)
                    connectionStatus = .success(databaseName: name)
                } else {
                    connectionStatus = .success(databaseName: nil)
                }
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - SyncTargetsSettingsView

struct SyncTargetsSettingsView: View {

    var bookmarkManager: BookmarkManager

    var body: some View {
        Form {
            Section("同期ディレクトリ") {
                if bookmarkManager.targets.isEmpty {
                    Text("ディレクトリが追加されていません")
                        .foregroundStyle(.secondary)
                } else {
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
                            Button("削除") {
                                bookmarkManager.removeTarget(target)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Button("ディレクトリを追加…") {
                    _ = bookmarkManager.addDirectory()
                }
            }
        }
        .formStyle(.grouped)
    }
}
