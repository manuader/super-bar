import AppKit
import Foundation
import SuperBarKit

// superbar-cli — list or click menu items of the frontmost application.
//
//   superbar-cli list [--predicate <NSPredicate format>]
//   superbar-cli select <index> <index> ...
//
// `list` prints {"items":[{title, path, indices, shortcut?, mark?, bundle_id?}]}
// for every enabled leaf item (menu bar items and submenus are omitted).
// `select 0 1` clicks the second item of the first (Apple) menu.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage(_ code: Int32) -> Never {
    let text = """
    OVERVIEW: A command-line interface to SuperBar.

    USAGE: superbar-cli <subcommand>

    SUBCOMMANDS:
      list [-p, --predicate <format>]   List all menu items of the frontmost application as JSON.
                                        The predicate supports title, path, appName, bundleIdentifier, index, depth.
      select <index> ...                Click the menu item at the given positional path.
      -h, --help                        Show help information.
    """
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    exit(code)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func frontmostApp() -> AppInfo {
    let me = ProcessInfo.processInfo.processIdentifier
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me else {
        fail("No frontmost application.")
    }
    return AppInfo(running: app)
}

extension AppInfo {
    init(running app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? "App")
    }
}

guard let command = arguments.first else { usage(2) }
if command == "-h" || command == "--help" || command == "help" { usage(0) }

let source = AXMenuSource()
guard source.isTrusted else {
    fail("Accessibility access is required. Enable your terminal under System Settings › Privacy & Security › Accessibility.", code: 3)
}

switch command {
case "list":
    var predicate: NSPredicate?
    var rest = arguments.dropFirst()
    while let flag = rest.first {
        rest = rest.dropFirst()
        switch flag {
        case "-p", "--predicate":
            guard let format = rest.first else { fail("--predicate needs a value.") }
            rest = rest.dropFirst()
            do { predicate = try RuleEngine.predicate(fromFormat: format) } catch { fail("Invalid predicate: \(error.localizedDescription)") }
        case "-h", "--help": usage(0)
        default: fail("Unknown option \(flag)")
        }
    }
    let app = frontmostApp()
    let roots: [MenuNode]
    do { roots = try source.loadMenuBar(for: app) { _ in } } catch let error as MenuSourceError { fail(error.message) } catch { fail(error.localizedDescription) }
    var items: [[String: Any]] = []
    for node in roots.flattened where node.kind == .item && node.isEnabled {
        if let predicate {
            let subject = RuleSubject(node: node, app: app)
            guard (try? RuleEngine.evaluate(predicate, with: subject)) == true else { continue }
        }
        var item: [String: Any] = ["title": node.title, "path": node.path, "indices": node.indexPath]
        if let key = node.keyEquivalent { item["shortcut"] = key.display }
        if let mark = node.mark { item["mark"] = mark }
        if let bundle = app.bundleIdentifier { item["bundle_id"] = bundle }
        items.append(item)
    }
    let data = try JSONSerialization.data(withJSONObject: ["items": items], options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)

case "select":
    let indices = arguments.dropFirst().compactMap { Int($0) }
    guard !indices.isEmpty, indices.count == arguments.count - 1 else { fail("select needs one or more integer indices.") }
    let app = frontmostApp()
    let roots: [MenuNode]
    do { roots = try source.loadMenuBar(for: app) { _ in } } catch let error as MenuSourceError { fail(error.message) } catch { fail(error.localizedDescription) }
    guard let node = roots.node(at: indices) else { fail("No menu item at \(indices).") }
    do { try source.press(node, in: app) } catch let error as MenuSourceError { fail(error.message) } catch { fail(error.localizedDescription) }

default:
    usage(2)
}
