import SwiftUI
import SuperBarKit

struct ScriptsSettingsView: View {
    @ObservedObject var app: AppDelegate

    private var grouped: [(String?, [ScriptItem])] {
        let global = app.scripts.filter { $0.scope == nil }
        let scoped = Dictionary(grouping: app.scripts.filter { $0.scope != nil }, by: { $0.scope! })
        return [(nil, global)] + scoped.keys.sorted().map { ($0, scoped[$0]!) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(app.scriptsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Open in Finder") {
                            try? FileManager.default.createDirectory(at: app.scriptsRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(app.scriptsRoot)
                        }
                    }
                }
            } footer: {
                Text("Drop shell scripts or AppleScript files here. Files at the top level appear in every app; files inside a folder named after an app’s bundle identifier (for example com.apple.Safari) appear only in that app. The file name becomes the item’s title. The folder is watched, so changes show up immediately.")
            }

            Section("Loaded Scripts") {
                if app.scripts.isEmpty {
                    Text("No scripts found.").foregroundStyle(.secondary)
                } else {
                    ForEach(grouped, id: \.0) { scope, items in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.map(appName) ?? "All Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(items) { item in
                                HStack {
                                    Image(systemName: "curlybraces.square")
                                    Text(item.title)
                                    Spacer()
                                    Text(item.url.pathExtension.isEmpty ? "executable" : item.url.pathExtension).font(.caption).foregroundStyle(.tertiary)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }

            Section("Environment") {
                Text("Scripts receive SUPERBAR_APP_NAME, SUPERBAR_APP_BUNDLE_ID, SUPERBAR_APP_PID and SUPERBAR_SCRIPT_TITLE. A non-zero exit status shows a notification with the script’s error output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") + "  (\(bundleID))"
        }
        return bundleID
    }
}

struct AboutSettingsView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).padding(.top, 20)
            Text("SuperBar").font(.title.weight(.semibold))
            Text(version).foregroundStyle(.secondary)
            Text("A native command palette for the menu bar of every app.\nFree and open source under the MIT license.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/manuader/super-bar")!)
                Link("Check for Updates", destination: URL(string: "https://github.com/manuader/super-bar/releases")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/manuader/super-bar/issues")!)
            }
            .padding(.top, 6)
            Spacer()
            Text("Inspired by Finbar. Not affiliated with its author.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}
