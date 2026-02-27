import XCTest
@testable import Toukan

final class SyncTargetTests: XCTestCase {

    // MARK: - sanitiseArchiveDirName

    func test_normalName_unchanged() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("archived"), "archived")
    }

    func test_nameWithSlash_stripped() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("path/to"), "pathto")
    }

    func test_nameWithLeadingDots_stripped() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("..hidden"), "hidden")
    }

    func test_emptyString_returnsDefault() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName(""), "archived")
    }

    func test_whitespaceOnly_returnsDefault() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("   "), "archived")
    }

    func test_pathTraversal_sanitised() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("../etc"), "etc")
    }

    func test_multipleSlashes_allStripped() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("a/b/c"), "abc")
    }

    func test_dotsOnly_returnsDefault() {
        XCTAssertEqual(SyncTarget.sanitiseArchiveDirName("..."), "archived")
    }
}
