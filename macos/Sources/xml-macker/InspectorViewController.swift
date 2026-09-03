import Cocoa

// Inspector, title line + Attributes/Text panel. The trend chart
// moved OUT to its own ChartPaneViewController pane in v0.23.0, so
// the attributes table now fills the whole pane instead of fighting
// a fixed-height chart strip for space.
//
// View-based NSTableView is required for reliable inline editing, 
// the cell-based path silently renders read-only cells in recent SDKs.
final class InspectorViewController: NSViewController {

    // Callbacks the parent controller wires to route edits to the
    // source view and refresh the tree row.
    var onAttributeEdit: ((_ node: XMLTreeNode, _ attrName: String, _ newValue: String) -> Void)?
    var onTextEdit: ((_ node: XMLTreeNode, _ newText: String) -> Void)?
    // Selecting a row in the Subtags table routes to the same handler
    // as a tree click, keeps tree/source/inspector/preview in sync.
    var onSubtagSelected: ((_ child: XMLTreeNode) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "No selection")
    let attributesVC = AttributesBarViewController()

    private var currentNode: XMLTreeNode?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.mono(13, .semibold)
        titleLabel.textColor = XMColor.syntaxTag
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        v.addSubview(titleLabel)

        addChild(attributesVC)
        attributesVC.view.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(attributesVC.view)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            // Attributes panel FILLS the rest of the pane, its table
            // grows and shrinks with the pane (and scrolls), so no
            // fixed-height stack can ever overflow and shove the
            // title up under the chrome again.
            attributesVC.view.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            attributesVC.view.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            attributesVC.view.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            attributesVC.view.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            attributesVC.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 124),
        ])

        view = v
    }

    // MARK: Public API

    func setNode(_ node: XMLTreeNode) {
        currentNode = node
        applyTitle(for: node)
        attributesVC.setNode(node)
    }

    // Two-tone header: the tag stays prominent (mono, syntax color),
    // the counts become quiet secondary metadata in the UI font.
    private func applyTitle(for node: XMLTreeNode) {
        let attrCount = node.attributes.count
        let childEl = node.children.filter { $0.kind == .element }
        let s = NSMutableAttributedString(
            string: "<\(node.displayLabel)>",
            attributes: [.font: XMFont.mono(13, .semibold),
                         .foregroundColor: XMColor.syntaxTag])
        let meta = "   \(attrCount) attr\(attrCount == 1 ? "" : "s") · \(childEl.count) \(childEl.count == 1 ? "child" : "children")"
        s.append(NSAttributedString(
            string: meta,
            attributes: [.font: XMFont.ui(11, .regular),
                         .foregroundColor: XMColor.text3]))
        titleLabel.attributedStringValue = s
    }

    func refreshCurrent() {
        if let node = currentNode { setNode(node) }
    }

    var isEditingCell: Bool {
        return attributesVC.isEditingCell
    }

    func refreshValuesOnly() {
        guard let node = currentNode, !isEditingCell else { return }
        setNode(node)
    }

    // Global zoom slider hook.
    func rebuildFonts() {
        if let node = currentNode { applyTitle(for: node) }
        attributesVC.rebuildFonts()
    }

    // Theme hook.
    func rebuildColors() {
        if let node = currentNode { applyTitle(for: node) } else { titleLabel.textColor = XMColor.syntaxTag }
        attributesVC.rebuildColors()
    }
}
