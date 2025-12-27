# NotionSync

MacのローカルディレクトリにMarkdownファイルが追加されると、自動的にNotionに保存して元ファイルを削除するシステムです。

## 特徴

- 📁 指定ディレクトリのMarkdownファイルを自動検出
- 🚀 Notionに自動保存（Notion API 2025-09-03 対応）
- 🗑️ 保存後、元ファイルを自動削除
- 🔄 macOS起動時に自動起動（LaunchAgent）
- 📝 ログ出力で動作状況を確認可能

## 必要要件

- macOS（LaunchAgentを使用）
- Python 3.7以上
- Notion Integration Token
- Notionデータベース

## セットアップ

### 1. リポジトリのクローン

```bash
git clone https://github.com/yourusername/NotionSync.git
cd NotionSync
```

### 2. Notion Integrationの作成

1. [Notion Integrations](https://www.notion.so/my-integrations) にアクセス
2. 「New integration」をクリック
3. Integration名を入力して作成
4. 「Internal Integration Token」をコピー（後で使用）

### 3. Notionデータベースの準備

1. Notionでデータベースを作成（または既存のデータベースを使用）
2. データベースに以下のプロパティが必要：
   - `Name` (Title型) - ページタイトル用
3. データベースURLから Database ID を取得:
   ```
   https://notion.so/{workspace}/{database_id}?v=...
   ```
4. データベースの右上「•••」→「接続を追加」→ 作成したIntegrationを選択

### 4. セットアップスクリプトの実行

```bash
chmod +x setup.sh
./setup.sh
```

セットアップ中に以下の情報を入力します：

- **Notion Integration Token**: 手順2でコピーしたトークン
- **Notion Database ID**: 手順3で取得したID
- **監視ディレクトリ**: Markdownファイルを監視するディレクトリ（デフォルト: プロジェクトディレクトリ）

### 5. 動作確認

テストファイルを作成して動作を確認:

```bash
echo -e "# テストページ\\n\\nこれはテストです。" > /path/to/watch/directory/test.md
```

数秒後、Notionにページが作成され、`test.md`が削除されます。

## 使い方

監視ディレクトリにMarkdownファイルを保存するだけです:

```bash
# ファイルを作成
vim /path/to/watch/directory/メモ.md

# または他の場所から移動
mv ~/Downloads/資料.md /path/to/watch/directory/
```

## ログ確認

```bash
# リアルタイムでログを確認
tail -f ~/Library/Logs/NotionSync/notion_sync.log

# 標準出力/エラー出力
tail -f ~/Library/Logs/NotionSync/stdout.log
tail -f ~/Library/Logs/NotionSync/stderr.log
```

## サービス管理

### 状態確認

```bash
launchctl list | grep notionsync
```

### 停止

```bash
launchctl unload ~/Library/LaunchAgents/com.$(whoami).notionsync.plist
```

### 再起動

```bash
launchctl unload ~/Library/LaunchAgents/com.$(whoami).notionsync.plist
launchctl load ~/Library/LaunchAgents/com.$(whoami).notionsync.plist
```

### アンインストール

```bash
launchctl unload ~/Library/LaunchAgents/com.$(whoami).notionsync.plist
rm ~/Library/LaunchAgents/com.$(whoami).notionsync.plist
rm -rf ~/Library/Logs/NotionSync
```

## トラブルシューティング

### mdファイルが削除されない

1. ログを確認: `tail -f ~/Library/Logs/NotionSync/notion_sync.log`
2. エラーメッセージを確認
3. Notion APIキーとDatabase IDが正しいか確認
4. データベースがIntegrationと共有されているか確認

### サービスが起動しない

```bash
# 手動実行でエラーを確認
cd /path/to/NotionSync
export NOTION_TOKEN="your_token"
export NOTION_DATABASE_ID="your_database_id"
export WATCH_DIR="/path/to/watch"
python3 notion_sync.py
```

### Python3のパスが異なる場合

```bash
# Python3のパスを確認
which python3

# セットアップスクリプトを再実行
./setup.sh
```

## 仕様

- **対応形式**: `.md`ファイルのみ
- **タイトル**: ファイル名（拡張子除く）
- **内容変換**:
  - `#` → Heading 1
  - `##` → Heading 2
  - `###` → Heading 3
  - その他 → Paragraph
- **文字数制限**: 各ブロック2000文字（Notion API制限）
- **API バージョン**: Notion API 2025-09-03

## プロジェクト構成

```
NotionSync/
├── notion_sync.py                  # メインスクリプト
├── com.bon.notionsync.plist.template  # LaunchAgent設定テンプレート
├── setup.sh                        # セットアップスクリプト
├── .env.example                    # 環境変数サンプル
├── .gitignore                      # Git除外設定
└── README.md                       # このファイル
```

## セキュリティ

- Notion APIトークンは `.gitignore` で除外されています
- LaunchAgent設定ファイル（`.plist`）も除外対象です
- 公開リポジトリに秘匿情報を含めないよう注意してください

## ライセンス

MIT License

## 貢献

Issue や Pull Request を歓迎します！

## 注意事項

- macOS再起動時に自動起動します
- 大きなファイル（長いMarkdown）は処理に時間がかかる場合があります
- 複雑なMarkdown記法（テーブル、コードブロックなど）は簡易変換されます
- Notion API 2025-09-03 を使用しているため、`data_source` として扱われます
