import AppKit
import SuperBarKit

/// Owns the file index: decides what to crawl, keeps it warm, answers searches
/// off the main thread and persists it so the first `open` after launch is
/// instant.
///
/// The crawl budget follows the user: directories they work in get deep,
/// watched coverage, everything else stays shallow.
@MainActor
final class FileIndexService {
    enum State: Equatable {
        case idle          // nothing indexed yet
        case indexing
        case ready
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var snapshot = FileIndexSnapshot()
    let heat: WorkspaceHeat
    private let preferences: Preferences

    /// Serial: crawling, heat recomputation and searching never overlap.
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.fileindex", qos: .userInitiated)
    private var generation = 0
    private var runningCrawl: FileIndexer.Cancellation?
    private var searchGeneration = 0
    private var watchers: [FSEventStreamRef] = []
    private var watchedRoots: [String] = []
    private var refreshWorkItem: DispatchWorkItem?
    private var lastPlan: [IndexRoot] = []
    private var lastHeatVersion = -1

    var onChange: (() -> Void)?

    /// `cacheURL` is nil for transient instances (tests, snapshots, diagnostics)
    /// so they never clobber the installed app's index.
    private let cacheURL: URL?

    init(preferences: Preferences, heatFileURL: URL?, cacheURL: URL?) {
        self.preferences = preferences
        self.cacheURL = cacheURL
        heat = WorkspaceHeat(fileURL: heatFileURL)
    }

    // MARK: Lifecycle

    /// Loads the cached index, then refreshes in the background. Called the
    /// first time the user opens the `open` command, so that permission
    /// prompts for Desktop/Documents appear in context.
    func activate() {
        guard state == .idle else {
            refreshIfNeeded()
            return
        }
        state = .indexing
        let cacheURL = self.cacheURL
        queue.async { [weak self] in
            if let cacheURL, let cached = FileIndexStore.load(from: cacheURL), cached.count > 0 {
                Task { @MainActor in
                    guard let self, self.state == .indexing else { return }
                    self.snapshot = cached
                    self.state = .ready
                    self.onChange?()
                }
            }
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Recrawls from scratch.
    func rebuild() {
        generation += 1
        let token = generation
        runningCrawl?.cancel()
        let cancellation = FileIndexer.Cancellation()
        runningCrawl = cancellation
        if state != .ready { state = .indexing }
        let heatScores = heat.allScores()
        let cacheURL = self.cacheURL
        let extraRoots = preferences.fileIndexExtraRoots
        let includeHidden = preferences.fileIndexIncludesHidden
        let ignore = preferences.effectiveIgnoreList
        let heatStore = heat
        lastHeatVersion = heat.version
        queue.async { [weak self] in
            let plan = FileIndexer.plan(heat: heatStore, extraRoots: extraRoots, ignore: ignore)
            let result = FileIndexer.crawl(roots: plan, includeHidden: includeHidden, ignore: ignore, cancellation: cancellation)
            if cancellation.isCancelled { return }
            let resolver = HeatResolver(heat: heatScores)
            var directories = FileTable(entries: result.directories)
            var files = FileTable(entries: result.files)
            directories.applyHeat { resolver.score(for: $0) }
            files.applyHeat { resolver.score(for: $0) }
            let snapshot = FileIndexSnapshot(directories: directories, files: files, isPartial: result.hitBudget)
            if let cache = cacheURL { FileIndexStore.save(snapshot, to: cache) }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.snapshot = snapshot
                self.lastPlan = plan
                self.state = snapshot.count > 0 ? .ready : .unavailable("No readable folders were found.")
                self.watch(plan.map(\.path))
                Log.files.notice("indexed \(snapshot.count) paths from \(plan.count) roots")
                self.onChange?()
            }
        }
    }

    /// Cheap refresh: only recomputes the heat column unless the plan changed.
    func refreshIfNeeded() {
        guard state == .ready else { return }
        if heat.version != lastHeatVersion {
            lastHeatVersion = heat.version
            let scores = heat.allScores()
            let current = snapshot
            let token = generation
            queue.async { [weak self] in
                let resolver = HeatResolver(heat: scores)
                var updated = current
                updated.directories.applyHeat { resolver.score(for: $0) }
                updated.files.applyHeat { resolver.score(for: $0) }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.snapshot = updated
                    self.onChange?()
                }
            }
            // A newly hot directory may deserve a deeper crawl.
            scheduleRefresh(after: 2)
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildIfPlanChanged() }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rebuildIfPlanChanged() {
        let plan = FileIndexer.plan(heat: heat, extraRoots: preferences.fileIndexExtraRoots, ignore: preferences.effectiveIgnoreList)
        guard plan != lastPlan else { return }
        rebuild()
    }

    // MARK: Recording use

    /// The user opened something: heat its folder chain and keep the index warm.
    func record(_ entry: FileEntry) {
        heat.record(path: entry.path, isDirectory: entry.isDirectory)
        refreshIfNeeded()
    }

    // MARK: Searching

    /// Searches off the main thread; the completion runs on the main actor and
    /// is skipped when a newer search has started.
    func search(_ text: String, limit: Int = 25, completion: @escaping @MainActor @Sendable (String, FileIndexSnapshot.Results) -> Void) {
        searchGeneration += 1
        let token = searchGeneration
        let snapshot = self.snapshot
        let query = FileQuery(text)
        queue.async { [weak self] in
            let results = snapshot.search(query, limit: limit)
            Task { @MainActor in
                guard let self, self.searchGeneration == token else { return }
                completion(text, results)
            }
        }
    }

    // MARK: Watching

    private func watch(_ roots: [String]) {
        guard roots != watchedRoots else { return }
        stopWatching()
        watchedRoots = roots
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let service = Unmanaged<FileIndexService>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in service.filesystemChanged() }
        }
        // Directory-level events only: cheap, and enough to know a recrawl is due.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        watchers = [stream]
    }

    private func stopWatching() {
        for stream in watchers {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        watchers = []
    }

    private func filesystemChanged() {
        // Coalesce bursts (a build, a git checkout) into one recrawl.
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    deinit { for stream in watchers { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }

    nonisolated static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SuperBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("file-index.txt")
    }
}

/// Plain-text index cache: one line per entry, `d|f` + depth + path. Parsing a
/// flat file beats re-crawling the disk at launch by an order of magnitude.
enum FileIndexStore {
    static func save(_ snapshot: FileIndexSnapshot, to url: URL) {
        var text = String()
        text.reserveCapacity(snapshot.count * 48)
        for entry in snapshot.directories.entries { text += "d\(entry.depth)\t\(entry.path)\n" }
        for entry in snapshot.files.entries { text += "f\(entry.depth)\t\(entry.path)\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func load(from url: URL) -> FileIndexSnapshot? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var directories: [FileEntry] = []
        var files: [FileEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let head = line[line.startIndex..<tab]
            let path = String(line[line.index(after: tab)...])
            guard let kind = head.first, let depth = Int(head.dropFirst()) else { continue }
            let entry = FileEntry(path: path, isDirectory: kind == "d", depth: depth)
            if kind == "d" { directories.append(entry) } else { files.append(entry) }
        }
        guard !directories.isEmpty || !files.isEmpty else { return nil }
        return FileIndexSnapshot(directories: FileTable(entries: directories), files: FileTable(entries: files))
    }
}
