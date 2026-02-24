import Foundation

/// Represents a single entry in sync_targets.json (on-disk format).
struct SyncTargetConfig: Codable, Equatable, Sendable {
    let directory: String
    let noteId: String
    let litNote: String?

    enum CodingKeys: String, CodingKey {
        case directory
        case noteId = "note_id"
        case litNote = "_lit_note"
    }

    /// Returns nil when noteId is empty or whitespace-only.
    var resolvedNoteId: String? {
        let trimmed = noteId.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
