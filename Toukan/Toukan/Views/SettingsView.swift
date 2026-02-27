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
            keychainError = nil
            if token.isEmpty {
                KeychainManager.delete(key: Self.tokenKey)
            } else {
                do {
                    try KeychainManager.save(key: Self.tokenKey, value: token)
                } catch {
                    keychainError = error.localizedDescription
                }
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
    private(set) var keychainError: String?

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

    /// Resolves a Notion share link to a data source ID.
    /// - Parameter input: A share link URL or raw database ID string.
    /// - Returns: The display name of the resolved data source.
    func resolveShareLink(input: String) async throws -> String {
        guard let databaseId = NotionURLParser.extractDatabaseId(from: input) else {
            throw NotionAPIError.validationError(message: "Could not extract database ID from input")
        }
        let db = try await NotionAPIClient(token: token).fetchDatabase(databaseId: databaseId)
        guard let ds = db.dataSources.first else {
            throw NotionAPIError.notFound
        }
        dataSourceId = ds.id
        return ds.name ?? db.databaseName
    }

    /// Tests the connection by fetching the data source name.
    /// - Returns: The data source name on success.
    func testConnection() async throws -> String {
        let id = dataSourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await NotionAPIClient(token: token).fetchDataSourceName(dataSourceId: id)
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
    var languageManager: LanguageManager

    private var strings: Strings { languageManager.strings }

    var body: some View {
        TabView {
            GeneralSettingsView(languageManager: languageManager)
                .tabItem { Label(strings.tabGeneral, systemImage: "gear") }

            APISettingsView(apiSettings: apiSettings, languageManager: languageManager)
                .tabItem { Label(strings.tabAPI, systemImage: "key") }

            SyncTargetsSettingsView(bookmarkManager: bookmarkManager, languageManager: languageManager)
                .tabItem { Label(strings.tabSyncTargets, systemImage: "folder") }
        }
        .frame(width: 480, height: 520)
        .onAppear {
            NSApp.activate()
        }
    }
}

// MARK: - GeneralSettingsView

struct GeneralSettingsView: View {

    @Bindable var languageManager: LanguageManager
    @State private var launchAtLoginError: String?

    private var strings: Strings { languageManager.strings }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle(strings.launchAtLogin, isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { toggleLaunchAtLogin($0) }
                ))

                if let error = launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker(strings.languageLabel, selection: $languageManager.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("Toukan")
                        .font(.headline)
                    Text("\(strings.aboutVersion) \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(strings.aboutCopyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        launchAtLoginError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = strings.launchAtLoginError(error.localizedDescription)
        }
    }
}

// MARK: - ConnectionStatus

private enum ConnectionStatus: Equatable {
    case untested
    case testing
    case success(databaseName: String?)
    case failed(String)

