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

echo ""
echo "設定内容:"
echo "  Python: $PYTHON_PATH"
echo "  スクリプトディレクトリ: $SCRIPT_DIR"
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
sed -e "s|{{USERNAME}}|$USERNAME|g" \
    -e "s|{{PYTHON_PATH}}|$PYTHON_PATH|g" \
    -e "s|{{SCRIPT_PATH}}|$SCRIPT_DIR|g" \
    -e "s|{{NOTION_TOKEN}}|$NOTION_TOKEN|g" \
    -e "s|{{NOTION_DATABASE_ID}}|$NOTION_DATABASE_ID|g" \
    -e "s|{{HOME}}|$HOME_DIR|g" \
    "$PLIST_TEMPLATE" > "$PLIST_FILE"

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
echo "【動作確認】"
echo "sync_targets.json を編集して監視ディレクトリを設定してください。"
echo "参考: $SCRIPT_DIR/sync_targets.json.example"
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
