# NotionSync

macOS のローカルディレクトリを監視し、Markdown ファイルが追加されると自動的に Notion の Input Warehouse データベースへ保存するデーモンです。launchd で常駐し、macOS 起動時に自動起動します。

## アーキテクチャ

```
~/Documents/NotionInput/
    └── メモ.md  ──(watchdog検出)──▶  notion_sync.py  ──(API 2025-09-03)──▶  Notion Input Warehouse
                                           │                                         │
                                    sync_targets.json                          data_source_id:
                                    (監視先+note_id)                    10219d7a-16c8-8103-a28c-f7bc29bcf6ce
                                           │
                                    保存後 archived/ へ移動
```

### 関連コンポーネント

NotionSync 以外にも、同じ Input Warehouse を操作する Claude Code スキルがあります。

| コンポーネント | 用途 | API | 実行方法 |
|---|---|---|---|
| **NotionSync** (本プロジェクト) | ディレクトリ監視→自動保存 | notion-client SDK | launchd 常駐 |
| **notion-add-note** スキル | Claude Code から直接保存 | urllib (直接HTTP) | `@notion-add-note` |
| **create-test-db** スキル | テストケース MD→ページ+インラインDB | urllib (直接HTTP) | `@create-test-db <path>` |

3つとも保存先は Input Warehouse で、Notion API 2025-09-03 の `data_source_id` を使用します。

## 技術選定

### Notion API 2025-09-03 (`data_source_id`)

2025-09-03 で `database_id` が `data_source_id` に移行されました。全コンポーネントを統一済みです。

```python
# 旧 (2022-06-28)
parent = {"database_id": "1021957a-16c8-4116-978e-87d88803770e"}

# 新 (2025-09-03)
parent = {"data_source_id": "10219d7a-16c8-8103-a28c-f7bc29bcf6ce"}
```

> **注意**: `ea60d648-178e-43e5-ac25-aaa1f754a782` はデータベースの **ページ ID** であり、`database_id` でも `data_source_id` でもありません。API の `parent` には使えません。

### NotionSync が notion-client SDK を使う理由

- `notion-client` は公式 SDK でページ作成・ブロック操作が簡潔に書ける
- NotionSync は常駐プロセスなので SDK のセッション管理が有利
- 一方、スキル側 (notion-add-note, create-test-db) は依存を最小化するため stdlib の `urllib` のみで実装

### sync_targets.json による監視先管理

環境変数 (`WATCH_DIR`) ではなく JSON ファイルで管理する設計です。

- 複数ディレクトリの監視に対応
- ディレクトリごとに `note_id` (Literature Notes ページ) を紐付け可能
- plist 再読み込みなしで監視先を変更可能

## セットアップ

### 前提条件

