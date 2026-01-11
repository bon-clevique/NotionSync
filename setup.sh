#!/bin/bash

set -e  # エラーが発生したら即座に終了

echo "===================================="
echo "NotionSync セットアップスクリプト"
echo "===================================="
echo ""

# 現在のディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERNAME=$(whoami)
HOME_DIR="$HOME"

# Python3のパス確認
PYTHON_PATH=$(which python3)
if [ -z "$PYTHON_PATH" ]; then
    echo "❌ Error: python3 が見つかりません"
    exit 1
fi

echo "Python3のパス: $PYTHON_PATH"
echo ""

# 必要なパッケージの確認
echo "必要なパッケージを確認中..."
python3 -c "import watchdog" 2>/dev/null || {
    echo "⚠️  watchdog がインストールされていません"
    echo "インストールしますか? (y/n)"
    read -r response
    if [ "$response" = "y" ]; then
        pip3 install watchdog
    else
        echo "❌ watchdog が必要です。セットアップを中断します。"
        exit 1
    fi
}

python3 -c "import notion_client" 2>/dev/null || {
    echo "⚠️  notion-client がインストールされていません"
    echo "インストールしますか? (y/n)"
    read -r response
    if [ "$response" = "y" ]; then
        pip3 install notion-client
    else
        echo "❌ notion-client が必要です。セットアップを中断します。"
        exit 1
    fi
}

echo "✓ 必要なパッケージがインストールされています"
echo ""

# Notion APIキーの入力
echo "Notion Integration Token を入力してください:"
echo "(https://www.notion.so/my-integrations で作成できます)"
read -rs NOTION_TOKEN
echo ""

if [ -z "$NOTION_TOKEN" ]; then
    echo "❌ Error: Notion Token が入力されていません"
    exit 1
fi

# Notion Database IDの入力
echo "Notion Database ID を入力してください:"
echo "(データベースURLの https://notion.so/{workspace}/{database_id}?v=... の部分)"
read -r NOTION_DATABASE_ID
echo ""

if [ -z "$NOTION_DATABASE_ID" ]; then
    echo "❌ Error: Database ID が入力されていません"
    exit 1
fi

# 監視ディレクトリの設定
echo "監視するディレクトリのパスを入力してください:"
echo "(デフォルト: スクリプトディレクトリ $SCRIPT_DIR)"
echo "(空Enter: スクリプトディレクトリを使用)"
echo "(複数指定: カンマ区切り 例: /path/to/dir1,/path/to/dir2)"
read -r WATCH_DIR

if [ -z "$WATCH_DIR" ] || [ "$WATCH_DIR" = "$SCRIPT_DIR" ]; then
    echo "WATCH_DIR環境変数を設定しません（スクリプトディレクトリを監視）"
    USE_WATCH_DIR_ENV=false
else
    echo "WATCH_DIR環境変数を設定します: $WATCH_DIR"
    USE_WATCH_DIR_ENV=true
fi

echo ""
echo "設定内容:"
echo "  Python: $PYTHON_PATH"
echo "  スクリプトディレクトリ: $SCRIPT_DIR"
if [ "$USE_WATCH_DIR_ENV" = true ]; then
    echo "  監視ディレクトリ: $WATCH_DIR (環境変数で設定)"
else
    echo "  監視ディレクトリ: $SCRIPT_DIR (スクリプトディレクトリ)"
fi
echo "  Database ID: $NOTION_DATABASE_ID"
echo ""

# plistファイルの生成
PLIST_TEMPLATE="$SCRIPT_DIR/com.bon.notionsync.plist.template"
PLIST_FILE="$HOME_DIR/Library/LaunchAgents/com.$USERNAME.notionsync.plist"

if [ ! -f "$PLIST_TEMPLATE" ]; then
    echo "❌ Error: テンプレートファイルが見つかりません: $PLIST_TEMPLATE"
    exit 1
fi

# LaunchAgentsディレクトリ作成
mkdir -p "$HOME_DIR/Library/LaunchAgents"

# テンプレートから plist を生成
if [ "$USE_WATCH_DIR_ENV" = true ]; then
    # WATCH_DIRを環境変数に追加
    WATCH_DIR_ENTRY="<key>WATCH_DIR</key>
        <string>$WATCH_DIR</string>"
    sed -e "s|{{USERNAME}}|$USERNAME|g" \
        -e "s|{{PYTHON_PATH}}|$PYTHON_PATH|g" \
        -e "s|{{SCRIPT_PATH}}|$SCRIPT_DIR|g" \
        -e "s|{{NOTION_TOKEN}}|$NOTION_TOKEN|g" \
        -e "s|{{NOTION_DATABASE_ID}}|$NOTION_DATABASE_ID|g" \
        -e "s|{{WATCH_DIR_ENTRY}}|$WATCH_DIR_ENTRY|g" \
        -e "s|{{HOME}}|$HOME_DIR|g" \
        "$PLIST_TEMPLATE" > "$PLIST_FILE"
else
    # WATCH_DIR環境変数を含めない
    sed -e "s|{{USERNAME}}|$USERNAME|g" \
        -e "s|{{PYTHON_PATH}}|$PYTHON_PATH|g" \
        -e "s|{{SCRIPT_PATH}}|$SCRIPT_DIR|g" \
        -e "s|{{NOTION_TOKEN}}|$NOTION_TOKEN|g" \
        -e "s|{{NOTION_DATABASE_ID}}|$NOTION_DATABASE_ID|g" \
        -e "s|{{WATCH_DIR_ENTRY}}||g" \
        -e "s|{{HOME}}|$HOME_DIR|g" \
        "$PLIST_TEMPLATE" > "$PLIST_FILE"
fi

echo "✓ LaunchAgent設定ファイルを作成しました"

# スクリプトに実行権限付与
chmod +x "$SCRIPT_DIR/notion_sync.py"
echo "✓ 実行権限を付与しました"

# ログディレクトリ作成
mkdir -p "$HOME_DIR/Library/Logs/NotionSync"
echo "✓ ログディレクトリを作成しました"

# LaunchAgent読み込み
launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE"
echo "✓ LaunchAgentを読み込みました"

echo ""
echo "===================================="
echo "セットアップ完了！"
echo "===================================="
echo ""
if [ "$USE_WATCH_DIR_ENV" = true ]; then
    echo "監視ディレクトリ: $WATCH_DIR"
    echo "【動作確認】"
    echo "以下のコマンドでテストMDファイルを作成できます:"
    echo "echo \"# テスト\\n\\nこれはテストです。\" > \"$WATCH_DIR/test.md\""
else
    echo "監視ディレクトリ: $SCRIPT_DIR (スクリプトディレクトリ)"
    echo "【動作確認】"
    echo "以下のコマンドでテストMDファイルを作成できます:"
    echo "echo \"# テスト\\n\\nこれはテストです。\" > \"$SCRIPT_DIR/test.md\""
fi
echo "ログファイル: $HOME_DIR/Library/Logs/NotionSync/notion_sync.log"
echo ""
echo ""
echo "【ログ確認】"
echo "tail -f $HOME_DIR/Library/Logs/NotionSync/notion_sync.log"
echo ""
echo "【停止方法】"
echo "launchctl unload $PLIST_FILE"
echo ""
echo "【再起動方法】"
echo "launchctl unload $PLIST_FILE && launchctl load $PLIST_FILE"
echo ""
