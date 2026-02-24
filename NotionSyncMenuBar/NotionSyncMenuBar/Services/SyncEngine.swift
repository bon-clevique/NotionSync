import Foundation
import os
import Observation

// MARK: - SyncEngine

/// Orchestrates the full sync flow: file detection → parse → upload → archive.
///
/// Observes watched directories via ``DirectoryWatcher``, parses detected Markdown
/// files, uploads them to Notion using ``NotionAPIClient``, and archives processed
/// files into an `archived/` subdirectory.
@Observable
@MainActor
final class SyncEngine {

    // MARK: - Observable State

    private(set) var isRunning = false
    private(set) var lastSyncedFile: String?
    private(set) var lastSyncedDate: Date?
    private(set) var errorMessage: String?
    private(set) var syncedCount: Int = 0

    // MARK: - Configuration (set from outside before calling start())

    var dataSourceId: String = ""
    var notionToken: String = ""

    // MARK: - Dependencies

    let bookmarkManager: BookmarkManager

    // MARK: - Private State

    private let parser = MarkdownParser()
    private var watcher: DirectoryWatcher?
    private var apiClient: NotionAPIClient?
    /// Security-scoped resource URLs that have been started and must be stopped on shutdown.
    private var accessedURLs: [URL] = []

    private let logger = Logger(subsystem: "com.bon.NotionSyncMenuBar", category: "SyncEngine")

    // MARK: - Config File Support

    /// Path to sync_targets.json. When set, targets are loaded from this file instead of BookmarkManager.
    var configFilePath: String = ""

    private var configWatcher: ConfigFileWatcher?

    /// Active targets from config file, keyed by canonical directory path.
    private var activeTargets: [String: ActiveTarget] = [:]

    private struct ActiveTarget {
        let directoryURL: URL
        var noteId: String?
    }

    /// Parsed config targets for display in SettingsView (available before start()).
    private(set) var displayConfigTargets: [SyncTargetConfig] = []

    var activeTargetCount: Int {
        if !configFilePath.isEmpty {
            return isRunning ? activeTargets.count : displayConfigTargets.count
        }
        return bookmarkManager.targets.count
    }

    // MARK: - Init

    init(bookmarkManager: BookmarkManager) {
        self.bookmarkManager = bookmarkManager
    }

    /// Loads config targets from the JSON file for display purposes.
    /// Call after setting `configFilePath`.
    func loadConfigTargets() {
        guard !configFilePath.isEmpty else { return }
        let url = URL(fileURLWithPath: configFilePath)
        guard let data = try? Data(contentsOf: url),
              let configs = try? JSONDecoder().decode([SyncTargetConfig].self, from: data) else {
            logger.warning("loadConfigTargets: failed to parse \(self.configFilePath, privacy: .public)")
            return
        }
        displayConfigTargets = configs
        logger.info("loadConfigTargets: loaded \(configs.count, privacy: .public) target(s) for display")
    }

    // MARK: - Lifecycle

    /// Validates configuration, creates the API client and directory watcher, and
    /// begins monitoring all registered sync targets.
    func start() {
        guard !notionToken.isEmpty else {
            errorMessage = "Notion token is not configured."
            logger.error("start: notionToken is empty — aborting")
            return
        }
        guard !dataSourceId.isEmpty else {
            errorMessage = "Notion data source ID is not configured."
            logger.error("start: dataSourceId is empty — aborting")
            return
        }

        logger.info("start: initialising SyncEngine")

        apiClient = NotionAPIClient(token: notionToken)

        // Capture self weakly to satisfy the @Sendable requirement on the handler
        // and to avoid a retain cycle. Dispatch back to MainActor for state access.
        let newWatcher = DirectoryWatcher { [weak self] fileURL, directoryURL in
            guard let self else { return }
            self.handleNewFile(fileURL, in: directoryURL)
        }
        watcher = newWatcher

        if !configFilePath.isEmpty {
            // Config-file-based mode: watch sync_targets.json and reconcile targets dynamically.
            let cfp = configFilePath
            let cfw = ConfigFileWatcher(filePath: cfp) { [weak self] configs in
                Task { @MainActor [weak self] in
                    self?.reconcileTargets(configs)
                }
            }
            configWatcher = cfw

            // Load initial config and start watching before setting isRunning.
            if let initialConfigs = cfw.parseConfigFile() {
                reconcileTargets(initialConfigs)
            }

            do {
                try cfw.startWatching()
            } catch {
                logger.error("start: failed to watch config file '\(cfp, privacy: .public)' — \(error.localizedDescription, privacy: .public)")
            }

            isRunning = true
            errorMessage = nil
            logger.info("start: SyncEngine running — config-file mode, \(self.activeTargets.count, privacy: .public) target(s) watched")
        } else {
            // Bookmark-based mode: start accessing every registered sync target.
            var startedURLs: [URL] = []
            for target in bookmarkManager.targets {
                guard let url = bookmarkManager.startAccessing(target) else {
                    logger.warning("start: could not start accessing target '\(target.displayName, privacy: .public)'")
                    continue
                }
                do {
                    try newWatcher.watch(url)
                    newWatcher.scanExistingFiles(in: url)
                    startedURLs.append(url)
                    logger.info("start: watching '\(url.path, privacy: .public)'")
                } catch {
                    logger.error("start: failed to watch '\(url.path, privacy: .public)' — \(error.localizedDescription, privacy: .public)")
                    bookmarkManager.stopAccessing(url)
                }
            }

            accessedURLs = startedURLs
            isRunning = true
            errorMessage = nil
            logger.info("start: SyncEngine running — \(startedURLs.count, privacy: .public) target(s) watched")
        }
    }

