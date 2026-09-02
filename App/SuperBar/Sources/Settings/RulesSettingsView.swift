import SwiftUI
import AppKit
import SuperBarKit

struct RulesSettingsView: View {
    @ObservedObject var app: AppDelegate
    @EnvironmentObject var prefs: Preferences
    @State private var selection: UUID?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(prefs.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { on in update(rule.id) { $0.isEnabled = on } }))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name)
                                Text(rule.predicateFormat).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(rule.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { edit(rule) }
                    }
                }
                .frame(minHeight: 200)
                .overlay {
                    if prefs.rules.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease.circle").font(.title).foregroundStyle(.tertiary)
                            Text("No rules yet").foregroundStyle(.secondary)
                            Text("Rules hide menu items you never use, so search results stay relevant.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                    Button("Edit…") { if let rule = prefs.rules.first(where: { $0.id == selection }) { edit(rule) } }.disabled(selection == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } header: {
                Text("Exclusion Rules")
            } footer: {
                Text("A menu item that matches a rule (and everything inside it) is excluded from search. Paths are backslash-separated (View\\Translation); index counts separators; depth is 0 for menu bar items.")
            }
        }
        .formStyle(.grouped)
    }

    private func update(_ id: UUID, _ change: (inout Rule) -> Void) {
        guard let i = prefs.rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = prefs.rules[i]
        change(&rule)
        prefs.rules[i] = rule
    }

    private func add() {
        let rule = (try? Rule(name: "Rule \(prefs.rules.count + 1)", predicate: NSPredicate(format: "title ==[cd] %@", "Apple"))) ?? nil
        guard let rule else { return }
        RuleEditorSheet.present(rule: rule, isNew: true, in: NSApp.keyWindow) { result in
            if let result { prefs.rules.append(result); selection = result.id }
        }
    }

    private func edit(_ rule: Rule) {
        RuleEditorSheet.present(rule: rule, isNew: false, in: NSApp.keyWindow) { result in
            if let result { update(rule.id) { $0 = result } }
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        prefs.rules.removeAll { $0.id == selection }
        self.selection = nil
    }
}

/// AppKit sheet wrapping `NSPredicateEditor` with the criteria Finbar users know.
@MainActor
final class RuleEditorSheet: NSObject {
    private static var active: RuleEditorSheet?
    private let window: NSWindow
    private let nameField = NSTextField()
    private let editor = NSPredicateEditor()
    private let completion: (Rule?) -> Void
    private let rule: Rule

    static func present(rule: Rule, isNew: Bool, in parent: NSWindow?, completion: @escaping (Rule?) -> Void) {
        let sheet = RuleEditorSheet(rule: rule, completion: completion)
        active = sheet
        if let parent {
            parent.beginSheet(sheet.window) { _ in active = nil }
        } else {
            sheet.window.center()
            sheet.window.makeKeyAndOrderFront(nil)
        }
    }

    private init(rule: Rule, completion: @escaping (Rule?) -> Void) {
        self.rule = rule
        self.completion = completion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Edit Rule"
        window.minSize = NSSize(width: 520, height: 320)
        super.init()
        build()
    }

