# Toukan (投函)

macOS メニューバー常駐アプリ。ローカルディレクトリを監視し、新しい `.md` ファイルを自動的に Notion データベースへ投函します。

AI 開発で大量に生成される Markdown ファイルを、Notion のシンプルなビューワーで確認・管理するための補助ツールです。

## 特徴

- **ディレクトリ監視 → 自動アップロード**: `.md` ファイルを保存するだけで Notion に反映
- **一方通行 (by design)**: ローカル = エディタ、Notion = ビューワー。双方向同期の複雑さなし
- **ネイティブ Swift/SwiftUI**: Electron なし、ランタイム依存なし、省メモリ・省電力
- **App Sandbox 対応**: Security-Scoped Bookmarks + Keychain + SMAppService
- **Notion REST API 直接通信**: MCP 非依存、Integration Token のみで動作

## セットアップ

1. Settings → API タブで Notion Integration Token と Data Source ID を入力
2. Settings → Sync Targets タブで監視ディレクトリを追加
3. Start をクリック

## アーキテクチャ

```
[ローカル .md ファイル]
     │ 保存
     ▼
[DirectoryWatcher] (kqueue / DispatchSource)
     │ 検出
     ▼
[SyncEngine]
     ├─ MarkdownParser  → Notion blocks へ変換
     ├─ NotionAPIClient → POST /v1/pages
     └─ archived/ へ移動
```

## 技術スタック

| 項目 | 選定 |
|---|---|
| 言語 | Swift 6.0 (strict concurrency) |
| UI | SwiftUI + MenuBarExtra |
| ファイル監視 | DispatchSource (kqueue) |
| HTTP | URLSession async/await |
| 認証情報 | macOS Keychain |
| ディレクトリ永続化 | Security-Scoped Bookmarks |
| ログイン項目 | SMAppService |
| Notion API | v2025-09-03 (`data_source_id`) |
| 最小OS | macOS 14.0 (Sonoma) |

## 開発

```bash
# ビルド
xcodebuild build \
  -project Toukan/Toukan.xcodeproj \
  -scheme Toukan \
  -destination 'platform=macOS'

# テスト
xcodebuild test \
  -project Toukan/Toukan.xcodeproj \
  -scheme Toukan \
  -destination 'platform=macOS'
```

## Markdown 変換仕様

| Markdown | Notion ブロック |
|---|---|
| `# 見出し` | heading_1 |
| `## 見出し` | heading_2 |
| `### 見出し` | heading_3 |
| 通常テキスト | paragraph |

- タイトル: ファイル名 (拡張子除く)
- 各ブロック 2000 文字制限 (Notion API 制限)
- 処理後のファイルは `archived/` サブディレクトリへ移動
