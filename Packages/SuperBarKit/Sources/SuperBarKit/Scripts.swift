import Foundation

/// A user script exposed as a palette item.
public struct ScriptItem: Hashable, Sendable, Identifiable, Codable {
    public var id: String { url.path }
    public var url: URL
    public var title: String
    /// Bundle identifier the script is limited to, or nil for every app.
    public var scope: String?

    public init(url: URL, title: String, scope: String?) {
        self.url = url
        self.title = title
        self.scope = scope
    }
}

public enum ScriptsLibrary {
    /// `~/Library/Application Scripts/<bundle id>/`
    public static func defaultRoot(bundleIdentifier: String) -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("Application Scripts", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Scans the root folder: files at the top level apply to every app,
    /// files inside a sub-folder named after a bundle identifier apply to
    /// that app only. Titles are file names without extension.
    public static func scan(root: URL, fileManager: FileManager = .default) -> [ScriptItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let top = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        func sorted(_ urls: [URL]) -> [URL] {
            urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        var items: [ScriptItem] = []
        let entries = sorted(top).map { url -> (URL, URLResourceValues?) in (url, try? url.resourceValues(forKeys: Set(keys))) }
        // Global scripts first (top-level files), then per-app folders.
        for (url, values) in entries where values?.isRegularFile == true || url.pathExtension == "scptd" {
            items.append(ScriptItem(url: url, title: title(for: url), scope: nil))
        }
        for (url, values) in entries where values?.isDirectory == true && url.pathExtension != "scptd" {
            let scope = url.lastPathComponent
            guard let inner = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for f in sorted(inner) {
                let v = try? f.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true || f.pathExtension == "scptd" {
                    items.append(ScriptItem(url: f, title: title(for: f), scope: scope))
                }
            }
        }
        return items
    }

    public static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// Scripts that apply to the given app (global ones first).
    public static func items(for bundleIdentifier: String?, in all: [ScriptItem]) -> [ScriptItem] {
        all.filter { $0.scope == nil || $0.scope == bundleIdentifier }
    }
}

/// Decides how to execute a script and runs it asynchronously.
public enum ScriptRunner {
    public struct Launch: Hashable, Sendable {
        public var executable: String
        public var arguments: [String]
        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    public static let appleScriptExtensions: Set<String> = ["scpt", "scptd", "applescript"]

    /// Picks the interpreter: AppleScript files go through `osascript`,
    /// executable files run directly, otherwise the shebang or the extension
    /// decides.
    public static func launch(for url: URL, fileManager: FileManager = .default) -> Launch {
        let ext = url.pathExtension.lowercased()
        if appleScriptExtensions.contains(ext) {
            return Launch(executable: "/usr/bin/osascript", arguments: [url.path])
        }
        if ext == "js" || ext == "jxa" {
            if let (exe, args) = shebang(of: url) { return Launch(executable: exe, arguments: args + [url.path]) }
            return Launch(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", url.path])
        }
        if fileManager.isExecutableFile(atPath: url.path) {
            return Launch(executable: url.path, arguments: [])
        }
        if let (exe, args) = shebang(of: url) {
            return Launch(executable: exe, arguments: args + [url.path])
        }
        switch ext {
        case "sh": return Launch(executable: "/bin/sh", arguments: [url.path])
        case "bash": return Launch(executable: "/bin/bash", arguments: [url.path])
        case "py": return Launch(executable: "/usr/bin/env", arguments: ["python3", url.path])
        case "rb": return Launch(executable: "/usr/bin/env", arguments: ["ruby", url.path])
        case "pl": return Launch(executable: "/usr/bin/env", arguments: ["perl", url.path])
        case "swift": return Launch(executable: "/usr/bin/env", arguments: ["swift", url.path])
        default: return Launch(executable: "/bin/zsh", arguments: [url.path])
        }
    }

    /// Parses `#!/usr/bin/env python3 -u` into ("/usr/bin/env", ["python3", "-u"]).
    public static func shebang(of url: URL) -> (String, [String])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256)
        guard data.count > 2, data[data.startIndex] == 0x23, data[data.startIndex + 1] == 0x21 else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard let exe = parts.first, !exe.isEmpty else { return nil }
        return (exe, Array(parts.dropFirst()))
    }

    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var isSuccess: Bool { exitCode == 0 }
    }

    /// Runs the script off the main thread and reports the result on the main queue.
    public static func run(_ item: ScriptItem, app: AppInfo?, completion: @escaping @Sendable (Result) -> Void) {
        let launch = launch(for: item.url)
        let title = item.title
        let directory = item.url.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = launch.arguments
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["SUPERBAR_SCRIPT_TITLE"] = title
            if let app {
                env["SUPERBAR_APP_NAME"] = app.name
                env["SUPERBAR_APP_BUNDLE_ID"] = app.bundleIdentifier ?? ""
                env["SUPERBAR_APP_PID"] = String(app.pid)
            }
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                let r = Result(exitCode: 127, stdout: "", stderr: error.localizedDescription)
                DispatchQueue.main.async { completion(r) }
                return
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let r = Result(exitCode: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
            DispatchQueue.main.async { completion(r) }
        }
    }
}

/// Watches the scripts folder (recursively) and reports changes, coalesced.
public final class ScriptsWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    public init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ScriptsWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func fire() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }
}
