import Foundation
import AppKit
import os
import Observation

// MARK: - SyncTarget

struct SyncTarget: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var noteId: String?
    var archiveDirName: String
    var bookmarkData: Data

    init(url: URL, displayName: String, noteId: String? = nil, archiveDirName: String = "archived") throws {
        self.id = UUID()
        self.displayName = displayName
        self.noteId = noteId
        self.archiveDirName = archiveDirName
        self.bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // Backward-compatible decoding: existing targets without archiveDirName get "archived"
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
        archiveDirName = Self.sanitiseArchiveDirName(
            try container.decodeIfPresent(String.self, forKey: .archiveDirName) ?? "archived"
        )
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
    }

    /// Strips path separators and leading dots to prevent directory traversal.
    static func sanitiseArchiveDirName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed
            .components(separatedBy: "/").joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return safe.isEmpty ? "archived" : safe
    }
}

// MARK: - BookmarkManager

@Observable @MainActor final class BookmarkManager {

    // MARK: Properties

    private(set) var targets: [SyncTarget] = []

    private let logger = Logger(subsystem: "com.clevique.Toukan", category: "Bookmark")
    private let defaultsKey = "syncTargets"

    // MARK: Lifecycle

    init() {
        loadTargets()
    }

    // MARK: Public Methods

    /// Opens NSOpenPanel for folder selection, creates a security-scoped bookmark,
    /// persists it, and returns the newly created SyncTarget.
    func addDirectory() -> SyncTarget? {
        // NSOpenPanel must run on the main thread
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Select a folder to sync with Notion"

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.info("NSOpenPanel cancelled or returned no URL")
            return nil
        }

        do {
            let target = try SyncTarget(url: url, displayName: url.lastPathComponent)
            targets.append(target)
            saveTargets()
            logger.info("Bookmark created for directory: \(url.path, privacy: .public)")
            return target
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes a target and its bookmark from storage.
    func removeTarget(_ target: SyncTarget) {
        targets.removeAll { $0.id == target.id }
        saveTargets()
        logger.info("Removed sync target: \(target.displayName, privacy: .public) (id: \(target.id.uuidString, privacy: .public))")
    }

    /// Replaces a stored target with the provided value.
    func updateTarget(_ target: SyncTarget) {
        guard let index = targets.firstIndex(where: { $0.id == target.id }) else {
            logger.warning("updateTarget: target not found with id \(target.id.uuidString, privacy: .public)")
            return
        }
        targets[index] = target
        saveTargets()
        logger.info("Updated sync target: \(target.displayName, privacy: .public) (id: \(target.id.uuidString, privacy: .public))")
    }

    /// Resolves bookmark data to a URL. Handles stale bookmarks by attempting
    /// to create a fresh bookmark from the resolved URL.
    func resolveURL(for target: SyncTarget) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: target.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("Stale bookmark detected for target: \(target.displayName, privacy: .public) — attempting auto-refresh")
                refreshBookmark(for: target, resolvedURL: url)
            } else {
                logger.debug("Bookmark resolved successfully for: \(target.displayName, privacy: .public)")
            }

            return url
        } catch {
            logger.error("Failed to resolve bookmark for \(target.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Resolves the URL for a target and begins accessing the security-scoped resource.
    /// Returns the resolved URL if access was successfully started, otherwise nil.
    func startAccessing(_ target: SyncTarget) -> URL? {
        guard let url = resolveURL(for: target) else {
            logger.error("startAccessing: could not resolve URL for target \(target.displayName, privacy: .public)")
            return nil
        }

        let didStart = url.startAccessingSecurityScopedResource()
        if !didStart {
            logger.warning("startAccessingSecurityScopedResource returned false for \(url.path, privacy: .public)")
            return nil
        }
        logger.debug("Started accessing security-scoped resource: \(url.path, privacy: .public)")
        return url
    }

    /// Stops accessing the security-scoped resource for the given URL.
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        logger.debug("Stopped accessing security-scoped resource: \(url.path, privacy: .public)")
    }

    /// Loads persisted sync targets from UserDefaults.
    func loadTargets() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            logger.info("No persisted sync targets found in UserDefaults")
            return
        }

        do {
            let decoded = try JSONDecoder().decode([SyncTarget].self, from: data)
            targets = decoded
            logger.info("Loaded \(decoded.count, privacy: .public) sync target(s) from UserDefaults")
        } catch {
            logger.error("Failed to decode sync targets from UserDefaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private Methods

    /// Persists the current targets array to UserDefaults as a JSON-encoded byte array.
    private func saveTargets() {
        do {
            let data = try JSONEncoder().encode(targets)
            UserDefaults.standard.set(data, forKey: defaultsKey)
            logger.debug("Saved \(self.targets.count, privacy: .public) sync target(s) to UserDefaults")
        } catch {
            logger.error("Failed to encode sync targets for UserDefaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Attempts to create a fresh bookmark from a previously resolved (but stale) URL
    /// and updates the stored target in-place.
    private func refreshBookmark(for target: SyncTarget, resolvedURL: URL) {
        do {
            let freshData = try resolvedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard let index = targets.firstIndex(where: { $0.id == target.id }) else {
                logger.warning("refreshBookmark: target not found in targets array (id: \(target.id.uuidString, privacy: .public))")
                return
            }
            targets[index].bookmarkData = freshData
            saveTargets()
            logger.info("Bookmark refreshed successfully for: \(target.displayName, privacy: .public)")
        } catch {
            logger.error("Failed to refresh stale bookmark for \(target.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
