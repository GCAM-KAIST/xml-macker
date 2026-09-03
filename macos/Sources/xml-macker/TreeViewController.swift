import Cocoa

// NSOutlineView handles tree-of-Object models natively and virtualizes
// rows, a 200k-node tree renders in constant memory.
final class TreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var root: XMLTreeNode?

    var onSelectNode: ((XMLTreeNode) -> Void)?

    // Right-click context menu (v0.28.0). MainWindowController owns
    // the actual edits, the tree only reports what was asked.
    enum ContextAction: Equatable {
        case copyXML, copyPath, cut, duplicateAbove, duplicateBelow, delete, findReplace
        case deleteOthers               // keep this element, remove its element siblings
        case shareToLLM(LLMTarget)      // Share ▸ Send to …
        case printElement
        case exportElement
        case defineInLearn
        case openLinkedFile(URL)      // config entry naming a real file
    }
    var onContextAction: ((XMLTreeNode, ContextAction) -> Void)?
    // Set by MainWindowController: a node whose text or attribute names
    // a file that exists next to the document.
    var resolveLinkedFile: ((XMLTreeNode) -> URL?)?
    private weak var contextNode: XMLTreeNode?

    // Per-pane zoom step; +1 step ≈ +1 pt on both the name label
    // and the detail preview. Row height grows proportionally so
    // the two text lines still fit at larger sizes.
    private(set) var zoomStep: Int = 0
    func zoomIn()    { zoomStep = min(zoomStep + 1, 16); applyZoom() }
    func zoomOut()   { zoomStep = max(zoomStep - 1, -4); applyZoom() }
    func zoomReset() { zoomStep = 0; applyZoom() }
    var scaledNameFont: NSFont  { XMFont.ui(12 + CGFloat(zoomStep), .semibold) }
    var scaledDetailFont: NSFont { XMFont.ui(10.5 + CGFloat(zoomStep), .regular) }
    private func applyZoom() {
        // Row height now folds in the global slider too, at 50% zoom
        // the tree compresses vertically so more nodes are visible.
        let base = XMMetric.s(XMMetric.treeRowH) + CGFloat(zoomStep) * 2
        outline.rowHeight = max(14, base)
        outline.reloadData()
    }
    // Global zoom slider hook, XMFont.globalScale updated by caller.
    // Tree cells pull fonts from scaledNameFont / scaledDetailFont at
    // build time, and reloadData rebuilds them.
    func rebuildFonts() { applyZoom() }

    // Theme hook. Tree cells use XMColor inside their text/dot build
    // methods, so reloadData re-colors every row against the fresh
    // palette.
    func rebuildColors() {
        outline.gridColor = XMColor.hairline
        outline.reloadData()
    }

    // Expose outline so MainWindowController can route focus-based zoom.
    var exposedOutline: NSOutlineView { outline }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        outline.headerView = nil
        outline.rowHeight = XMMetric.treeRowH
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.usesAlternatingRowBackgroundColors = false
        // .regular keeps AppKit's selection machinery firing
        // drawSelection(in:) on our custom TreeRowView, with .none
        // AppKit suppresses that call entirely and the row never
        // shows any highlight.
        outline.selectionHighlightStyle = .regular
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        // An element can be dragged out of the tree: into the source, into
        // the Learn chat, or into any other application.
        outline.setDraggingSourceOperationMask([.copy], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        let ctx = NSMenu()
        ctx.delegate = self
        outline.menu = ctx
        // Double-click a row = toggle its disclosure (same as the
        // little arrow), so an element opens up without having to hit
        // the small triangle.
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.focusRingType = .none
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = XMMetric.treeIndent
        outline.backgroundColor = .clear

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = ""
        col.minWidth = 120
        col.width = 400
        col.resizingMask = [.autoresizingMask, .userResizingMask]
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        scroll.documentView = outline
        v.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])

        self.view = v
    }

    // Aurora uses a custom selection style, draw a subtle accent
    // glass fill behind the selected row, no system blue highlight.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return TreeRowView()
    }

    func setRoot(_ root: XMLTreeNode) {
        self.root = root
        outline.reloadData()
        if let first = root.children.first(where: { $0.kind == .element }) {
            outline.expandItem(root)
            outline.expandItem(first)
        }
    }

    func refreshNode(_ node: XMLTreeNode) {
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.reloadData(forRowIndexes: IndexSet(integer: row),
                               columnIndexes: IndexSet(integer: 0))
        }
    }

    // Selection changes from select() already fire the outline's
    // selectionDidChange → onSelectNode path, so we don't call
    // onSelectNode manually here (would double-fire the handler).
    func drillUp() {
        let row = outline.selectedRow
        guard row >= 0,
              let node = outline.item(atRow: row) as? XMLTreeNode,
              let parent = node.parent else { return }
        select(node: parent, expandAncestors: true)
    }

    func drillDown() {
        let row = outline.selectedRow
        guard row >= 0,
              let node = outline.item(atRow: row) as? XMLTreeNode,
              let first = node.children.first else { return }
        outline.expandItem(node)
        select(node: first, expandAncestors: false)
    }

    func select(node: XMLTreeNode, expandAncestors: Bool = false) {
        if expandAncestors {
            var ancestors: [XMLTreeNode] = []
            var cur = node.parent
            while let p = cur {
                ancestors.append(p)
                cur = p.parent
            }
            for a in ancestors.reversed() {
                outline.expandItem(a)
            }
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: data source

    /// Asked for the XML of an element that is being dragged, and the
    /// name a file made from it should have. MainWindowController fills
    /// this in; it owns the document text.
    var dragPayload: ((XMLTreeNode) -> (name: String, xml: String)?)?

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? XMLTreeNode,
              let payload = dragPayload?(node) else { return nil }
        Diag.log("tree drag: <\(node.name)> \(payload.xml.utf8.count) bytes as \(payload.name)")
        return ElementDragItem(name: payload.name, xml: payload.xml)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return root == nil ? 0 : 1
        }
        if let node = item as? XMLTreeNode {
            return node.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return root as Any
        }
        let node = item as! XMLTreeNode
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? XMLTreeNode { return !node.children.isEmpty }
        return false
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? XMLTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("auroraCell")
        let cell: AuroraTreeCell
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? AuroraTreeCell {
            cell = reused
        } else {
            cell = AuroraTreeCell()
            cell.identifier = id
        }
        cell.applyFonts(name: scaledNameFont, detail: scaledDetailFont)
        cell.configure(for: node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? XMLTreeNode else { return }
        onSelectNode?(node)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? XMLTreeNode else { return }
        guard outline.isExpandable(node) else { return }
        if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }

    // MARK: Right-click context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0,
              let node = outline.item(atRow: row) as? XMLTreeNode,
              node.kind == .element else { contextNode = nil; return }
        contextNode = node
        // Right-click MOVES the selection too, otherwise the highlight
        // stays behind on the previously left-clicked row. Selecting the
        // row fires the full sync pipeline, so the source highlight,
        // inspector, chart etc. all follow.
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        func add(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        // Config-style entries that name another file open it directly.
        if let url = resolveLinkedFile?(node) {
            let it = NSMenuItem(title: "Open Linked File: \(url.lastPathComponent)",
                                action: #selector(ctxOpenLinked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = url
            menu.addItem(it)
            menu.addItem(.separator())
        }
        // Define in Learn sits at the top level, not only inside Share.
        add("✨ Define in Learn", #selector(ctxDefineLearn(_:)))
        menu.addItem(.separator())
        add("Copy Element XML", #selector(ctxCopyXML(_:)))
        add("Copy Path",       #selector(ctxCopyPath(_:)))
        menu.addItem(.separator())
        add("Duplicate Above", #selector(ctxDupAbove(_:)))
        add("Duplicate Below", #selector(ctxDupBelow(_:)))
        menu.addItem(.separator())
        add("Cut Element",     #selector(ctxCut(_:)))
        add("Delete Element",  #selector(ctxDelete(_:)))
        add("Delete Others (keep only this)", #selector(ctxDeleteOthers(_:)))
        menu.addItem(.separator())
        // Share ▸, same side-menu as the Share menu bar entry.
        let shareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        let shareSub = NSMenu(title: "Share")
        for target in LLMTarget.allCases {
            let it = NSMenuItem(title: "Send to \(target.displayName)",
                                action: #selector(ctxShareLLM(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = target.rawValue
            shareSub.addItem(it)
        }
        shareSub.addItem(.separator())
        let learnIt = NSMenuItem(title: "✨ Define in Learn", action: #selector(ctxDefineLearn(_:)), keyEquivalent: "")
        learnIt.target = self
        shareSub.addItem(learnIt)
        let printIt = NSMenuItem(title: "Print Element…", action: #selector(ctxPrintElement(_:)), keyEquivalent: "")
        printIt.target = self
        shareSub.addItem(printIt)
        let exportIt = NSMenuItem(title: "Export as XML…", action: #selector(ctxExportElement(_:)), keyEquivalent: "")
        exportIt.target = self
        shareSub.addItem(exportIt)
        shareItem.submenu = shareSub
        menu.addItem(shareItem)
        menu.addItem(.separator())
        add("Find & Replace in <\(node.displayLabel)>…", #selector(ctxFindReplace(_:)))
    }

    @objc private func ctxCopyXML(_ s: Any?)      { fireContext(.copyXML) }
    @objc private func ctxCopyPath(_ s: Any?)     { fireContext(.copyPath) }
    @objc private func ctxDupAbove(_ s: Any?)     { fireContext(.duplicateAbove) }
    @objc private func ctxDupBelow(_ s: Any?)     { fireContext(.duplicateBelow) }
    @objc private func ctxCut(_ s: Any?)          { fireContext(.cut) }
    @objc private func ctxDelete(_ s: Any?)       { fireContext(.delete) }
    @objc private func ctxFindReplace(_ s: Any?)  { fireContext(.findReplace) }
    @objc private func ctxDeleteOthers(_ s: Any?) { fireContext(.deleteOthers) }
    @objc private func ctxDefineLearn(_ s: Any?)  { fireContext(.defineInLearn) }
    @objc private func ctxPrintElement(_ s: Any?) { fireContext(.printElement) }
    @objc private func ctxExportElement(_ s: Any?) { fireContext(.exportElement) }
    @objc private func ctxShareLLM(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String,
              let target = LLMTarget(rawValue: raw) else { return }
        fireContext(.shareToLLM(target))
    }
    @objc private func ctxOpenLinked(_ s: NSMenuItem) {
        guard let url = s.representedObject as? URL else { return }
        fireContext(.openLinkedFile(url))
    }
    private func fireContext(_ a: ContextAction) {
        guard let n = contextNode else { return }
        onContextAction?(n, a)
    }
}

// MARK: - Aurora row view (custom selection glass fill)

private final class TreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 3, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        XMColor.accent.withAlphaComponent(0.18).setFill()
        path.fill()
        XMColor.accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
    override var isEmphasized: Bool { get { true } set { _ = newValue } }
}

// MARK: - Aurora tree cell
//
// Visual: [10px diamond icon · colored by kind]  name in SF Pro semibold  attr-preview in smaller text3

private final class AuroraTreeCell: NSTableCellView {
    private let iconView = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = XMFont.ui(12, .semibold)
        nameLabel.textColor = XMColor.text
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.usesSingleLineMode = true
        nameLabel.cell?.wraps = false
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = XMFont.ui(10.5, .regular)
        detailLabel.textColor = XMColor.text3
        detailLabel.isBordered = false
        detailLabel.drawsBackground = false
        detailLabel.isEditable = false
        detailLabel.usesSingleLineMode = true
        detailLabel.cell?.wraps = false
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail

        textField = nameLabel
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    func applyFonts(name: NSFont, detail: NSFont) {
        nameLabel.font = name
        detailLabel.font = detail
    }

    func configure(for node: XMLTreeNode) {
        nameLabel.stringValue = node.displayLabel
        detailLabel.stringValue = node.displayDetail

        // Icon: diamond for elements (violet), dot for text, square for comment/doc.
        iconView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let shape = CAShapeLayer()
        shape.frame = iconView.bounds
        switch node.kind {
        case .element:
            let r = NSRect(x: 0, y: 0, width: 10, height: 10)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.minY + 1))
            p.line(to: NSPoint(x: r.maxX - 1, y: r.midY))
            p.line(to: NSPoint(x: r.midX, y: r.maxY - 1))
            p.line(to: NSPoint(x: r.minX + 1, y: r.midY))
            p.close()
            shape.path = p.cgPath
            shape.fillColor = XMColor.syntaxTag.cgColor
        case .text:
            let p = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 6, height: 6))
            shape.path = p.cgPath
            shape.fillColor = XMColor.syntaxText.cgColor
        case .comment:
            let p = NSBezierPath(rect: NSRect(x: 2, y: 2, width: 6, height: 6))
            shape.path = p.cgPath
            shape.fillColor = XMColor.syntaxCom.cgColor
        case .document:
            let p = NSBezierPath(rect: NSRect(x: 1, y: 1, width: 8, height: 8))
            shape.path = p.cgPath
            shape.fillColor = XMColor.text2.cgColor
        }
        iconView.layer = CALayer()
        iconView.wantsLayer = true
        iconView.layer?.addSublayer(shape)
    }
}

// NSBezierPath → CGPath convenience for the diamond icon.
private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:        path.move(to: points[0])
            case .lineTo:        path.addLine(to: points[0])
            case .curveTo:       path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:  path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:     path.closeSubpath()
            @unknown default:    break
            }
        }
        return path
    }
}
