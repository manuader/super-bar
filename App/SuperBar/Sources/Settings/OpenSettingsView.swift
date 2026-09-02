import SwiftUI
import SuperBarKit

/// Settings for the `open` command: where folders open, what is indexed, and
/// which app opens each kind of file.
struct OpenSettingsView: View {
    @ObservedObject var app: AppDelegate
    @EnvironmentObject var prefs: Preferences
    @State private var selectedRoot: String?
    @State private var ignoreText = ""
    @State private var ignoreDirty = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable the “open” command", isOn: Binding(get: { prefs.openCommandEnabled }, set: { prefs.openCommandEnabled = $0 }))
                Picker("Folders open in", selection: Binding(get: { prefs.folderOpenBehavior }, set: { prefs.folderOpenBehavior = $0 })) {
                    ForEach(FolderOpenBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.openCommandEnabled)
            } header: {
                Text("Open Command")
            } footer: {
                Text("Type “open ” followed by part of a name in any app. Matching folders are listed first, then files. A new Finder tab needs permission to control Finder the first time.")
            }

            Section {
                LabeledContent("Index", value: app.fileIndexSummary)
                List(selection: $selectedRoot) {
                    ForEach(prefs.fileIndexExtraRoots, id: \.self) { path in
                        Label(FileEntry.abbreviate(path), systemImage: "folder")
                            .tag(path)
                    }
                }
                .frame(height: 96)
                .overlay {
                    if prefs.fileIndexExtraRoots.isEmpty {
                        Text("Your home folder and the places you work in are indexed automatically.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
                HStack(spacing: 0) {
                    Button { addRoot() } label: { Image(systemName: "plus") }
                    Button { removeRoot() } label: { Image(systemName: "minus") }.disabled(selectedRoot == nil)
                    Spacer()
                    Button("Rebuild Now") { app.fileIndex.rebuild() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Toggle("Include hidden files and folders", isOn: Binding(get: { prefs.fileIndexIncludesHidden }, set: { prefs.fileIndexIncludesHidden = $0; app.fileIndex.rebuild() }))
            } header: {
                Text("Indexed Locations")
            } footer: {
                Text("SuperBar indexes the folders you actually work in: opening something raises the score of its whole folder chain, and a hot folder is then crawled deeply, so even its rarely used subfolders are found instantly. Add a folder here to index it regardless of use.")
            }

            Section {
                TextEditor(text: $ignoreText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 150)
                    .onChange(of: ignoreText) { _, _ in ignoreDirty = true }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                HStack {
                    Button("Restore Defaults") {
                        ignoreText = IgnoreList.defaultText
                        ignoreDirty = true
                    }
                    Spacer()
                    Button("Save and Rebuild Index") {
                        prefs.fileIndexIgnoreList = ignoreText == IgnoreList.defaultText ? "" : ignoreText
                        ignoreDirty = false
                        app.fileIndex.rebuild()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ignoreDirty)
                }
            } header: {
                Text("Ignored Folders")
            } footer: {
                Text("Dependency and build folders are never indexed, so node_modules, Pods, DerivedData, .venv and the like stay out of your results. The syntax follows .gitignore: a bare name matches anywhere, a trailing slash means folders only, * globs, a leading slash matches one exact location and ! puts something back. Later lines win.")
            }

            Section {
                if prefs.fileTypeHandlers.choices.isEmpty {
                    Text("No file types configured yet. The first time you open a kind of file, SuperBar asks which app to use and remembers it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.fileTypeHandlers.sortedKeys, id: \.self) { key in
                        if let choice = prefs.fileTypeHandlers.choices[key] {
                            HStack {
                                if let path = choice.applicationPath {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(FileTypeHandlers.describe(key))
                                    Text(choice.applicationName ?? "System default").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { remove(key) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button("Forget All File Types") {
                        var handlers = prefs.fileTypeHandlers
                        handlers.removeAll()
                        prefs.fileTypeHandlers = handlers
                    }
                }
            } header: {
                Text("File Types")
            } footer: {
                Text("Press ⌥↩ on a file to pick a different app and replace the saved choice.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ignoreText = prefs.fileIndexIgnoreList.isEmpty ? IgnoreList.defaultText : prefs.fileIndexIgnoreList
            ignoreDirty = false
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Index"
        guard panel.runModal() == .OK else { return }
        var roots = prefs.fileIndexExtraRoots
        for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
        prefs.fileIndexExtraRoots = roots
        app.fileIndex.rebuild()
    }

    private func removeRoot() {
        guard let selectedRoot else { return }
        prefs.fileIndexExtraRoots.removeAll { $0 == selectedRoot }
        self.selectedRoot = nil
        app.fileIndex.rebuild()
    }

    private func remove(_ key: String) {
        var handlers = prefs.fileTypeHandlers
        handlers.remove(for: key)
        prefs.fileTypeHandlers = handlers
    }
}
