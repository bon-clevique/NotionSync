import XCTest
@testable import Toukan

final class MarkdownParserTests: XCTestCase {

    private let parser = MarkdownParser()

    // MARK: - Helper

    /// Encodes a NotionBlock to JSON and extracts the plain text content
    /// from the first rich_text entry of the block's type-keyed payload.
    private func textContent(of block: NotionBlock) throws -> String {
        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let type = json["type"] as! String
        let content = json[type] as! [String: Any]
        let richText = content["rich_text"] as! [[String: Any]]
        let text = richText[0]["text"] as! [String: Any]
        return text["content"] as! String
    }

    // MARK: - Empty / Whitespace

    func test_emptyContent_returnsEmptyArray() {
        let blocks = parser.parse("")
        XCTAssertTrue(blocks.isEmpty)
    }

    func test_whitespaceOnly_returnsEmptyArray() {
        let blocks = parser.parse("   \n  \n")
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - Headings

    func test_heading1_parsesCorrectly() throws {
        let blocks = parser.parse("# Heading 1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .heading1)
        XCTAssertEqual(try textContent(of: blocks[0]), "Heading 1")
    }

    func test_heading2_parsesCorrectly() throws {
        let blocks = parser.parse("## Heading 2")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .heading2)
        XCTAssertEqual(try textContent(of: blocks[0]), "Heading 2")
    }

    func test_heading3_parsesCorrectly() throws {
        let blocks = parser.parse("### Heading 3")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .heading3)
        XCTAssertEqual(try textContent(of: blocks[0]), "Heading 3")
    }

    // MARK: - Paragraph

    func test_paragraph_parsesCorrectly() throws {
        let blocks = parser.parse("This is a paragraph.")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .paragraph)
        XCTAssertEqual(try textContent(of: blocks[0]), "This is a paragraph.")
    }

    // MARK: - Multiple Elements

    func test_multipleElements_parsesInOrder() {
        let blocks = parser.parse("# Title\n\nParagraph text\n\n## Sub")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].type, .heading1)
        XCTAssertEqual(blocks[1].type, .paragraph)
        XCTAssertEqual(blocks[2].type, .heading2)
    }

    // MARK: - Truncation

    func test_longText_truncatesAt2000() throws {
        let input = String(repeating: "a", count: 2500)
        let blocks = parser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .paragraph)
        let content = try textContent(of: blocks[0])
        XCTAssertEqual(content.count, 2000)
        XCTAssertTrue(content.hasSuffix("..."))
    }

    func test_textExactly2000_notTruncated() throws {
        let input = String(repeating: "a", count: 2000)
        let blocks = parser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .paragraph)
        let content = try textContent(of: blocks[0])
        XCTAssertEqual(content.count, 2000)
        XCTAssertFalse(content.hasSuffix("..."))
        XCTAssertEqual(content, String(repeating: "a", count: 2000))
    }

    func test_textExactly2001_truncatesTo2000() throws {
        let input = String(repeating: "a", count: 2001)
        let blocks = parser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        let content = try textContent(of: blocks[0])
        XCTAssertEqual(content.count, 2000)
        XCTAssertTrue(content.hasSuffix("..."))
        XCTAssertEqual(String(content.prefix(1997)), String(repeating: "a", count: 1997))
    }

    func test_textExactly1999_notTruncated() throws {
        let input = String(repeating: "a", count: 1999)
        let blocks = parser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        let content = try textContent(of: blocks[0])
        XCTAssertEqual(content.count, 1999)
        XCTAssertFalse(content.hasSuffix("..."))
    }

    // MARK: - Line Merging

    func test_consecutiveLines_mergeIntoParagraph() throws {
        let blocks = parser.parse("line1\nline2\nline3")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .paragraph)
        XCTAssertEqual(try textContent(of: blocks[0]), "line1\nline2\nline3")
    }

    // MARK: - Edge Cases

    func test_headingWithoutSpace_treatedAsParagraph() throws {
        let blocks = parser.parse("#NoSpace")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .paragraph)
        XCTAssertEqual(try textContent(of: blocks[0]), "#NoSpace")
    }

    // MARK: - Complex Document

    func test_complexDocument_parsesCorrectly() throws {
        let input = "# Title\n\nFirst paragraph.\nSecond line.\n\n## Section\n\n### Subsection\n\nBody text"
        let blocks = parser.parse(input)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0].type, .heading1)
        XCTAssertEqual(blocks[1].type, .paragraph)
        XCTAssertEqual(blocks[2].type, .heading2)
        XCTAssertEqual(blocks[3].type, .heading3)
        XCTAssertEqual(blocks[4].type, .paragraph)

        XCTAssertEqual(try textContent(of: blocks[0]), "Title")
        XCTAssertEqual(try textContent(of: blocks[1]), "First paragraph.\nSecond line.")
        XCTAssertEqual(try textContent(of: blocks[2]), "Section")
        XCTAssertEqual(try textContent(of: blocks[3]), "Subsection")
        XCTAssertEqual(try textContent(of: blocks[4]), "Body text")
    }
}
