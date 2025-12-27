#!/usr/bin/env python3
"""
NotionSync - MDファイル自動保存スクリプト
指定ディレクトリのmdファイルをNotionに保存し、元ファイルを削除
"""

import os
import sys
import time
import logging
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from notion_client import Client

# ログ設定
log_dir = Path.home() / "Library" / "Logs" / "NotionSync"
log_dir.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_dir / "notion_sync.log"),
        logging.StreamHandler()
    ]
)

# 環境変数から設定を取得
NOTION_TOKEN = os.environ.get("NOTION_TOKEN")
DATABASE_ID = os.environ.get("NOTION_DATABASE_ID")
WATCH_DIR = os.environ.get("WATCH_DIR", str(Path.cwd()))

if not NOTION_TOKEN:
    logging.error("環境変数 NOTION_TOKEN が設定されていません")
    sys.exit(1)

if not DATABASE_ID:
    logging.error("環境変数 NOTION_DATABASE_ID が設定されていません")
    sys.exit(1)

# Notion クライアント初期化（API バージョン 2025-09-03 を使用）
notion = Client(auth=NOTION_TOKEN, notion_version="2025-09-03")


class MarkdownHandler(FileSystemEventHandler):
    """Markdownファイルの作成を監視"""

    def on_created(self, event):
        if event.is_directory:
            return

        file_path = Path(event.src_path)

        # .mdファイルのみ処理
        if file_path.suffix.lower() == '.md':
            logging.info(f"新しいMDファイルを検出: {file_path.name}")
            # ファイルの書き込みが完了するまで少し待機
            time.sleep(0.5)
            self.process_markdown(file_path)

    def process_markdown(self, file_path: Path):
        """MarkdownファイルをNotionに保存し、元ファイルを削除"""
        try:
            # ファイル読み込み
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()

            # タイトル取得（ファイル名から拡張子を除く）
            title = file_path.stem

            # Notionページ作成（data_source_id を使用）
            page = notion.pages.create(
                parent={"data_source_id": DATABASE_ID},
                properties={
                    "Name": {
                        "title": [
                            {
                                "text": {
                                    "content": title
                                }
                            }
                        ]
                    }
                },
                children=self.markdown_to_blocks(content)
            )

            logging.info(f"Notionに保存成功: {title}")
            logging.info(f"Page URL: https://notion.so/{page['id'].replace('-', '')}")

            # 元ファイル削除
            file_path.unlink()
            logging.info(f"元ファイル削除: {file_path.name}")

        except Exception as e:
            logging.error(f"処理エラー ({file_path.name}): {str(e)}")

    def markdown_to_blocks(self, content: str) -> list:
        """MarkdownをNotionブロックに変換（シンプル版）"""
        if not content.strip():
            return []

        blocks = []
        lines = content.split('\n')

        current_paragraph = []

        for line in lines:
            line = line.rstrip()

            # 見出し
            if line.startswith('# '):
                if current_paragraph:
                    blocks.append(self.create_paragraph_block('\n'.join(current_paragraph)))
                    current_paragraph = []
                blocks.append({
                    "object": "block",
                    "type": "heading_1",
                    "heading_1": {
                        "rich_text": [{"type": "text", "text": {"content": line[2:]}}]
                    }
                })
            elif line.startswith('## '):
                if current_paragraph:
                    blocks.append(self.create_paragraph_block('\n'.join(current_paragraph)))
                    current_paragraph = []
                blocks.append({
                    "object": "block",
                    "type": "heading_2",
                    "heading_2": {
                        "rich_text": [{"type": "text", "text": {"content": line[3:]}}]
                    }
                })
            elif line.startswith('### '):
                if current_paragraph:
                    blocks.append(self.create_paragraph_block('\n'.join(current_paragraph)))
                    current_paragraph = []
                blocks.append({
                    "object": "block",
                    "type": "heading_3",
                    "heading_3": {
                        "rich_text": [{"type": "text", "text": {"content": line[4:]}}]
                    }
                })
            # 空行
            elif not line:
                if current_paragraph:
                    blocks.append(self.create_paragraph_block('\n'.join(current_paragraph)))
                    current_paragraph = []
            # 通常のテキスト
            else:
                current_paragraph.append(line)

        # 最後の段落を追加
        if current_paragraph:
            blocks.append(self.create_paragraph_block('\n'.join(current_paragraph)))

        return blocks

    def create_paragraph_block(self, text: str) -> dict:
        """段落ブロック作成"""
        # Notion APIの制限: rich_textは2000文字まで
        if len(text) > 2000:
            text = text[:1997] + "..."

        return {
            "object": "block",
            "type": "paragraph",
            "paragraph": {
                "rich_text": [{"type": "text", "text": {"content": text}}]
            }
        }


def main():
    """メイン処理"""
    logging.info("NotionSync 起動")
    logging.info(f"監視ディレクトリ: {WATCH_DIR}")

    # ディレクトリ存在確認
    watch_path = Path(WATCH_DIR)
    if not watch_path.exists():
        logging.error(f"監視ディレクトリが存在しません: {WATCH_DIR}")
        sys.exit(1)

    # 監視開始
    event_handler = MarkdownHandler()
    observer = Observer()
    observer.schedule(event_handler, WATCH_DIR, recursive=False)
    observer.start()

    logging.info("監視開始 (Ctrl+C で終了)")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
        logging.info("監視終了")

    observer.join()


if __name__ == "__main__":
    main()
