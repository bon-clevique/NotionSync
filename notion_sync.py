#!/usr/bin/env python3
"""
NotionSync - MDファイル自動保存スクリプト
指定ディレクトリのmdファイルをNotionに保存し、元ファイルをアーカイブ
"""

import os
import sys
import time
import json
import shutil
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

if not NOTION_TOKEN:
    logging.error("環境変数 NOTION_TOKEN が設定されていません")
    sys.exit(1)

if not DATABASE_ID:
    logging.error("環境変数 NOTION_DATABASE_ID が設定されていません")
    sys.exit(1)

# スクリプト自身のディレクトリを取得
SCRIPT_DIR = Path(__file__).parent.resolve()

# Notion クライアント初期化（API バージョン 2025-09-03 を使用）
notion = Client(auth=NOTION_TOKEN, notion_version="2025-09-03")


def load_sync_targets() -> list[dict]:
    """sync_targets.json から同期対象ディレクトリを読み込む"""
    config_path = SCRIPT_DIR / "sync_targets.json"
    if not config_path.exists():
        logging.error(f"設定ファイルが見つかりません: {config_path}")
        sys.exit(1)
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            targets = json.load(f)
    except json.JSONDecodeError as e:
        logging.error(f"設定ファイルのJSON解析エラー: {e}")
        sys.exit(1)
    return targets


class MarkdownHandler(FileSystemEventHandler):
    """Markdownファイルの作成を監視"""

    def __init__(self, dir_note_map: dict[str, str | None]):
        super().__init__()
        self.dir_note_map = dir_note_map

    def on_created(self, event):
        if event.is_directory:
            return

        file_path = Path(event.src_path)

        # .mdファイルのみ処理
        if file_path.suffix.lower() == '.md':
            logging.info(f"新しいMDファイルを検出: {file_path.name}")
            # ファイルの書き込みが完了するまで少し待機
            time.sleep(0.5)
            note_id = self.dir_note_map.get(str(file_path.parent))
            self.process_markdown(file_path, note_id)

    def process_markdown(self, file_path: Path, note_id: str | None = None):
        """MarkdownファイルをNotionに保存し、元ファイルをアーカイブ"""
        try:
            # ファイル読み込み
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()

            # タイトル取得（ファイル名から拡張子を除く）
            title = file_path.stem

            # プロパティを構築
            properties = {
                "Name": {
                    "title": [
                        {
                            "text": {
                                "content": title
                            }
                        }
                    ]
                }
            }

            if note_id is not None:
                properties["Lit Notes"] = {"relation": [{"id": note_id}]}

            # Notionページ作成（data_source_id を使用）
            page = notion.pages.create(
                parent={"data_source_id": DATABASE_ID},
                properties=properties,
                children=self.markdown_to_blocks(content)
            )

            logging.info(f"Notionに保存成功: {title}")
            logging.info(f"Page URL: https://notion.so/{page['id'].replace('-', '')}")

            # ファイルをアーカイブ
            archive_dir = file_path.parent / "archived"
            archive_dir.mkdir(exist_ok=True)
            shutil.move(str(file_path), str(archive_dir / file_path.name))
            logging.info(f"ファイルをアーカイブ: {file_path.name} → archived/")

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
    logging.info("NotionSync 起動")

    # 同期対象を設定ファイルから読み込み
    sync_targets = load_sync_targets()
    logging.info(f"設定ファイルから {len(sync_targets)} 件の同期対象を読み込み")

    # dir_note_map を構築
    dir_note_map: dict[str, str | None] = {}

    validated_dirs = []
    for target in sync_targets:
        watch_dir = target["directory"]
        note_id = target.get("note_id")
        watch_path = Path(watch_dir)

        if not watch_path.exists():
            logging.warning(f"監視ディレクトリが存在しません: {watch_dir}")
            try:
                watch_path.mkdir(parents=True, exist_ok=True)
                logging.info(f"監視ディレクトリを作成しました: {watch_dir}")
            except Exception as e:
                logging.error(f"監視ディレクトリの作成に失敗: {str(e)}")
                sys.exit(1)

        if not os.access(watch_path, os.R_OK):
            logging.error(f"監視ディレクトリに読み取り権限がありません: {watch_dir}")
            sys.exit(1)

        dir_note_map[watch_dir] = note_id
        validated_dirs.append(watch_dir)
        logging.info(f"監視対象ディレクトリ: {watch_dir}" + (f" (note_id: {note_id})" if note_id else ""))

    if not validated_dirs:
        logging.error("監視対象ディレクトリがありません")
        sys.exit(1)

    event_handler = MarkdownHandler(dir_note_map)
    observer = Observer()

    for watch_dir in validated_dirs:
        observer.schedule(event_handler, watch_dir, recursive=False)
        logging.info(f"監視開始: {watch_dir}")

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
