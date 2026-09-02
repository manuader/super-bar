import Foundation
import SBObjC

/// A user-defined exclusion rule. The predicate is stored as a secure-coded
/// archive so that it always round-trips through `NSPredicateEditor`.
public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var predicateData: Data

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, predicateData: Data) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.predicateData = predicateData
    }

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, predicate: NSPredicate) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: predicate, requiringSecureCoding: true)
        self.init(id: id, name: name, isEnabled: isEnabled, predicateData: data)
    }

    public var predicate: NSPredicate? {
        guard let p = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPredicate.self, from: predicateData) else { return nil }
        p.allowEvaluation()   // secure-coded predicates refuse to evaluate until allowed
        return p
    }

    public var predicateFormat: String { predicate?.predicateFormat ?? "" }
}

/// KVC-compliant subject evaluated by rule predicates.
@objc public final class RuleSubject: NSObject {
    @objc public let title: String
    @objc public let path: String
    @objc public let appName: String
    @objc public let bundleIdentifier: String
    @objc public let index: Int
    @objc public let depth: Int

    public init(title: String, path: String, appName: String, bundleIdentifier: String, index: Int, depth: Int) {
        self.title = title
        self.path = path
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.index = index
        self.depth = depth
    }

    public convenience init(node: MenuNode, app: AppInfo) {
        self.init(title: node.title, path: node.rulePath, appName: app.name, bundleIdentifier: app.bundleIdentifier ?? "", index: node.index, depth: node.depth)
    }

    public static let keys = ["title", "path", "appName", "bundleIdentifier", "index", "depth"]
}

public enum RuleEngine {
    public struct Outcome: Sendable {
        public var roots: [MenuNode]
        public var removedCount: Int
        /// Set when applying the rules removed every node.
        public var removedEverything: Bool
        /// Rules that threw while evaluating (invalid regex, etc.).
        public var failedRuleIDs: [UUID]
    }

    /// Removes every node (and its descendants) that any enabled rule matches.
    public static func apply(_ rules: [Rule], to roots: [MenuNode], app: AppInfo) -> Outcome {
        let active = rules.filter(\.isEnabled).compactMap { rule -> (UUID, NSPredicate)? in
            guard let p = rule.predicate else { return nil }
            return (rule.id, p)
        }
        guard !active.isEmpty else {
            return Outcome(roots: roots, removedCount: 0, removedEverything: roots.isEmpty, failedRuleIDs: [])
        }
        var removed = 0
        var failed = Set<UUID>()

        func matches(_ node: MenuNode) -> Bool {
            let subject = RuleSubject(node: node, app: app)
            for (id, predicate) in active where !failed.contains(id) {
                var result = false
                var error: NSError?
                let ok = SBTryCatch({ result = predicate.evaluate(with: subject) }, &error)
                if !ok { failed.insert(id); continue }
                if result { return true }
            }
            return false
        }

        func filter(_ node: MenuNode) -> MenuNode? {
            if node.isSeparator { return node }
            if matches(node) {
                removed += node.flattened.count
                return nil
            }
            var copy = node
            copy.children = node.children.compactMap(filter)
            return copy
        }

        let out = roots.compactMap(filter)
        let hadContent = !roots.flattened.isEmpty
        return Outcome(roots: out, removedCount: removed, removedEverything: hadContent && out.flattened.filter { !$0.isSeparator && $0.kind != .menuBarItem }.isEmpty, failedRuleIDs: Array(failed))
    }

    /// Builds a predicate from a format string, converting parse failures into
    /// a thrown error instead of an Objective-C exception.
    public static func predicate(fromFormat format: String) throws -> NSPredicate {
        var predicate: NSPredicate?
        var error: NSError?
        let ok = SBTryCatch({ predicate = NSPredicate(format: format) }, &error)
        guard ok, let p = predicate else {
            throw error ?? NSError(domain: "SuperBar.Rules", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid predicate"])
        }
        return p
    }

    /// Evaluates a predicate against a subject, surfacing exceptions as errors.
    public static func evaluate(_ predicate: NSPredicate, with subject: RuleSubject) throws -> Bool {
        var result = false
        var error: NSError?
        let ok = SBTryCatch({ result = predicate.evaluate(with: subject) }, &error)
        if !ok { throw error ?? NSError(domain: "SuperBar.Rules", code: 2) }
        return result
    }
}
