import SwiftUI
import SuperBarKit

struct AppearanceSettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @State private var editingTheme: Theme?

    var body: some View {
        Form {
            Section {
                Picker("Light appearance", selection: Binding(get: { prefs.selectedLightTheme }, set: { prefs.selectedLightTheme = $0 })) {
                    ForEach(prefs.allThemes) { theme in Text(theme.name).tag(theme.id) }
                }
                Picker("Dark appearance", selection: Binding(get: { prefs.selectedDarkTheme }, set: { prefs.selectedDarkTheme = $0 })) {
                    ForEach(prefs.allThemes) { theme in Text(theme.name).tag(theme.id) }
                }
            } header: {
                Text("Themes")
            } footer: {
                Text("System themes follow your accent colour and use a translucent material. Classic palettes are opaque.")
            }

            Section {
                ForEach(prefs.customThemes) { theme in
                    HStack {
                        ThemeSwatch(theme: theme)
                        Text(theme.name)
                        Spacer()
                        Button("Edit…") { editingTheme = theme }
                        Button(role: .destructive) { delete(theme) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
                Menu("New Theme Based On…") {
                    ForEach(BuiltInThemes.all) { base in
                        Button(base.name) { create(from: base) }
                    }
                }
            } header: {
                Text("Custom Themes")
            }

            Section("Rows") {
                Picker("Text size", selection: Binding(get: { prefs.rowTextSize }, set: { prefs.rowTextSize = $0 })) {
                    Text("Regular").tag(RowTextSize.regular)
                    Text("Large").tag(RowTextSize.large)
                    Text("Extra Large").tag(RowTextSize.extraLarge)
                }
                Toggle("Show item paths", isOn: Binding(get: { prefs.showSubtitles }, set: { prefs.showSubtitles = $0 }))
                Toggle("Show item counts on menus", isOn: Binding(get: { prefs.showCountBadge }, set: { prefs.showCountBadge = $0 }))
                LabeledContent("Window width") {
                    HStack {
                        Slider(value: Binding(get: { prefs.windowWidth }, set: { prefs.windowWidth = ($0 / 10).rounded() * 10 }), in: 480...1200, step: 10)
                        Text("\(Int(prefs.windowWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Button("Reset Window Position") { prefs.resetWindowPosition() }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingTheme) { theme in
            ThemeEditor(theme: theme) { updated in
                if let i = prefs.customThemes.firstIndex(where: { $0.id == updated.id }) {
                    prefs.customThemes[i] = updated
                } else {
                    prefs.customThemes.append(updated)
                }
                editingTheme = nil
            } onCancel: { editingTheme = nil }
        }
    }

    private func create(from base: Theme) {
        let theme = base.customCopy(named: "\(base.name) Copy")
        prefs.customThemes.append(theme)
        editingTheme = theme
    }

    private func delete(_ theme: Theme) {
        prefs.customThemes.removeAll { $0.id == theme.id }
        if prefs.selectedLightTheme == theme.id { prefs.selectedLightTheme = Theme.systemLightID }
        if prefs.selectedDarkTheme == theme.id { prefs.selectedDarkTheme = Theme.systemDarkID }
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    var body: some View {
        HStack(spacing: 2) {
            ForEach([theme.background, theme.selection, theme.accent, theme.text], id: \.hex) { c in
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: NSColor(c))).frame(width: 12, height: 16)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
    }
}

struct ThemeEditor: View {
    @State var theme: Theme
    let onSave: (Theme) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $theme.name)
                    Toggle("Dark theme (uses dark controls)", isOn: $theme.isDark)
                }
                Section("Colours") {
                    colorRow("Background", \.background)
                    colorRow("Text", \.text)
                    colorRow("Secondary text", \.secondaryText)
                    colorRow("Selection", \.selection)
                    colorRow("Selected text", \.selectionText)
                    colorRow("Badge background", \.badgeBackground)
                    colorRow("Badge text", \.badgeText)
                    colorRow("Accent (icons, quick selection)", \.accent)
                    colorRow("Separators", \.separator)
                }
                Section("Preview") {
                    ThemePreview(theme: theme)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(theme) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 480, height: 620)
    }

    private func colorRow(_ label: String, _ keyPath: WritableKeyPath<Theme, ThemeColor>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: NSColor(theme[keyPath: keyPath])) },
            set: { theme[keyPath: keyPath] = NSColor($0).themeColor }
        ), supportsOpacity: true)
    }
}

struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Format", count: "21", selected: false)
            row("Font › Bold", key: "⌘B", quick: "⌘2", selected: true)
            row("Font › Italic", key: "⌘I", quick: "⌘3", selected: false)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(theme.background))))
    }

    private func row(_ title: String, count: String? = nil, key: String? = nil, quick: String? = nil, selected: Bool) -> some View {
        let text = Color(nsColor: NSColor(selected ? theme.selectionText : theme.text))
        return HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(Color(nsColor: NSColor(selected ? theme.selectionText : theme.accent)))
            Text(title).foregroundStyle(text)
            if let count { badge(count, selected: selected) }
            Spacer()
            if let key { badge(key, selected: selected) }
            if let quick { Label(quick, systemImage: "bolt.fill").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(Color(nsColor: NSColor(selected ? theme.selectionText : theme.accent)))
                .background(Capsule().fill(Color(nsColor: NSColor(selected ? theme.selectionText.withAlpha(0.22) : theme.accent.withAlpha(0.16))))) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: NSColor(theme.selection)) : .clear))
    }

    private func badge(_ text: String, selected: Bool) -> some View {
        Text(text).font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Color(nsColor: NSColor(selected ? theme.selectionText : theme.badgeText)))
            .background(Capsule().fill(Color(nsColor: NSColor(selected ? theme.selectionText.withAlpha(0.22) : theme.badgeBackground))))
    }
}
