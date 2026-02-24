import Foundation
import os

// MARK: - ConfigFileWatcher

/// Watches a single JSON file (sync_targets.json) for changes using a
/// kqueue-backed `DispatchSource`. Handles atomic saves (write-to-temp +
/// rename) by re-establishing the source whenever the file descriptor becomes
/// stale after a rename or delete event.
final class ConfigFileWatcher: @unchecked Sendable {

    // MARK: Types

    /// Delivers the freshly parsed array of sync targets. Called on a
    /// background queue; callers are responsible for any required
    /// main-thread hopping.
    typealias Handler = @Sendable ([SyncTargetConfig]) -> Void

    // MARK: Private State (all guarded by `queue`)

    private let filePath: String
    private let handler: Handler

    /// Serial queue that serialises all state mutations and file-system access.
    private let queue = DispatchQueue(label: "com.bon.NotionSyncMenuBar.ConfigFileWatcher")

    /// The currently active DispatchSource, or nil when not watching.
    private var source: DispatchSourceFileSystemObject?

    /// Work item used to debounce rapid change events (300 ms window).
    private var debounceWork: DispatchWorkItem?

    private let logger = Logger(subsystem: "com.bon.NotionSyncMenuBar", category: "ConfigWatcher")

    // MARK: Lifecycle

    /// - Parameters:
    ///   - filePath: Absolute path to the file to watch (e.g. sync_targets.json).
    ///   - handler: Invoked with the freshly parsed `[SyncTargetConfig]` after
    ///     each detected change. Called on a background queue.
    init(filePath: String, handler: @escaping Handler) {
        self.filePath = filePath
        self.handler = handler
    }

    deinit {
        queue.sync {
            tearDownSource()
        }
    }

    // MARK: Public API

    /// Opens the file and installs a kqueue watcher. Safe to call from any thread.
    /// - Throws: An `NSError` wrapping the POSIX error if the file cannot be opened.
    func startWatching() throws {
        var openError: Error?
        queue.sync {
            do {
                try setUpSource()
            } catch {
                openError = error
            }
        }
        if let error = openError { throw error }
    }

    /// Cancels the current watcher. Safe to call from any thread.
    func stopWatching() {
        queue.sync {
            tearDownSource()
        }
    }

    /// Reads and parses the config file synchronously. Returns nil on any error.
    /// Safe to call from any thread.
    func parseConfigFile() -> [SyncTargetConfig]? {
        parseConfigFileInternal()
    }

    // MARK: Private — Source lifecycle (must be called on `queue`)

    /// Opens the file descriptor and installs a new DispatchSource.
    private func setUpSource() throws {
        tearDownSource()

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            let code = Int(errno)
            logger.error("Failed to open fd for \(self.filePath, privacy: .public): errno \(code, privacy: .public)")
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(Int32(code)))]
            )
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.handleEvent(source: newSource)
        }

        newSource.setCancelHandler {
            Darwin.close(fd)
        }

        source = newSource
        newSource.resume()
        logger.info("Watching config file: \(self.filePath, privacy: .public)")
    }

    /// Cancels and nils out the active source (if any). Must be called on `queue`.
    private func tearDownSource() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
    }

    // MARK: Private — Event handling (called on `queue`)

    private func handleEvent(source eventSource: DispatchSourceFileSystemObject) {
        let data = eventSource.data

        let isRenameOrDelete = data.intersection([.rename, .delete]) != []
        let isWrite = data.contains(.write)

        if isRenameOrDelete {
            // The file was atomically replaced (rename) or deleted. The fd is
            // now stale. Tear down and re-open after a brief delay to let the
            // rename complete.
            logger.debug("rename/delete event on config file — re-establishing watcher")
            tearDownSource()
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                do {
                    try self.setUpSource()
                    // Also trigger a parse since the content has changed.
                    self.scheduleDebounce()
                } catch {
                    self.logger.warning("Re-open after rename failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        if isWrite {
            scheduleDebounce()
        }
    }

    /// Schedules a debounced parse 300 ms after the last event fires.
    /// Must be called on `queue`.
    private func scheduleDebounce() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fireHandler()
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Private — Parsing

    /// Parses the file and invokes the handler. Safe to call on any queue.
    private func fireHandler() {
        guard let configs = parseConfigFileInternal() else { return }
        logger.info("Config reloaded: \(configs.count, privacy: .public) target(s)")
        handler(configs)
    }

    /// Reads and decodes the JSON file. Returns nil on any error.
    private func parseConfigFileInternal() -> [SyncTargetConfig]? {
        let url = URL(fileURLWithPath: filePath)
        do {
            let data = try Data(contentsOf: url)
            let configs = try JSONDecoder().decode([SyncTargetConfig].self, from: data)
            return configs
        } catch {
            logger.error("Failed to parse config file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
