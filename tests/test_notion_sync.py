"""Tests for notion_sync.py module."""

import json
import os
import sys
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock

import pytest

# Add parent directory to path to import notion_sync
sys.path.insert(0, str(Path(__file__).parent.parent))

# Mock environment variables before importing notion_sync
os.environ["NOTION_TOKEN"] = "test_token"
os.environ["NOTION_DATABASE_ID"] = "test_database_id"

import notion_sync


class TestMarkdownHandler:
    """Tests for MarkdownHandler class."""

    def test_markdown_handler_initialization(self):
        """Test that MarkdownHandler can be instantiated."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        assert handler is not None

    def test_create_paragraph_block_short_text(self):
        """Test create_paragraph_block with short text."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        text = "This is a short paragraph."
        block = handler.create_paragraph_block(text)

        assert block["object"] == "block"
        assert block["type"] == "paragraph"
        assert "paragraph" in block
        assert len(block["paragraph"]["rich_text"]) > 0
        assert block["paragraph"]["rich_text"][0]["text"]["content"] == text

    def test_create_paragraph_block_long_text(self):
        """Test create_paragraph_block with text exceeding 2000 characters."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        text = "a" * 2500  # Exceeds 2000 character limit
        block = handler.create_paragraph_block(text)

        assert block["object"] == "block"
        assert block["type"] == "paragraph"
        content = block["paragraph"]["rich_text"][0]["text"]["content"]
        assert len(content) <= 2000
        assert content.endswith("...")

    def test_markdown_to_blocks_empty_content(self):
        """Test markdown_to_blocks with empty content."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        blocks = handler.markdown_to_blocks("")
        assert blocks == []

    def test_markdown_to_blocks_heading_1(self):
        """Test markdown_to_blocks with heading 1."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        content = "# Heading 1"
        blocks = handler.markdown_to_blocks(content)

        assert len(blocks) == 1
        assert blocks[0]["type"] == "heading_1"
        assert blocks[0]["heading_1"]["rich_text"][0]["text"]["content"] == "Heading 1"

    def test_markdown_to_blocks_heading_2(self):
        """Test markdown_to_blocks with heading 2."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        content = "## Heading 2"
        blocks = handler.markdown_to_blocks(content)

        assert len(blocks) == 1
        assert blocks[0]["type"] == "heading_2"
        assert blocks[0]["heading_2"]["rich_text"][0]["text"]["content"] == "Heading 2"

    def test_markdown_to_blocks_heading_3(self):
        """Test markdown_to_blocks with heading 3."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        content = "### Heading 3"
        blocks = handler.markdown_to_blocks(content)

        assert len(blocks) == 1
        assert blocks[0]["type"] == "heading_3"
        assert blocks[0]["heading_3"]["rich_text"][0]["text"]["content"] == "Heading 3"

    def test_markdown_to_blocks_paragraph(self):
        """Test markdown_to_blocks with paragraph."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        content = "This is a paragraph."
        blocks = handler.markdown_to_blocks(content)

        assert len(blocks) == 1
        assert blocks[0]["type"] == "paragraph"
        assert blocks[0]["paragraph"]["rich_text"][0]["text"]["content"] == content

    def test_markdown_to_blocks_multiple_elements(self):
        """Test markdown_to_blocks with multiple elements."""
        handler = notion_sync.MarkdownHandler(dir_note_map={})
        content = "# Title\n\nThis is a paragraph.\n\n## Subtitle"
        blocks = handler.markdown_to_blocks(content)

        assert len(blocks) >= 2
        assert blocks[0]["type"] == "heading_1"
        assert blocks[-1]["type"] == "heading_2"


class TestMarkdownHandlerInit:
    """Tests for MarkdownHandler initialization."""

    def test_handler_stores_dir_note_map(self):
        """Test that dir_note_map is stored correctly."""
        mapping = {"/tmp/notes": "abc123", "/tmp/drafts": None}
        handler = notion_sync.MarkdownHandler(dir_note_map=mapping)
        assert handler.dir_note_map == mapping


