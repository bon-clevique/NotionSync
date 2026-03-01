import Foundation
import os
import Observation

// MARK: - SyncEngine

/// Orchestrates the full sync flow: file detection → parse → upload → archive.
///
/// Observes watched directories via ``DirectoryWatcher``, parses detected Markdown
/// files, uploads them to Notion using ``NotionAPIClient``, and archives processed
/// files into a configurable subdirectory (per ``SyncTarget``).
@Observable
@MainActor
final class SyncEngine {

    // MARK: - Observable State

    private(set) var isRunning = false
    private(set) var lastSyncedFile: String?
    private(set) var lastSyncedDate: Date?
    private(set) var errorMessage: String?
    private(set) var syncedCount: Int = 0

    // MARK: - Configuration

    private let apiSettings: APISettings

    // MARK: - Dependencies

    private let bookmarkManager: BookmarkManager
    private let logStore: SyncLogStore
    private let languageManager: LanguageManager

    // MARK: - Private State

    private let parser = MarkdownParser()
    private var watcher: DirectoryWatcher?
    private var apiClient: NotionAPIClient?
    /// Cached title property name from the data source schema.
    private var cachedTitlePropertyName: String?
    /// Security-scoped resource URLs that have been started and must be stopped on shutdown.
    private var accessedURLs: [URL] = []

    private let logger = Logger(subsystem: "com.clevique.Toukan", category: "SyncEngine")

    var activeTargetCount: Int {
        accessedURLs.count
    }

    private var strings: Strings { languageManager.strings }

    // MARK: - Init

    init(bookmarkManager: BookmarkManager, apiSettings: APISettings, logStore: SyncLogStore, languageManager: LanguageManager) {
        self.bookmarkManager = bookmarkManager
        self.apiSettings = apiSettings
        self.logStore = logStore
        self.languageManager = languageManager
    }

    // MARK: - Logging

    private func log(_ level: SyncLogLevel, _ message: String) {
        logStore.append(SyncLogEntry(level: level, message: message))
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    /// Validates configuration, creates the API client and directory watcher, and
    /// begins monitoring all registered sync targets.
    func start() {
        guard !apiSettings.token.isEmpty else {
            errorMessage = strings.tokenNotConfigured
            log(.error, strings.tokenNotConfigured)
            return
        }
        guard !apiSettings.dataSourceId.isEmpty else {
            errorMessage = strings.dataSourceIdNotConfigured
            log(.error, strings.dataSourceIdNotConfigured)
            return
        }

        log(.info, strings.syncStarting)

        apiClient = NotionAPIClient(token: apiSettings.token)

        // Capture self weakly to satisfy the @Sendable requirement on the handler
        // and to avoid a retain cycle. Dispatch back to MainActor for state access.
        let newWatcher = DirectoryWatcher { [weak self] fileURL, directoryURL in
            guard let self else { return }
            self.handleNewFile(fileURL, in: directoryURL)
        }
        watcher = newWatcher

        // Start accessing every registered sync target via security-scoped bookmarks.
        var startedURLs: [URL] = []
        for target in bookmarkManager.targets {
            guard let url = bookmarkManager.startAccessing(target) else {
                log(.warning, strings.targetAccessFailed(name: target.displayName))
                continue
            }
            do {
                try newWatcher.watch(url)
                newWatcher.scanExistingFiles(in: url)
                startedURLs.append(url)
                log(.info, strings.targetWatching(path: url.path))
            } catch {
                log(.error, strings.targetWatchFailed(name: url.path))
                bookmarkManager.stopAccessing(url)
            }
        }

        accessedURLs = startedURLs

        if startedURLs.isEmpty {
            if bookmarkManager.targets.isEmpty {
                log(.warning, strings.noTargetsConfigured)
                errorMessage = strings.noTargetsConfigured
            } else {
                log(.error, strings.allTargetsFailed)
                errorMessage = strings.allTargetsFailed
            }
            isRunning = false
        } else {
            let failedCount = bookmarkManager.targets.count - startedURLs.count
            if failedCount > 0 {
                let msg = strings.someTargetsFailed(count: failedCount)
                log(.warning, msg)
                errorMessage = msg
            } else {
                errorMessage = nil
            }
            isRunning = true
            log(.info, strings.syncStarted(count: startedURLs.count))
        }
    }

    /// Stops all directory watchers and relinquishes security-scoped resource access.
    func stop() {
        log(.info, strings.syncStopping)

        processingFiles.removeAll()

        watcher?.stopAll()
        watcher = nil
        apiClient = nil
        cachedTitlePropertyName = nil

        for url in accessedURLs {
            bookmarkManager.stopAccessing(url)
        }
        accessedURLs = []

        isRunning = false
        log(.info, strings.syncStopped)
    }

    // MARK: - File Handling

    /// Entry point called by ``DirectoryWatcher`` when a new `.md` file is detected.
    ///
    /// The watcher calls this handler on its own internal queue, so this method is
    /// `nonisolated`. A `Task { @MainActor in }` bridges to the main actor for all
    /// state-touching work.
    nonisolated private func handleNewFile(_ fileURL: URL, in directoryURL: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = bookmarkManager.targets.first { target in
                bookmarkManager.resolveURL(for: target)?.standardizedFileURL
                    == directoryURL.standardizedFileURL
            }
            if target == nil {
                self.log(.warning, "handleNewFile: no matching target for '\(directoryURL.path)' — using default archive dir")
            }

            await processFile(
                fileURL,
                noteId: target?.noteId,
                archiveDirName: target?.archiveDirName ?? "archived"
            )
        }
    }

