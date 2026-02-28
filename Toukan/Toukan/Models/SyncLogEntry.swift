import Foundation
import Observation

// MARK: - SyncLogLevel

enum SyncLogLevel: Equatable, Sendable {
    case info
    case warning
    case error
}

// MARK: - SyncLogEntry

struct SyncLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: SyncLogLevel
    let message: String

    init(level: SyncLogLevel, message: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
    }
}

// MARK: - SyncLogStore

@Observable
@MainActor
final class SyncLogStore {

    private(set) var entries: [SyncLogEntry] = []

    private let maxEntries = 50

    func append(_ entry: SyncLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
