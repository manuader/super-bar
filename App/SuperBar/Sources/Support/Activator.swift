import AppKit
import SuperBarKit

/// Performs the action behind a palette row and records it in the recents.
@MainActor
final class Activator {
    private let source: MenuSource
    private let recents: RecentsStore
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.actions", qos: .userInteractive)

    init(source: MenuSource, recents: RecentsStore) {
        self.source = source
        self.recents = recents
    }

    func press(_ node: MenuNode, app: AppInfo, running: NSRunningApplication?, completion: @escaping @Sendable (Error?) -> Void) {
        recents.record(appKey: app.storageKey, titlePath: node.path, indexPath: node.indexPath)
        let source = self.source
        queue.async {
            do {
                try source.press(node, in: app)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                // Some apps (Electron, JetBrains) only accept presses while active.
                DispatchQueue.main.async {
                    running?.activate(options: [])
                    self.queue.asyncAfter(deadline: .now() + 0.15) {
                        do {
                            try source.press(node, in: app)
                            DispatchQueue.main.async { completion(nil) }
                        } catch {
                            DispatchQueue.main.async { completion(error) }
                        }
                    }
                }
            }
        }
    }

    func reveal(_ node: MenuNode, app: AppInfo, completion: @escaping @Sendable (Error?) -> Void) {
        let source = self.source
        // Opening a menu can block until it closes; keep the serial action queue free.
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                try source.reveal(node, in: app)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func searchHelp(query: String, app: AppInfo, completion: @escaping @Sendable (Error?) -> Void) {
        let source = self.source
        queue.async {
            do {
                try source.searchHelpMenu(query: query, in: app)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func run(_ script: ScriptItem, app: AppInfo?, completion: @escaping @Sendable (ScriptRunner.Result) -> Void) {
        if let app { recents.record(appKey: app.storageKey, titlePath: [script.title], indexPath: [], isScript: true) }
        ScriptRunner.run(script, app: app) { result in
            Task { @MainActor in completion(result) }
        }
    }
}
