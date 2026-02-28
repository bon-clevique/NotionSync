import XCTest
@testable import Toukan

@MainActor
final class SyncLogStoreTests: XCTestCase {

    func test_appendEntry_addsToEntries() {
        let store = SyncLogStore()
        let entry = SyncLogEntry(level: .info, message: "test")
        store.append(entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.message, "test")
        XCTAssertEqual(store.entries.first?.level, .info)
    }

    func test_maxEntries_trimsOldest() {
        let store = SyncLogStore()
        for i in 1...51 {
            store.append(SyncLogEntry(level: .info, message: "msg \(i)"))
        }
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.message, "msg 2")
        XCTAssertEqual(store.entries.last?.message, "msg 51")
    }

    func test_clear_removesAll() {
        let store = SyncLogStore()
        store.append(SyncLogEntry(level: .info, message: "a"))
        store.append(SyncLogEntry(level: .warning, message: "b"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_entryHasUniqueId() {
        let a = SyncLogEntry(level: .info, message: "a")
        let b = SyncLogEntry(level: .info, message: "a")
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_entryLevels() {
        let info = SyncLogEntry(level: .info, message: "i")
        let warn = SyncLogEntry(level: .warning, message: "w")
        let err = SyncLogEntry(level: .error, message: "e")
        XCTAssertEqual(info.level, .info)
        XCTAssertEqual(warn.level, .warning)
        XCTAssertEqual(err.level, .error)
    }

    func test_exactlyAtMax_doesNotTrim() {
        let store = SyncLogStore()
        for i in 1...50 {
            store.append(SyncLogEntry(level: .info, message: "msg \(i)"))
        }
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.message, "msg 1")
    }
}