- macOS
- Python 3.7+ (asdf 管理)
- Notion Integration Token ([作成手順](https://www.notion.so/my-integrations))
- Input Warehouse データベースに Integration のアクセス権限を付与済み

### 自動セットアップ

```bash
cd ~/dev/NotionSync
chmod +x setup.sh
./setup.sh
```

入力項目: Notion Integration Token、Database ID (`data_source_id`)

### 手動セットアップ

```bash
# 依存インストール
pip install -r requirements.txt

# 監視先設定
cp sync_targets.json.example sync_targets.json
# sync_targets.json を編集

# plist 生成・配置
# com.bon.notionsync.plist.template を元に値を埋めて ~/Library/LaunchAgents/ へコピー

# サービス起動
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bon.notionsync.plist
```

## 設定

### 環境変数 (plist 内)

| 変数 | 用途 |
|---|---|
| `NOTION_TOKEN` | Notion Integration Token (notion-client SDK 用) |
| `NOTION_DATABASE_ID` | Input Warehouse の `data_source_id` |

> スキル側は `.zshenv` の `NOTION_API_KEY` / `NOTION_INPUT_WAREHOUSE_DATA_SOURCE_ID` を使用します。NotionSync は plist で独立管理です。

### sync_targets.json

```json
[
  {
    "directory": "/Users/bon/Documents/NotionInput",
    "note_id": null
  }
]
```

| フィールド | 必須 | 説明 |
|---|---|---|
| `directory` | Yes | 監視ディレクトリの絶対パス |
| `note_id` | No | Literature Notes のページ ID。指定すると保存時に Lit Notes リレーションを設定 |

複数エントリ可。ディレクトリが存在しない場合は自動作成されます。

## 起動・停止

### nsync コマンド（推奨）

`nsync` は launchctl コマンドをラップした管理スクリプトです。

```bash
nsync --start     # 起動
nsync --stop      # 停止
nsync --restart   # 再起動
nsync --status    # 状態確認
```

PATH を通すには、セットアップ後にシンボリックリンクを作成してください。

```bash
ln -s ~/dev/NotionSync/nsync /usr/local/bin/nsync
```

または、プロジェクトディレクトリから直接実行できます。

```bash
~/dev/NotionSync/nsync --start
```

> **注意**: `setup.sh` を実行した直後は自動的に起動されるため、手動での起動は不要です。macOS ログイン時にも自動起動します (`RunAtLoad` + `KeepAlive`)。

### 停止に関する補足

- `KeepAlive` が設定されているため、プロセスを `kill` しても launchd が自動的に再起動します。必ず `nsync --stop` で停止してください
- サービスを停止しても、plist が `~/Library/LaunchAgents/` にある限り次回ログイン時に再起動されます。自動起動を完全に無効化するには plist を削除してください:

```bash
nsync --stop
rm ~/Library/LaunchAgents/com.bon.notionsync.plist
```

再度有効にするには `setup.sh` を実行するか、手動で plist を再配置してください。

### 手動起動（デバッグ用）

launchd を介さずに直接実行することもできます。ターミナルにログが出力されるのでデバッグに便利です。

```bash
cd ~/dev/NotionSync
NOTION_TOKEN="your-token" NOTION_DATABASE_ID="your-data-source-id" python3 notion_sync.py
```

Ctrl+C で停止します。

## 使い方

監視ディレクトリに `.md` ファイルを置くだけです。

```bash
# ファイル作成
echo "テストタイトル
本文テキスト" > ~/Documents/NotionInput/test.md

# または移動
mv ~/Downloads/メモ.md ~/Documents/NotionInput/
```

保存後、元ファイルは `archived/` サブディレクトリに移動されます。

### Markdown 変換仕様

| Markdown | Notion ブロック |
|---|---|
| `# 見出し` | heading_1 |
| `## 見出し` | heading_2 |
| `### 見出し` | heading_3 |
| 通常テキスト | paragraph |
| 空行 | 段落区切り |

- タイトル: ファイル名 (拡張子除く)
- 各ブロック 2000 文字制限 (Notion API 制限)

## サービス管理（クイックリファレンス）

```bash
nsync --start     # 起動
nsync --stop      # 停止
nsync --restart   # 再起動
nsync --status    # 状態確認
```

plist を再生成する場合は `./setup.sh` を実行してください。

## ログ

```bash
# アプリケーションログ
tail -f ~/Library/Logs/NotionSync/notion_sync.log

# stdout / stderr
tail -f ~/Library/Logs/NotionSync/stdout.log
tail -f ~/Library/Logs/NotionSync/stderr.log
```

## トラブルシューティング

### ファイルが archived/ に移動しない

1. ログ確認: `tail -f ~/Library/Logs/NotionSync/notion_sync.log`
2. `NOTION_TOKEN` と `NOTION_DATABASE_ID` が plist に正しく設定されているか確認
3. Integration が Input Warehouse に接続されているか確認 (Notion 上で「接続を追加」)

### サービスが起動しない

```bash
# 手動実行でエラーを確認
NOTION_TOKEN="..." NOTION_DATABASE_ID="..." python3 ~/dev/NotionSync/notion_sync.py
```

### sync_targets.json が見つからない

スクリプトと同じディレクトリに配置してください。plist の `WorkingDirectory` が `~/dev/NotionSync` に設定されている必要があります。

### API エラー: "validation_error" / "invalid data_source_id"

`NOTION_DATABASE_ID` に正しい `data_source_id` (`10219d7a-...`) が設定されているか確認してください。旧 `database_id` (`1021957a-...`) やページ ID (`ea60d648-...`) では動作しません。

## テスト

```bash
cd ~/dev/NotionSync
python -m pytest tests/
```

## プロジェクト構成

```
NotionSync/
├── notion_sync.py                     # メインスクリプト (watchdog + notion-client)
├── sync_targets.json                  # 監視先設定 (gitignore)
├── sync_targets.json.example          # 設定サンプル
├── com.bon.notionsync.plist           # LaunchAgent 設定 (gitignore)
├── com.bon.notionsync.plist.template  # plist テンプレート
├── nsync                              # サービス管理 CLI (start/stop/restart/status)
├── setup.sh                           # セットアップスクリプト
├── requirements.txt                   # watchdog, notion-client
├── requirements-dev.txt               # テスト用依存
├── tests/                             # pytest テスト
└── docs/                              # 設計ドキュメント
```
