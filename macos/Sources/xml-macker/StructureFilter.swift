import Cocoa

// "Structure only", v0.44.1. Both the Hierarchy flame-map and Orbit
// show only the main elements that have a tree under them, because
// every leaf at once is too much noise. In GCAM a technology period
// carries dozens of plain values (share-weight, speed, flags) next to
// a handful of real containers; showing every leaf as a chip buried
// the structure. One preference, shared by both views, so the app has
// a single idea of what "structure" means.
//
// Rule: keep the elements that CONTAIN other elements. If NOTHING in
// the list is a container, the values are the content, return them
// all rather than an empty map.
enum StructureFilter {
    static let key = "xml-macker.structureOnly"
    static let changed = Notification.Name("xml-macker.structureOnlyChanged")

    static var enabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: key) == nil ? true : d.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func isContainer(_ n: XMLTreeNode) -> Bool {
        n.children.contains { $0.kind == .element }
    }

    static func apply(_ nodes: [XMLTreeNode]) -> [XMLTreeNode] {
        guard enabled else { return nodes }
        let containers = nodes.filter(isContainer)
        return containers.isEmpty ? nodes : containers
    }
}