    /// Stops all directory watchers and relinquishes security-scoped resource access.
    func stop() {
        logger.info("stop: stopping SyncEngine")

        configWatcher?.stopWatching()
        configWatcher = nil
        activeTargets.removeAll()
        processingFiles.removeAll()

        watcher?.stopAll()
        watcher = nil
        apiClient = nil

        for url in accessedURLs {
            bookmarkManager.stopAccessing(url)
        }
        accessedURLs = []

        isRunning = false
        logger.info("stop: SyncEngine stopped")
    }

    // MARK: - Config Reconciliation

    /// Reconciles running watchers with new config entries.
    private func reconcileTargets(_ configs: [SyncTargetConfig]) {
        displayConfigTargets = configs
        let newPaths = Set(configs.map { $0.directory })
        let currentPaths = Set(activeTargets.keys)

        // Stop watching removed directories
        for path in currentPaths.subtracting(newPaths) {
            if let target = activeTargets.removeValue(forKey: path) {
                watcher?.stopWatching(target.directoryURL)
                logger.info("reconcile: stopped watching removed target \(path, privacy: .public)")
            }
        }

        // Add new directories
        for config in configs where !currentPaths.contains(config.directory) {
            let url = URL(fileURLWithPath: config.directory)
            guard FileManager.default.fileExists(atPath: config.directory) else {
                logger.warning("reconcile: directory does not exist: \(config.directory, privacy: .public)")
                continue
            }
            do {
                try watcher?.watch(url)
                watcher?.scanExistingFiles(in: url)
                activeTargets[config.directory] = ActiveTarget(directoryURL: url, noteId: config.resolvedNoteId)
                logger.info("reconcile: started watching new target \(config.directory, privacy: .public)")
            } catch {
                logger.error("reconcile: failed to watch \(config.directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Update noteId for existing directories
        for config in configs where currentPaths.contains(config.directory) {
            activeTargets[config.directory]?.noteId = config.resolvedNoteId
        }

        logger.info("reconcile: now watching \(self.activeTargets.count, privacy: .public) target(s)")
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
            // First check config-file-based targets, then fall back to bookmark-based
            let canonicalPath = directoryURL.resolvingSymlinksInPath().path
            let noteId = activeTargets[canonicalPath]?.noteId
                ?? bookmarkManager.targets.first { target in
                    bookmarkManager.resolveURL(for: target)?.standardizedFileURL
                        == directoryURL.standardizedFileURL
                }?.noteId

            await processFile(fileURL, noteId: noteId)
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

    private func processFile(_ fileURL: URL, noteId: String?) async {
        let filename = fileURL.lastPathComponent
        let canonicalPath = fileURL.resolvingSymlinksInPath().path

        // Guard against duplicate processing (race between scanExistingFiles and live watcher)
        guard !processingFiles.contains(canonicalPath) else {
            logger.debug("processFile: skipping duplicate '\(filename, privacy: .public)'")
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.debug("processFile: file no longer exists '\(filename, privacy: .public)'")
            return
        }
        processingFiles.insert(canonicalPath)
        defer { processingFiles.remove(canonicalPath) }

        logger.info("processFile: begin '\(filename, privacy: .public)'")

        // 1. Read file content
        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let message = "Failed to read '\(filename)': \(error.localizedDescription)"
            logger.error("processFile: \(message, privacy: .public)")
            errorMessage = message
            return
        }

        // 2. Derive title from filename (strip extension)
        let title = fileURL.deletingPathExtension().lastPathComponent

        // 3. Parse Markdown into Notion blocks
        let blocks = parser.parse(content)

        // 4. Upload to Notion
        guard let client = apiClient else {
            let message = "API client is not initialised — call start() first."
            logger.error("processFile: \(message, privacy: .public)")
            errorMessage = message
            return
        }

        let page: NotionPage
        do {
            page = try await client.createPage(
                dataSourceId: dataSourceId,
                title: title,
                litNoteId: noteId,
                blocks: blocks
            )
            logger.info("processFile: uploaded '\(filename, privacy: .public)' → Notion page id=\(page.id, privacy: .public)")
        } catch {
            let message = "Upload failed for '\(filename)': \(error.localizedDescription)"
            logger.error("processFile: \(message, privacy: .public)")
            errorMessage = message
            // Do not move the file — leave it in place for retry
            return
        }

        // 5. Archive the processed file
        let directoryURL = fileURL.deletingLastPathComponent()
        let archivedDir = directoryURL.appendingPathComponent("archived", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: archivedDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            let message = "Could not create archived/ directory for '\(filename)': \(error.localizedDescription)"
            logger.error("processFile: \(message, privacy: .public)")
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
            logger.info("processFile: archived '\(filename, privacy: .public)' → '\(destination.path, privacy: .public)'")
        } catch {
            let message = "Failed to archive '\(filename)': \(error.localizedDescription)"
            logger.error("processFile: \(message, privacy: .public)")
            errorMessage = message
            return
        }

        // 6. Update observable state on success
        lastSyncedFile = filename
        lastSyncedDate = Date()
        syncedCount += 1
        errorMessage = nil
        logger.info("processFile: done '\(filename, privacy: .public)' (total synced: \(self.syncedCount, privacy: .public))")
    }
}
