import Cocoa

// Attributes + Text Content panel, stacks vertically so it fits
// inside the Inspector right column. Previously used as a horizontal
// strip at the bottom of the window; layout flipped to vertical when
// Subtags moved to the bottom strip and Attributes returned to the
// inspector column.
final class AttributesBarViewController: NSViewController,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate {

    var onAttributeEdit: ((_ node: XMLTreeNode, _ attrName: String, _ newValue: String) -> Void)?
    var onTextEdit: ((_ node: XMLTreeNode, _ newText: String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "ATTRIBUTES")
    private let attrScroll = NSScrollView()
    private let attrTable = NSTableView()
    private let textHeader = NSTextField(labelWithString: "TEXT CONTENT")
    private let textField = NSTextField()

    private var currentNode: XMLTreeNode?

    // Per-pane zoom.
    private(set) var zoomStep: Int = 0
    func zoomIn()    { zoomStep = min(zoomStep + 1, 16); applyZoom() }
    func zoomOut()   { zoomStep = max(zoomStep - 1, -3); applyZoom() }
    func zoomReset() { zoomStep = 0; applyZoom() }
    private var scaledCellFont: NSFont { XMFont.mono(11.5 + CGFloat(zoomStep), .regular) }
    private var scaledTextFont: NSFont { XMFont.mono(12 + CGFloat(zoomStep), .regular) }
    private func applyZoom() {
        // Row height scales with BOTH the global slider and the
        // per-pane zoom step, small screens can tighten the
        // attributes table so more rows fit.
        attrTable.rowHeight = max(14, XMMetric.s(20) + CGFloat(zoomStep) * 2)
        textField.font = scaledTextFont
        attrTable.reloadData()
    }

    // Re-applies every font this VC owns. Called from
    // MainWindowController when the global zoom slider changes, 
    // XMFont.globalScale has been updated already, so re-invoking
    // every XMFont.xxx helper yields freshly-scaled fonts.
    func rebuildFonts() {
        titleLabel.font = XMFont.uiCaption
        textHeader.font = XMFont.uiCaption
        applyZoom()
    }

    // Theme hook.
    func rebuildColors() {
        titleLabel.textColor = XMColor.text3
        textHeader.textColor = XMColor.text3
        attrTable.gridColor = XMColor.hairline
        attrTable.reloadData()
    }
    var exposedAttrTable: NSTableView { attrTable }
    var exposedTextField: NSTextField { textField }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.uiCaption
        titleLabel.textColor = XMColor.text3
        v.addSubview(titleLabel)

        attrScroll.translatesAutoresizingMaskIntoConstraints = false
        attrScroll.hasVerticalScroller = true
        attrScroll.drawsBackground = false
        attrScroll.borderType = .noBorder

        attrTable.headerView = NSTableHeaderView()
        attrTable.rowHeight = 20
        attrTable.usesAlternatingRowBackgroundColors = false
        attrTable.style = .inset
        attrTable.dataSource = self
        attrTable.delegate = self
        attrTable.allowsColumnResizing = true
        attrTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        attrTable.backgroundColor = .clear
        attrTable.gridColor = XMColor.hairline

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("aName"))
        nameCol.title = "Name"
        nameCol.width = 120
        nameCol.minWidth = 70
        nameCol.isEditable = false
        attrTable.addTableColumn(nameCol)

