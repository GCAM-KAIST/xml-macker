import Foundation

// In-memory tree representation. Nodes are classes (not structs) so
// NSOutlineView can identity-compare via object pointers, and so we can
// build parent back-references cheaply during streaming parse.
final class XMLTreeNode {
    enum Kind {
        case document
        case element
        case text
        case comment
    }

    let id: Int
    var kind: Kind
    var name: String
    var textValue: String = ""
    var attributes: [(name: String, value: String)] = []
    weak var parent: XMLTreeNode?
    var children: [XMLTreeNode] = []

    // Byte ranges in the original file so we can slice or patch later.
    var startOffset: Int = 0
    var endOffset: Int = 0
    var startLine: Int = 1
    var endLine: Int = 1

    // True if this node represents a "...(N more elements not shown)" marker
    // produced when a branch was too large to load eagerly.
    var isTruncationPlaceholder: Bool = false

    init(id: Int, kind: Kind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }

    var displayLabel: String {
        switch kind {
        // The root row shows the FILE name (loadFile renames the
        // document node), "#document" meant nothing to users.
        case .document: return name
        case .element: return name
        case .text: return "#text"
        case .comment: return "#comment"
        }
    }

    var displayDetail: String {
        if kind != .element { return "" }
        if attributes.isEmpty { return "" }
        let previews = attributes.prefix(3).map { "\($0.name)=\"\($0.value)\"" }
        var s = previews.joined(separator: " ")
        if attributes.count > 3 { s += " …" }
        return s
    }

    var isLeafForOutline: Bool {
        return children.isEmpty
    }
}