class TestLoadSyncTargets:
    """Tests for load_sync_targets function."""

    def test_load_sync_targets_success(self, tmp_path):
        """Test successful loading of sync_targets.json."""
        config = [
            {"directory": "/tmp/notes", "note_id": "abc123"},
            {"directory": "/tmp/drafts"}
        ]
        config_file = tmp_path / "sync_targets.json"
        config_file.write_text(json.dumps(config))

        with patch.object(notion_sync, 'SCRIPT_DIR', tmp_path):
            result = notion_sync.load_sync_targets()

        assert len(result) == 2
        assert result[0]["directory"] == "/tmp/notes"
        assert result[0]["note_id"] == "abc123"
        assert result[1]["directory"] == "/tmp/drafts"
        assert "note_id" not in result[1]

    def test_load_sync_targets_file_not_found(self, tmp_path):
        """Test sys.exit when config file is missing."""
        with patch.object(notion_sync, 'SCRIPT_DIR', tmp_path):
            with pytest.raises(SystemExit):
                notion_sync.load_sync_targets()

    def test_load_sync_targets_invalid_json(self, tmp_path):
        """Test sys.exit when config file has invalid JSON."""
        config_file = tmp_path / "sync_targets.json"
        config_file.write_text("{invalid json")

        with patch.object(notion_sync, 'SCRIPT_DIR', tmp_path):
            with pytest.raises(SystemExit):
                notion_sync.load_sync_targets()


class TestArchive:
    """Tests for archive functionality."""

    @patch.object(notion_sync, 'notion')
    def test_process_markdown_archives_file(self, mock_notion, tmp_path):
        """Test that process_markdown moves file to archived/ directory."""
        # Create a test markdown file
        md_file = tmp_path / "test.md"
        md_file.write_text("# Test\n\nContent")

        mock_notion.pages.create.return_value = {"id": "page-id-123"}

        handler = notion_sync.MarkdownHandler(dir_note_map={})
        handler.process_markdown(md_file)

        # Original file should be gone
        assert not md_file.exists()
        # File should be in archived/
        archived_file = tmp_path / "archived" / "test.md"
        assert archived_file.exists()
        assert archived_file.read_text() == "# Test\n\nContent"

    @patch.object(notion_sync, 'notion')
    def test_process_markdown_creates_archived_dir(self, mock_notion, tmp_path):
        """Test that archived/ directory is created if it doesn't exist."""
        md_file = tmp_path / "test.md"
        md_file.write_text("# Test")

        mock_notion.pages.create.return_value = {"id": "page-id-123"}

        handler = notion_sync.MarkdownHandler(dir_note_map={})
        handler.process_markdown(md_file)

        assert (tmp_path / "archived").is_dir()


class TestLitNotesRelation:
    """Tests for Lit Notes relation property."""

    @patch.object(notion_sync, 'notion')
    def test_process_markdown_with_note_id(self, mock_notion, tmp_path):
        """Test that Lit Notes relation is set when note_id is provided."""
        md_file = tmp_path / "test.md"
        md_file.write_text("# Test")

        mock_notion.pages.create.return_value = {"id": "page-id-123"}

        handler = notion_sync.MarkdownHandler(dir_note_map={})
        handler.process_markdown(md_file, note_id="lit-note-id-456")

        # Verify the Notion API was called with Lit Notes relation
        call_kwargs = mock_notion.pages.create.call_args
        properties = call_kwargs.kwargs.get("properties") or call_kwargs[1].get("properties")
        assert "Lit Notes" in properties
        assert properties["Lit Notes"] == {"relation": [{"id": "lit-note-id-456"}]}

    @patch.object(notion_sync, 'notion')
    def test_process_markdown_without_note_id(self, mock_notion, tmp_path):
        """Test that Lit Notes relation is NOT set when note_id is None."""
        md_file = tmp_path / "test.md"
        md_file.write_text("# Test")

        mock_notion.pages.create.return_value = {"id": "page-id-123"}

        handler = notion_sync.MarkdownHandler(dir_note_map={})
        handler.process_markdown(md_file)

        call_kwargs = mock_notion.pages.create.call_args
        properties = call_kwargs.kwargs.get("properties") or call_kwargs[1].get("properties")
        assert "Lit Notes" not in properties
