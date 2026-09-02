import AppKit
import UniformTypeIdentifiers
import SuperBarKit

/// Opens folders in Finder and files in the app the user picked for that type.
@MainActor
final class Opener {
    /// AppleScript talking to Finder must not block the main thread.
    private let queue = DispatchQueue(label: "com.manuader.SuperBar.opener", qos: .userInitiated)

    enum Failure: LocalizedError {
        case finderScript(String)
        case cannotOpen(String)
        var errorDescription: String? {
            switch self {
            case .finderScript(let reason): return reason
            case .cannotOpen(let reason): return reason
            }
        }
    }

    // MARK: Folders

    /// Opens `url` in Finder, honouring the user's preferred window behaviour.
    /// A new tab is created by sending ⌘T to Finder (Accessibility, which
    /// SuperBar already has) and then retargeting the front window, because
    /// Finder's scripting interface has no notion of tabs.
    func openFolder(_ url: URL, behavior: FolderOpenBehavior, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        let path = url.path
        queue.async {
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            let hasWindows = finder.map { Opener.windowCount(of: $0.processIdentifier) > 0 } ?? false
            if let bundleURL = finder?.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)
            }
            Thread.sleep(forTimeInterval: hasWindows ? 0.12 : 0)

            var script: String
            switch behavior {
            case .newTab where hasWindows:
                Opener.sendCommandT(to: finder?.processIdentifier)
                Thread.sleep(forTimeInterval: 0.18)
                script = Opener.retargetFrontWindow(path)
            case .reuseWindow where hasWindows:
                script = Opener.retargetFrontWindow(path)
            default:
                script = Opener.makeNewWindow(path)
            }

            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "Finder did not respond."
                // Fall back to the plain open, which never needs automation access.
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    completion(Failure.finderScript("Opened in Finder without a new tab: \(message)"))
                }
                return
            }
            Task { @MainActor in completion(nil) }
        }
    }

    nonisolated private static func retargetFrontWindow(_ path: String) -> String {
        """
        tell application "Finder"
            activate
            set superbarTarget to POSIX file "\(escape(path))" as alias
            if (count of Finder windows) is 0 then
                make new Finder window to superbarTarget
            else
                set target of front Finder window to superbarTarget
            end if
        end tell
        """
    }

    nonisolated private static func makeNewWindow(_ path: String) -> String {
        """
        tell application "Finder"
            activate
            make new Finder window to (POSIX file "\(escape(path))" as alias)
        end tell
        """
    }

    nonisolated private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func sendCommandT(to pid: pid_t?) {
        guard let pid else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: true)   // "t"
        let up = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.postToPid(pid)
        usleep(30_000)
        up?.postToPid(pid)
    }

    nonisolated private static func windowCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return 0 }
        return (value as? [AnyObject])?.count ?? 0
    }

    // MARK: Files

    /// Applications able to open `url`, the system default first, each icon
    /// rasterised so rows draw immediately.
    func handlers(for url: URL) -> [AppHandler] {
        let workspace = NSWorkspace.shared
        // Resolve by content type, not by URL: the choice is remembered for the
        // whole file type, and this also works for paths that no longer exist.
        let ext = url.pathExtension.lowercased()
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let systemDefault = type.flatMap { workspace.urlForApplication(toOpen: $0) } ?? workspace.urlForApplication(toOpen: url)
        let candidates = type.map { workspace.urlsForApplications(toOpen: $0) } ?? workspace.urlsForApplications(toOpen: url)

        var seen = Set<String>()
        var handlers: [AppHandler] = []
        if let systemDefault, seen.insert(systemDefault.path).inserted {
            handlers.append(AppHandler(url: systemDefault, isSystemDefault: true))
        }
        for candidate in candidates where seen.insert(candidate.path).inserted {
            handlers.append(AppHandler(url: candidate, isSystemDefault: false))
        }
        handlers.append(.browse)
        return handlers
    }

    /// Opens a file with the app remembered for its type, or with `handler`.
    func openFile(_ url: URL, choice: FileHandlerChoice?, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let appURL = choice?.applicationURL, FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                Task { @MainActor in completion(error) }
            }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                Task { @MainActor in completion(error) }
            }
        }
    }
}

/// An application offered as a handler for a file type.
struct AppHandler: Hashable {
    let url: URL?
    let isSystemDefault: Bool
    let name: String
    let icon: NSImage?

    /// The "Choose Another App…" row.
    static let browse = AppHandler(url: nil, isSystemDefault: false, name: "Choose Another App…", icon: NSImage.symbol("ellipsis.circle", pointSize: 15))

    init(url: URL?, isSystemDefault: Bool, name: String, icon: NSImage?) {
        self.url = url
        self.isSystemDefault = isSystemDefault
        self.name = name
        self.icon = icon
    }

    init(url: URL, isSystemDefault: Bool) {
        self.url = url
        self.isSystemDefault = isSystemDefault
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        icon = RunningApp.rasterize(NSWorkspace.shared.icon(forFile: url.path))
    }

    var isBrowse: Bool { url == nil }
    var bundleIdentifier: String? { url.flatMap { Bundle(url: $0)?.bundleIdentifier } }
    var choice: FileHandlerChoice? {
        guard let url else { return nil }
        return FileHandlerChoice(applicationPath: url.path, bundleIdentifier: bundleIdentifier)
    }
}