    private func build() {
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let nameLabel = NSTextField(labelWithString: "Rule Description")
        nameField.stringValue = rule.name
        nameField.placeholderString = "Rule name"
        let explanation = NSTextField(labelWithString: "Exclude a menu item (and any menu items contained inside) from search, if:")
        explanation.font = .systemFont(ofSize: 13)

        editor.rowTemplates = RuleEditorSheet.templates
        editor.nestingMode = .compound
        editor.canRemoveAllRows = false
        editor.objectValue = rule.predicate ?? NSPredicate(format: "title ==[cd] %@", "Apple")
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        editor.autoresizingMask = [.width]

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        ok.keyEquivalent = "\r"
        let help = NSButton(title: "", target: self, action: #selector(openHelp))
        help.bezelStyle = .helpButton

        for v in [nameLabel, nameField, explanation, scroll, cancel, ok, help] { content.addSubview(v) }
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false
        ok.translatesAutoresizingMaskIntoConstraints = false
        help.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            nameLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            explanation.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -16),
            help.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            help.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancel.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -10),
            cancel.bottomAnchor.constraint(equalTo: ok.bottomAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    /// Row templates: string criteria with the operators users expect, integer
    /// criteria for index/depth, and the standard Any/All/None compound row.
    static var templates: [NSPredicateEditorRowTemplate] {
        let strings = ["title", "path", "appName", "bundleIdentifier"].map { NSExpression(forKeyPath: $0) }
        let stringOperators: [NSComparisonPredicate.Operator] = [.equalTo, .notEqualTo, .contains, .beginsWith, .endsWith, .matches]
        let stringOps = stringOperators.map { NSNumber(value: $0.rawValue) }
        let stringTemplate = FriendlyRowTemplate(leftExpressions: strings, rightExpressionAttributeType: .stringAttributeType, modifier: .direct, operators: stringOps, options: Int(NSComparisonPredicate.Options.caseInsensitive.rawValue | NSComparisonPredicate.Options.diacriticInsensitive.rawValue))
        let ints = ["index", "depth"].map { NSExpression(forKeyPath: $0) }
        let intOperators: [NSComparisonPredicate.Operator] = [.equalTo, .notEqualTo, .lessThan, .lessThanOrEqualTo, .greaterThan, .greaterThanOrEqualTo]
        let intOps = intOperators.map { NSNumber(value: $0.rawValue) }
        let intTemplate = FriendlyRowTemplate(leftExpressions: ints, rightExpressionAttributeType: .integer64AttributeType, modifier: .direct, operators: intOps, options: 0)
        let compound = NSPredicateEditorRowTemplate(compoundTypes: [NSNumber(value: NSCompoundPredicate.LogicalType.and.rawValue), NSNumber(value: NSCompoundPredicate.LogicalType.or.rawValue), NSNumber(value: NSCompoundPredicate.LogicalType.not.rawValue)])
        return [compound, stringTemplate, intTemplate]
    }

    @objc private func ok(_ sender: Any?) {
        guard let predicate = editor.predicate else { finish(nil); return }
        // Validate regular expressions up front so evaluation can never trap.
        if let bad = RuleEditorSheet.invalidRegex(in: predicate) {
            let alert = NSAlert()
            alert.messageText = "Invalid regular expression"
            alert.informativeText = "“\(bad)” is not a valid pattern."
            alert.beginSheetModal(for: window)
            return
        }
        var updated = rule
        updated.name = nameField.stringValue.isEmpty ? "Rule" : nameField.stringValue
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: predicate, requiringSecureCoding: true) {
            updated.predicateData = data
        }
        finish(updated)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/manuader/super-bar#rules")!)
    }

    private func finish(_ result: Rule?) {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        completion(result)
    }

    static func invalidRegex(in predicate: NSPredicate) -> String? {
        if let compound = predicate as? NSCompoundPredicate {
            for sub in compound.subpredicates.compactMap({ $0 as? NSPredicate }) {
                if let bad = invalidRegex(in: sub) { return bad }
            }
        } else if let comparison = predicate as? NSComparisonPredicate, comparison.predicateOperatorType == .matches,
                  let pattern = comparison.rightExpression.constantValue as? String {
            if (try? NSRegularExpression(pattern: pattern)) == nil { return pattern }
        }
        return nil
    }
}

/// Shows human names for key paths in the left pop-up.
final class FriendlyRowTemplate: NSPredicateEditorRowTemplate {
    static let names: [String: String] = [
        "title": "Menu Item’s title",
        "path": "Menu Item’s path",
        "appName": "Application’s name",
        "bundleIdentifier": "Application’s bundle identifier",
        "index": "Menu Item’s index",
        "depth": "Menu Item’s depth",
    ]

    override var templateViews: [NSView] {
        let views = super.templateViews
        if let popup = views.first as? NSPopUpButton {
            for item in popup.itemArray {
                if let expression = item.representedObject as? NSExpression, expression.expressionType == .keyPath,
                   let name = FriendlyRowTemplate.names[expression.keyPath] {
                    item.title = name
                }
            }
        }
        return views
    }
}
