import Foundation
import Observation

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true ? .japanese : .english
    }
}

// MARK: - LanguageManager

@Observable
@MainActor
final class LanguageManager {

    private static let key = "appLanguage"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else {
            language = .systemDefault
        }
    }

    var strings: Strings { Strings(language) }
}

// MARK: - Strings

struct Strings: Sendable {

    private let ja: Bool

    init(_ lang: AppLanguage) {
        ja = lang == .japanese
    }

    // MARK: Menu Bar

    func menuRunning(count: Int) -> String {
        ja ? "Toukan: 実行中（\(count)ディレクトリ）" : "Toukan: Running (\(count) dirs)"
    }
    var menuStopped: String { ja ? "Toukan: 停止中" : "Toukan: Stopped" }
    var lastLabel: String { ja ? "最新" : "Last" }
    var menuStop: String { ja ? "停止" : "Stop" }
    var menuStart: String { ja ? "開始" : "Start" }
    var menuSettings: String { ja ? "設定..." : "Settings..." }
    var menuQuit: String { ja ? "終了" : "Quit" }

    // MARK: Settings Tabs

    var tabGeneral: String { ja ? "一般" : "General" }
    var tabAPI: String { "API" }
    var tabSyncTargets: String { ja ? "同期先" : "Sync Targets" }

    // MARK: General Settings

    var launchAtLogin: String { ja ? "ログイン時に起動" : "Launch at Login" }
    func launchAtLoginError(_ detail: String) -> String {
        ja ? "設定に失敗しました: \(detail)" : "Failed to update setting: \(detail)"
    }
    var languageLabel: String { ja ? "言語" : "Language" }
    var aboutVersion: String { ja ? "バージョン" : "Version" }
    var aboutCopyright: String { "© 2026 Clevique" }
    var keychainSaveError: String { ja ? "キーチェーン保存エラー" : "Keychain save error" }

    // MARK: API Settings

    var notionIntegration: String { ja ? "Notion インテグレーション" : "Notion Integration" }
    var tokenPlaceholder: String {
        ja ? "内部インテグレーションシークレット (ntn_…)" : "Internal Integration Secret (ntn_…)"
    }
    var shareLinkSection: String {
        ja ? "共有リンクから Data Source ID を取得" : "Get Data Source ID from Share Link"
    }
    var shareLinkPlaceholder: String {
        ja ? "https://notion.so/… を貼り付け" : "Paste https://notion.so/… link"
    }
    var resolve: String { ja ? "取得" : "Resolve" }
    var testConnection: String { ja ? "接続テスト" : "Test Connection" }
    var enterDataSourceIdFirst: String {
        ja ? "先に Data Source ID を入力してください" : "Enter Data Source ID first."
    }
    var deleteCredentials: String { ja ? "資格情報を削除" : "Delete Credentials" }
    var deleteCredentialsConfirm: String {
        ja ? "保存済みのAPIトークンとData Source IDを削除しますか？"
           : "Delete saved API token and Data Source ID?"
    }
    var delete: String { ja ? "削除" : "Delete" }

    // MARK: Keychain Info

    var aboutKeychain: String { ja ? "キーチェーンについて" : "About Keychain" }
    var keychainWhyTitle: String {
        ja ? "なぜシステムがパスワードを求めるのか" : "Why the system asks for your password"
    }
    var keychainWhyBody: String {
        ja ? "ToukanはAPIトークンの安全な保管にmacOS標準のキーチェーンを使用します。初回アクセス時やアプリの署名が変わった際に、macOSがアクセス許可を確認するダイアログを表示することがあります。これはmacOSのセキュリティ機構による正常な動作です。"
           : "Toukan uses the macOS Keychain to securely store your API token. On first access or when the app signature changes, macOS may display a dialog asking for permission. This is normal behavior from the macOS security system."
    }
    var keychainWhatTitle: String {
        ja ? "何を使い、何の目的か" : "What it uses and why"
    }
    var keychainWhatBody: String {
        ja ? "macOSキーチェーン（システム標準の暗号化された資格情報保管庫）にAPIトークンを保存します。キーチェーンに保存されたデータはmacOSにより暗号化され、Toukanのみがアクセスできます。"
           : "Your API token is stored in the macOS Keychain — the system's built-in encrypted credential store. Data in the Keychain is encrypted by macOS and accessible only to Toukan."
    }
    var keychainNotTitle: String {
        ja ? "何をしないか" : "What it doesn't do"
    }
    var keychainNotBody: String {
        ja ? "APIトークンを外部サーバーに送信しません（Notion APIへの通信のみ）。他のアプリのキーチェーン項目にアクセスしません。Data Source IDは機密情報ではないため、キーチェーンではなく設定値として保存します。"
           : "Your API token is never sent to external servers (only to the Notion API). Toukan does not access other apps' Keychain items. The Data Source ID is not sensitive, so it is stored as a preference rather than in the Keychain."
    }

    // MARK: Connection Status

    var statusNotTested: String { ja ? "未テスト" : "Not tested" }
    var statusTesting: String { ja ? "テスト中…" : "Testing…" }
    func statusConnected(name: String?) -> String {
        if let name, !name.isEmpty {
            return ja ? "接続済み — \(name)" : "Connected — \(name)"
        }
        return ja ? "接続済み" : "Connected"
    }
    func statusFailed(message: String) -> String {
        ja ? "失敗: \(message)" : "Failed: \(message)"
    }

    // MARK: Resolve Status

    var resolveCannotExtract: String {
        ja ? "リンクからIDを抽出できません" : "Could not extract ID from link"
    }
    var resolveNoDataSource: String {
        ja ? "Data Source が見つかりません" : "No Data Source found"
    }

    // MARK: Sync Targets

    var syncDirectories: String { ja ? "同期ディレクトリ" : "Sync Directories" }
    var noDirectoriesAdded: String {
        ja ? "ディレクトリが追加されていません" : "No directories added"
    }
    var addDirectory: String { ja ? "ディレクトリを追加…" : "Add Directory…" }
    var howSyncWorksTitle: String { ja ? "同期の仕組み" : "How Sync Works" }
    var howSyncWorksBody: String {
        ja ? "ディレクトリ直下の .md ファイルのみが Notion に連携されます。サブディレクトリ内のファイルや .md 以外のファイルは無視されます。連携済みのファイルはアーカイブ先に自動で移動されるため、再アップロードされることはありません。"
           : "Only .md files at the top level of the directory are synced to Notion. Files in subdirectories and non-.md files are ignored. Synced files are automatically moved to the archive folder, preventing re-upload."
    }

    // MARK: Sync Target Row

    var remove: String { ja ? "削除" : "Remove" }
    var archiveTo: String { ja ? "アーカイブ先:" : "Archive to:" }
    var directoryExists: String { ja ? "ディレクトリが存在します" : "Directory exists" }
    var create: String { ja ? "作成" : "Create" }
    func createFailed(error: String) -> String {
        ja ? "作成失敗: \(error)" : "Creation failed: \(error)"
    }
}
