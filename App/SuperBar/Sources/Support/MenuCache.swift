import AppKit
import SuperBarKit

/// Keeps one snapshot per application and refreshes it in the background.
/// Loading streams top-level menus so the palette becomes usable before the
/// whole tree is known.
@MainActor
final class MenuCache {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(MenuSourceError)
    }

    struct Entry {
        var snapshot: MenuSnapshot?
        var state: State
        var partialRoots: [MenuNode] = []
    }

    private let source: MenuSource
    private var entries: [Int32: Entry] = [:]
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.menus", qos: .userInitiated)
    private var generation: [Int32: Int] = [:]
    /// Snapshots older than this are refreshed when the palette opens.
    var staleInterval: TimeInterval = 20

    var onUpdate: ((AppInfo, Entry) -> Void)?

    init(source: MenuSource) {
        self.source = source
    }

    func entry(for app: AppInfo) -> Entry? { entries[app.pid] }

    func forget(pid: Int32) {
        entries[pid] = nil
    }

    func invalidateAll() {
        for pid in entries.keys { entries[pid]?.snapshot = nil; entries[pid]?.state = .idle }
    }

    /// Returns the cached snapshot immediately (if any) and refreshes when stale.
    @discardableResult
    func load(app: AppInfo, force: Bool = false) -> Entry {
        var entry = entries[app.pid] ?? Entry(snapshot: nil, state: .idle)
        let stale = entry.snapshot.map { Date().timeIntervalSince($0.createdAt) > staleInterval } ?? true
        if entry.state == .loading && !force {
            return entry
        }
        if !force && !stale, entry.snapshot != nil {
            return entry
        }
        entry.state = entry.snapshot == nil ? .loading : .ready
        entry.partialRoots = []
        entries[app.pid] = entry
        let gen = (generation[app.pid] ?? 0) + 1
        generation[app.pid] = gen
        let source = self.source
        queue.async { [weak self] in
            var roots: [MenuNode] = []
            do {
                let result = try source.loadMenuBar(for: app) { node in
                    roots.append(node)
                    let partial = roots
                    DispatchQueue.main.async {
                        guard let self, self.generation[app.pid] == gen else { return }
                        self.entries[app.pid]?.partialRoots = partial
                        if let e = self.entries[app.pid] { self.onUpdate?(app, e) }
                    }
                }
                let snapshot = MenuSnapshot(app: app, roots: result)
                DispatchQueue.main.async {
                    guard let self, self.generation[app.pid] == gen else { return }
                    self.entries[app.pid] = Entry(snapshot: snapshot, state: .ready)
                    self.onUpdate?(app, self.entries[app.pid]!)
                }
            } catch let error as MenuSourceError {
                DispatchQueue.main.async {
                    guard let self, self.generation[app.pid] == gen else { return }
                    var e = self.entries[app.pid] ?? Entry(snapshot: nil, state: .idle)
                    e.state = .failed(error)
                    self.entries[app.pid] = e
                    self.onUpdate?(app, e)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation[app.pid] == gen else { return }
                    var e = self.entries[app.pid] ?? Entry(snapshot: nil, state: .idle)
                    e.state = .failed(.actionFailed(error.localizedDescription))
                    self.entries[app.pid] = e
                    self.onUpdate?(app, e)
                }
            }
        }
        return entry
    }
}

extension AppInfo {
    init(running app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "App")
    }
}