    // MARK: - File Processing

    /// Reads, parses, uploads, and archives a single Markdown file.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the `.md` file to process.
    ///   - noteId:  Optional Notion page ID to attach as a "Lit Notes" relation.
    /// Files currently being processed — prevents duplicate processing from
    /// concurrent scan + watcher events.
    private var processingFiles: Set<String> = []

    private func processFile(_ fileURL: URL, noteId: String?, archiveDirName: String) async {
        let filename = fileURL.lastPathComponent
        let canonicalPath = fileURL.resolvingSymlinksInPath().path

        // Guard against duplicate processing (race between scanExistingFiles and live watcher)
        guard !processingFiles.contains(canonicalPath) else {
            logger.debug("processFile: skipping duplicate '\(filename, privacy: .public)'")
            return
        }
        processingFiles.insert(canonicalPath)
        defer { processingFiles.remove(canonicalPath) }

        log(.info, strings.processingFile(name: filename))

        // 1. Read file content
        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let message = strings.fileReadFailed(name: filename)
            log(.error, message)
            errorMessage = message
            return
        }

        // 2. Derive title from filename (strip extension)
        let title = fileURL.deletingPathExtension().lastPathComponent

        // 3. Parse Markdown into Notion blocks
        let blocks = parser.parse(content)

        // 4. Upload to Notion
        guard let client = apiClient else {
            let message = strings.apiClientNotReady
            log(.error, message)
            errorMessage = message
            return
        }

        // Fetch and cache the title property name from the data source schema
        let titlePropertyName: String
        if let cached = cachedTitlePropertyName {
            titlePropertyName = cached
        } else {
            do {
                titlePropertyName = try await client.fetchTitlePropertyName(dataSourceId: apiSettings.dataSourceId)
                cachedTitlePropertyName = titlePropertyName
                log(.info, "Title property: '\(titlePropertyName)'")
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log(.error, strings.uploadFailedDetail(name: filename, detail: detail))
                errorMessage = strings.uploadFailed(name: filename)
                return
            }
        }

        do {
            _ = try await client.createPage(
                dataSourceId: apiSettings.dataSourceId,
                title: title,
                titlePropertyName: titlePropertyName,
                litNoteId: noteId,
                blocks: blocks
            )
            log(.info, strings.uploadSuccess(name: filename))
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log(.error, strings.uploadFailedDetail(name: filename, detail: detail))
            errorMessage = strings.uploadFailed(name: filename)
            return
        }

        // 5. Archive the processed file
        let directoryURL = fileURL.deletingLastPathComponent()
        let archivedDir = directoryURL.appendingPathComponent(archiveDirName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: archivedDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            let message = strings.archiveFailed(name: filename)
            log(.error, message)
            errorMessage = message
            return
        }

        let destination = archivedDir.appendingPathComponent(filename)
        do {
            // If a file with the same name already exists in the archive, remove it first
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: fileURL, to: destination)
            log(.info, strings.archiveSuccess(name: filename))
        } catch {
            let message = strings.archiveFailed(name: filename)
            log(.error, message)
            errorMessage = message
            return
        }

        // 6. Update observable state on success
        lastSyncedFile = filename
        lastSyncedDate = Date()
        syncedCount += 1
        errorMessage = nil
        log(.info, strings.syncComplete(name: filename, count: syncedCount))
    }
}