        let valCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("aValue"))
        valCol.title = "Value"
        valCol.width = 220
        valCol.minWidth = 80
        valCol.resizingMask = [.autoresizingMask, .userResizingMask]
        valCol.isEditable = true
        attrTable.addTableColumn(valCol)

        attrScroll.documentView = attrTable
        v.addSubview(attrScroll)

        textHeader.translatesAutoresizingMaskIntoConstraints = false
        textHeader.font = XMFont.uiCaption
        textHeader.textColor = XMColor.text3
        v.addSubview(textHeader)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBezeled = true
        textField.bezelStyle = .squareBezel
        textField.isEditable = true
        textField.font = XMFont.mono(12, .regular)
        textField.textColor = XMColor.syntaxText
        textField.placeholderString = "(no text content)"
        textField.target = self
        textField.action = #selector(textContentCommitted(_:))
        (textField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        v.addSubview(textField)

        // The table's height is SOFT so this panel can compress when
        // the inspector (or its popped-out window) is short, the
        // table scrolls, nothing overlaps. Hard floor keeps a couple
        // of rows visible. Mirrors InspectorViewController's scheme.
        let tableH = attrScroll.heightAnchor.constraint(equalToConstant: 120)
        tableH.priority = NSLayoutConstraint.Priority(510)
        let tfH = textField.heightAnchor.constraint(equalToConstant: 22)
        self.textFieldHeightCon = tfH

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            attrScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            attrScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            attrScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            tableH,
            attrScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            textHeader.topAnchor.constraint(equalTo: attrScroll.bottomAnchor, constant: 8),
            textHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            textField.topAnchor.constraint(equalTo: textHeader.bottomAnchor, constant: 4),
            textField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            tfH,
            // Pinned bottom: the table above stretches to fill the
            // pane (its 120-pt height is a soft preference), so the
            // attributes list gets ALL the room the pane has.
            textField.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        view = v
    }

    // Collapses the text editor to zero when it can't be used anyway
    // (element has child elements), the note moves into the header
    // line instead of a full-height disabled box eating space.
    private var textFieldHeightCon: NSLayoutConstraint?

    func setNode(_ node: XMLTreeNode) {
        currentNode = node
        let hasElementChildren = node.children.contains(where: { $0.kind == .element })
        titleLabel.stringValue = "ATTRIBUTES  (\(node.attributes.count))"
        attrTable.reloadData()
        textField.isEnabled = !hasElementChildren
        textField.stringValue = hasElementChildren ? "" : node.textValue
        // Elements with children can't have their text edited here, 
        // instead of a full-height disabled box, collapse the editor
        // and say why in the header line. Less crowding, same info.
        if hasElementChildren {
            // Nothing to say: the element's text lives in its children,
            // which the tree below already shows. The caption was one more
            // line of chrome explaining an empty box.
            textHeader.stringValue = ""
            textHeader.isHidden = true
            textField.isHidden = true
            textFieldHeightCon?.constant = 0
        } else {
            textHeader.isHidden = false
            textHeader.stringValue = "TEXT CONTENT"
            textField.isHidden = false
            textFieldHeightCon?.constant = 22
            textField.placeholderString = "(no text content)"
        }
    }

    var isEditingCell: Bool {
        if attrTable.editedRow >= 0 { return true }
        if let win = view.window, let first = win.firstResponder as? NSText,
           first.delegate === textField || first === textField.currentEditor() {
            return true
        }
        return false
    }

    func refreshValuesOnly() {
        guard let node = currentNode, !isEditingCell else { return }
        setNode(node)
    }

    // MARK: DataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return currentNode?.attributes.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let node = currentNode else { return nil }
        guard row < node.attributes.count else { return nil }
        let attr = node.attributes[row]
        let reuseId = NSUserInterfaceItemIdentifier("attrCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: reuseId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCellView(reuseId: reuseId)
        }
        guard let tf = cell.textField else { return cell }
        tf.font = scaledCellFont
        tf.isEditable = col.isEditable
        if col.identifier.rawValue == "aName" {
            tf.stringValue = attr.name
            tf.textColor = XMColor.syntaxAttr
        } else {
            tf.stringValue = attr.value
            tf.textColor = XMColor.syntaxVal
        }
        return cell
    }

    private func makeCellView(reuseId: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = reuseId
        let tf = NSTextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.font = XMFont.mono(11.5, .regular)
        tf.usesSingleLineMode = true
        tf.maximumNumberOfLines = 1
        tf.cell?.wraps = false
        tf.cell?.truncatesLastVisibleLine = true
        tf.lineBreakMode = .byTruncatingTail
        tf.target = self
        tf.action = #selector(attrCellCommitted(_:))
        (tf.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        tf.focusRingType = .none
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.topAnchor.constraint(equalTo: cell.topAnchor),
            tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    @objc private func attrCellCommitted(_ sender: NSTextField) {
        let row = attrTable.row(for: sender)
        let col = attrTable.column(for: sender)
        guard row >= 0, col >= 0, let node = currentNode else { return }
        let colId = attrTable.tableColumns[col].identifier.rawValue
        guard colId == "aValue", row < node.attributes.count else { return }
        let attrName = node.attributes[row].name
        onAttributeEdit?(node, attrName, sender.stringValue)
    }

    @objc private func textContentCommitted(_ sender: NSTextField) {
        guard let node = currentNode else { return }
        onTextEdit?(node, sender.stringValue)
    }
}
