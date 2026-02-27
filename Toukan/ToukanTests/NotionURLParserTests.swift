import XCTest
@testable import Toukan

final class NotionURLParserTests: XCTestCase {

    // MARK: - extractDatabaseId

    func test_validUUIDWithDashes_returnsLowercased() {
        let input = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    func test_32HexWithoutDashes_returnsFormattedUUID() {
        let input = "a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    func test_notionSoShareLink_extractsDatabaseId() {
        let input = "https://www.notion.so/workspace/My-Database-a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    func test_notionSiteLink_extractsDatabaseId() {
        let input = "https://myspace.notion.site/Page-Title-a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    func test_evilDomain_returnsNil() {
        let input = "https://evilnotion.so/a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertNil(result)
    }

    func test_nonNotionDomain_returnsNil() {
        let input = "https://example.com/a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertNil(result)
    }

    func test_invalidInput_returnsNil() {
        let result = NotionURLParser.extractDatabaseId(from: "not-a-valid-id")
        XCTAssertNil(result)
    }

    func test_emptyString_returnsNil() {
        let result = NotionURLParser.extractDatabaseId(from: "")
        XCTAssertNil(result)
    }

    func test_notionSoWithoutSubdomain_extractsDatabaseId() {
        let input = "https://notion.so/a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.extractDatabaseId(from: input)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    // MARK: - formatAsUUID

    func test_formatAsUUID_insertsCorrectDashes() {
        let hex = "a1b2c3d4e5f67890abcdef1234567890"
        let result = NotionURLParser.formatAsUUID(hex)
        XCTAssertEqual(result, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }
}