    func label(_ strings: Strings) -> String {
        switch self {
        case .untested:  return strings.statusNotTested
        case .testing:   return strings.statusTesting
        case .success(let name): return strings.statusConnected(name: name)
        case .failed(let msg): return strings.statusFailed(message: msg)
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
    var languageManager: LanguageManager

    @State private var connectionStatus: ConnectionStatus = .untested
    @State private var showClearConfirmation = false
    @State private var shareLink: String = ""
    @State private var resolveStatus: ResolveStatus = .idle

    private var strings: Strings { languageManager.strings }

    var body: some View {
        Form {
            Section(strings.notionIntegration) {
                SecureField(strings.tokenPlaceholder, text: $apiSettings.token)
                    .textContentType(.password)
                    .onChange(of: apiSettings.token) { _, _ in
                        connectionStatus = .untested
                        resolveStatus = .idle
                    }

                if let error = apiSettings.keychainError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("Data Source ID", text: $apiSettings.dataSourceId)
                    .onChange(of: apiSettings.dataSourceId) { _, _ in
                        connectionStatus = .untested
                    }
            }

            Section(strings.shareLinkSection) {
                TextField(strings.shareLinkPlaceholder, text: $shareLink)
                    .textContentType(.URL)
                    .onChange(of: shareLink) { _, _ in
                        resolveStatus = .idle
                    }

                HStack {
                    Button(strings.resolve) {
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
                    Button(strings.testConnection) {
                        runConnectionTest()
                    }
                    .disabled(
                        apiSettings.token.isEmpty ||
                        apiSettings.dataSourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        connectionStatus == .testing
                    )

                    Spacer()

                    if connectionStatus != .untested {
                        Label(connectionStatus.label(strings), systemImage: statusIcon)
                            .foregroundStyle(connectionStatus.color)
                            .font(.callout)
                    }
                }
            }

            Section {
                Button(strings.deleteCredentials, role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(apiSettings.token.isEmpty && apiSettings.dataSourceId.isEmpty)
                .confirmationDialog(
                    strings.deleteCredentialsConfirm,
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(strings.delete, role: .destructive) {
                        apiSettings.clearCredentials()
                        connectionStatus = .untested
                    }
                }
            }

            Section {
                DisclosureGroup(strings.aboutKeychain) {
                    VStack(alignment: .leading, spacing: 12) {
                        keychainInfoRow(
                            icon: "questionmark.circle",
                            title: strings.keychainWhyTitle,
                            body: strings.keychainWhyBody
                        )

                        keychainInfoRow(
                            icon: "lock.shield",
                            title: strings.keychainWhatTitle,
                            body: strings.keychainWhatBody
                        )

                        keychainInfoRow(
                            icon: "xmark.shield",
                            title: strings.keychainNotTitle,
                            body: strings.keychainNotBody
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

        guard NotionURLParser.extractDatabaseId(from: input) != nil else {
            resolveStatus = .failed(strings.resolveCannotExtract)
            return
        }

        Task { @MainActor in
            do {
                let name = try await apiSettings.resolveShareLink(input: input)
                resolveStatus = .resolved(name: name)
            } catch {
                resolveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func runConnectionTest() {
        guard !apiSettings.dataSourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionStatus = .failed(strings.enterDataSourceIdFirst)
            return
        }

        connectionStatus = .testing
        Task {
            do {
                let name = try await apiSettings.testConnection()
                connectionStatus = .success(databaseName: name)
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - SyncTargetsSettingsView

struct SyncTargetsSettingsView: View {

    var bookmarkManager: BookmarkManager
    var languageManager: LanguageManager

    private var strings: Strings { languageManager.strings }

    var body: some View {
        Form {
            Section(strings.syncDirectories) {
                if bookmarkManager.targets.isEmpty {
                    Text(strings.noDirectoriesAdded)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarkManager.targets) { target in
                        SyncTargetRow(target: target, bookmarkManager: bookmarkManager, languageManager: languageManager)
                    }
                }

                Button(strings.addDirectory) {
                    _ = bookmarkManager.addDirectory()
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(strings.howSyncWorksTitle, systemImage: "info.circle")
                        .font(.callout.weight(.medium))
                    Text(strings.howSyncWorksBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - SyncTargetRow

private struct SyncTargetRow: View {

    let target: SyncTarget
    var bookmarkManager: BookmarkManager
    var languageManager: LanguageManager

    @State private var archiveDirName: String = ""
    @State private var archiveDirExists: Bool? = nil
    @State private var createError: String? = nil

    private var strings: Strings { languageManager.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: name + delete
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
                Button(strings.remove) {
                    bookmarkManager.removeTarget(target)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }

            // Archive directory
            HStack(spacing: 6) {
                Text(strings.archiveTo)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("archived", text: $archiveDirName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 160)
                    .onSubmit { saveAndCheck() }

                if let exists = archiveDirExists {
                    if exists {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .help(strings.directoryExists)
                    } else {
                        Button(strings.create) { createArchiveDir() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            }

            if let error = createError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            archiveDirName = target.archiveDirName
            checkArchiveDirExists()
        }
        .onDisappear { saveAndCheck() }
    }

    private func saveAndCheck() {
        let sanitised = SyncTarget.sanitiseArchiveDirName(archiveDirName)
        archiveDirName = sanitised
        var updated = target
        updated.archiveDirName = sanitised
        bookmarkManager.updateTarget(updated)
        createError = nil
        checkArchiveDirExists()
    }

    private func checkArchiveDirExists() {
        guard let url = bookmarkManager.startAccessing(target) else {
            archiveDirExists = nil
            return
        }
        defer { bookmarkManager.stopAccessing(url) }
        let dirName = archiveDirName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dirName.isEmpty else {
            archiveDirExists = nil
            return
        }
        let archiveURL = url.appendingPathComponent(dirName, isDirectory: true)
        var isDir: ObjCBool = false
        archiveDirExists = FileManager.default.fileExists(atPath: archiveURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func createArchiveDir() {
        guard let url = bookmarkManager.startAccessing(target) else { return }
        defer { bookmarkManager.stopAccessing(url) }
        let dirName = SyncTarget.sanitiseArchiveDirName(archiveDirName)
        let archiveURL = url.appendingPathComponent(dirName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
            createError = nil
        } catch {
            createError = strings.createFailed(error: error.localizedDescription)
        }
        archiveDirName = dirName
        saveAndCheck()
    }
}
