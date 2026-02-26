import Foundation
import os

// MARK: - DirectoryWatcher

/// Watches one or more directories for newly created `.md` files using
/// `DispatchSource.makeFileSystemObjectSource`. Designed for use inside the
/// App Sandbox; the caller is responsible for starting/stopping
/// security-scoped resource access on every URL passed to `watch(_:)`.
final class DirectoryWatcher: @unchecked Sendable {

    // MARK: Types

    /// Called on a background queue whenever a new `.md` file is detected.
    /// - Parameters:
    ///   - fileURL: The full URL of the newly detected `.md` file.
    ///   - directoryURL: The watched directory in which the file was found.
    typealias Handler = @Sendable (URL, URL) -> Void

    // MARK: Private State (all guarded by `queue`)

    /// Serial queue that serialises all file-system operations and state mutations.
    private let queue = DispatchQueue(label: "com.clevique.Toukan.DirectoryWatcher")

    /// Active `DispatchSource` keyed by the directory URL being watched.
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]

    /// Last-known set of `.md` file names (lastPathComponent) per directory.
    private var snapshots: [URL: Set<String>] = [:]

    /// Caller-supplied callback.
    private let handler: Handler

    private let logger = Logger(subsystem: "com.clevique.Toukan", category: "DirectoryWatcher")

    // MARK: Lifecycle

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        // Cancel synchronously on the serial queue so that all cancel handlers
        // (which close file descriptors) complete before the object is freed.
        queue.sync {
            for (_, source) in sources {
                source.cancel()
            }
            sources.removeAll()
            snapshots.removeAll()
        }
    }

    // MARK: Public API

    /// Start watching `directoryURL` for new `.md` files.
    ///
    /// The URL must already be accessible (i.e. the caller has invoked
    /// `startAccessingSecurityScopedResource()` on it before calling this method).
    ///
    /// Calling `watch(_:)` on an already-watched directory is a no-op.
    ///
    /// - Throws: An `NSError` wrapping the POSIX error code if the directory
    ///   file descriptor cannot be opened.
    func watch(_ directoryURL: URL) throws {
        // Resolve symlinks so the URL is canonical.
        let url = directoryURL.resolvingSymlinksInPath()

        // `open()` is available via Darwin / Foundation without a separate import.
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            let code = Int(errno)
            logger.error("Failed to open fd for \(url.path, privacy: .public): errno \(code, privacy: .public)")
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(Int32(code)))]
            )
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        // Capture the initial snapshot and install the event handler.
        queue.sync {
            guard sources[url] == nil else {
                // Already watching — close the fd we just opened and bail out.
                Darwin.close(fd)
                logger.debug("Already watching \(url.path, privacy: .public) — ignoring duplicate watch() call")
                return
            }

            snapshots[url] = currentMDFiles(in: url)
            sources[url] = source

            source.setEventHandler { [weak self] in
                self?.handleEvent(for: url)
            }

            source.setCancelHandler {
                Darwin.close(fd)
            }

            source.resume()
            logger.info("Started watching directory: \(url.path, privacy: .public)")
        }
    }

    /// Stop watching a specific directory.
    func stopWatching(_ directoryURL: URL) {
        let url = directoryURL.resolvingSymlinksInPath()
        queue.sync {
            cancelSource(for: url)
        }
    }

    /// Stop watching all directories.
    func stopAll() {
        queue.sync {
            let urls = Array(sources.keys)
            for url in urls {
                cancelSource(for: url)
            }
        }
    }

    /// Scans the directory for existing .md files and invokes the handler for each.
    /// Used at startup or after config reload to process files already present.
    func scanExistingFiles(in directoryURL: URL) {
        let url = directoryURL.resolvingSymlinksInPath()
        queue.async { [weak self] in
            guard let self else { return }
            let files = currentMDFiles(in: url)
            for fileName in files {
                let fileURL = url.appendingPathComponent(fileName)
                logger.info("Scan: existing .md file found: \(fileURL.path, privacy: .public)")
                handler(fileURL, url)
            }
        }
    }

    // MARK: Private Helpers (must be called on `queue`)

    /// Cancels and removes the source for `url`. Must be called on `queue`.
    private func cancelSource(for url: URL) {
        guard let source = sources.removeValue(forKey: url) else { return }
        snapshots.removeValue(forKey: url)
        source.cancel()
        logger.info("Stopped watching directory: \(url.path, privacy: .public)")
    }

    /// Called by the `DispatchSource` event handler. Must be called on `queue`.
    private func handleEvent(for directoryURL: URL) {
        let previous = snapshots[directoryURL] ?? []
        let current = currentMDFiles(in: directoryURL)

        let added = current.subtracting(previous)

        if !added.isEmpty {
            logger.debug("\(added.count, privacy: .public) new .md file(s) detected in \(directoryURL.path, privacy: .public)")
        }

        // Update snapshot before dispatching so that rapid successive events
        // don't trigger duplicate notifications for the same file.
        snapshots[directoryURL] = current

        for fileName in added {
            let fileURL = directoryURL.appendingPathComponent(fileName)

            // Wait 0.5 s for the write to complete before notifying the caller,
            // matching the behaviour of the Python watchdog implementation.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                logger.info("New .md file ready: \(fileURL.path, privacy: .public)")
                handler(fileURL, directoryURL)
            }
        }
    }

    /// Returns the set of `.md` file names (lastPathComponent) currently present
    /// directly inside `directoryURL`. Only top-level regular files with a `.md`
    /// extension are included; subdirectories (including any archive directory)
    /// are excluded by the `isRegularFile` check. The extension check is case-insensitive.
    private func currentMDFiles(in directoryURL: URL) -> Set<String> {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("contentsOfDirectory failed for \(directoryURL.path, privacy: .public)")
            return []
        }

        var result = Set<String>()
        for itemURL in contents {
            // Only accept regular `.md` files.
            // Subdirectories (including the archive directory) are excluded
            // by the isRegularFile check below.
            guard
                itemURL.pathExtension.lowercased() == "md",
                (try? itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }

            result.insert(itemURL.lastPathComponent)
        }
        return result
    }
}
