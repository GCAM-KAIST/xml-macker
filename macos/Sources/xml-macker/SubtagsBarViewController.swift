import Cocoa

// Subtags table hoisted into the bottom strip of the window.
// Columns: # | → (Go) | Tag | Text | per-attribute value columns.
//
// Interaction contract (important):
//   • Clicking a ROW (any non-button cell) = PREVIEW.
//       onSubtagPreview(child) fires → source editor scrolls to that
//       child's line and highlights it, WITHOUT changing the tree's
//       selection. The inspector continues to show the parent.
//   • Clicking the row's "→" Go button = NAVIGATE.
//       onSubtagSelected(child) fires → tree re-selects to the child,
//       which cascades the full handleTreeSelection refresh.
//   • DOUBLE-clicking a cell = EDIT it in place (v0.32.1), commits
//       fire the usual onTextEdit / onAttributeEdit callbacks which
//       write straight into the source document.
final class SubtagsBarViewController: NSViewController,
                                      NSTableViewDataSource,
                                      NSTableViewDelegate {

    // Header ↑ button (the small column beside #): navigate to the
    // current element's PARENT, one click to climb the tree.
    var onGoUp: (() -> Void)?
    var onSubtagPreview:  ((_ child: XMLTreeNode) -> Void)?
    var onSubtagSelected: ((_ child: XMLTreeNode) -> Void)?
    var onAttributeEdit:  ((_ node: XMLTreeNode, _ attrName: String, _ newValue: String) -> Void)?
    var onTextEdit:       ((_ node: XMLTreeNode, _ newText: String) -> Void)?
    // Double-click the Tag cell → rename the element (open AND close
    // tag in the source). Fired only when the name actually changed.
    var onTagRename:      ((_ node: XMLTreeNode, _ newName: String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "SUBTAGS")
    private let scroll = NSScrollView()
    private let table = NSTableView()

    private var currentNode: XMLTreeNode?
    private var suppressSelection = false

    // Per-pane zoom, affects row height + cell font size.
    private(set) var zoomStep: Int = 0
    func zoomIn()    { zoomStep = min(zoomStep + 1, 16); applyZoom() }
    func zoomOut()   { zoomStep = max(zoomStep - 1, -3); applyZoom() }
    func zoomReset() { zoomStep = 0; applyZoom() }
    private var scaledCellFont: NSFont { XMFont.mono(11.5 + CGFloat(zoomStep), .regular) }
    private func applyZoom() {
        // Row height scales with the global slider + per-pane step.
        table.rowHeight = max(14, XMMetric.s(22) + CGFloat(zoomStep) * 2)
        table.reloadData()
    }

    // Global zoom slider hook. XMFont.globalScale already updated by
    // caller; we just refresh everything that cached a font.
    func rebuildFonts() {
        titleLabel.font = XMFont.uiCaption
        applyZoom()
    }

    // Theme hook, re-apply NSColor backgrounds + cgColor border on
    // the scroll view so Light themes paint bright surfaces here too.
    func rebuildColors() {
        titleLabel.textColor = XMColor.text3
        scroll.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35)
        scroll.layer?.borderColor = XMColor.hairlineS.cgColor
        table.gridColor = XMColor.hairline
        table.reloadData()
    }
    var exposedTable: NSTableView { table }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.uiCaption
        titleLabel.textColor = XMColor.text3
        v.addSubview(titleLabel)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35)
        // Visible hairline frame on all 4 sides of the table area.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = XMMetric.hairline
        scroll.layer?.borderColor = XMColor.hairlineS.cgColor
        scroll.borderType = .noBorder

        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.gridColor = XMColor.hairline
        // Real cell borders: a bordered table reads better here than
        // the borderless look.
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.selectionHighlightStyle = .regular
        // Double-click on a cell opens it for typing, see
        // rowDoubleClicked below. Drilling into a child stays on the
        // "↗" button.
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))

        setupFixedColumns()
        scroll.documentView = table
        v.addSubview(scroll)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        view = v
    }

    private func setupFixedColumns() {
        let idxCol = NSTableColumn(identifier: .subIdx)
        idxCol.title = "#"
        idxCol.width = 28
        idxCol.minWidth = 24
        idxCol.isEditable = false
        table.addTableColumn(idxCol)

        let goCol = NSTableColumn(identifier: .subGo)
        goCol.title = "↑"
        goCol.headerToolTip = "Go up to the parent element"
        goCol.width = 32
        goCol.minWidth = 28
        goCol.isEditable = false
        table.addTableColumn(goCol)

        let tagCol = NSTableColumn(identifier: .subTag)
        tagCol.title = "Tag"
        tagCol.width = 160
        tagCol.minWidth = 80
        // Editable since v0.32.2, double-click renames the element
        // (the source edit fixes BOTH the open and close tag).
        tagCol.isEditable = true
        table.addTableColumn(tagCol)

        let textCol = NSTableColumn(identifier: .subText)
        textCol.title = "Text"
        textCol.width = 200
        textCol.minWidth = 80
        textCol.isEditable = true
        table.addTableColumn(textCol)
    }

    // MARK: Public API

    // Returns the rows to display. For an element with child elements
    // we show those. For a leaf element that carries text content
    // we synthesize a single row showing the element itself so the
    // Tag/Text columns aren't blank: when the selected element IS a
    // leaf with text, its own name and value are still worth showing.
    private func displayedRows(for node: XMLTreeNode) -> [XMLTreeNode] {
        let kids = node.children.filter { $0.kind == .element }
        if kids.isEmpty && !node.textValue.isEmpty {
            return [node]
        }
        return kids
    }

    private var isSelfLeafRow: Bool {
        guard let node = currentNode else { return false }
        let kids = node.children.filter { $0.kind == .element }
        return kids.isEmpty && !node.textValue.isEmpty
    }

    func setNode(_ node: XMLTreeNode) {
        suppressSelection = true
        defer { suppressSelection = false }
        currentNode = node
        let rows = displayedRows(for: node)
        let kids = node.children.filter { $0.kind == .element }
        // The header bar already says SUBTAGS, so the inner label carries
        // the only thing it can add: how many there are.
        if kids.isEmpty && !node.textValue.isEmpty {
            titleLabel.stringValue = "leaf value, no subtags"
        } else {
            titleLabel.stringValue = "\(kids.count) subtag\(kids.count == 1 ? "" : "s")"
        }
        rebuildAttrColumns(for: node)
        if let textCol = table.tableColumns.first(where: { $0.identifier == .subText }) {
            let anyHasText = rows.contains(where: { !$0.textValue.isEmpty })
            textCol.isHidden = !anyHasText
        }
        table.reloadData()
        autoSizeColumns(for: rows)
    }

    // Compute max content width per column across all child rows and
    // the column header; clamp to [minWidth, 360pt].
    private func autoSizeColumns(for kids: [XMLTreeNode]) {
        let cellFont = XMFont.mono(11.5, .regular)
        let headerFont = XMFont.uiCaption
        let padding: CGFloat = 16

        for col in table.tableColumns where !col.isHidden {
            let headerWidth = (col.title as NSString)
                .size(withAttributes: [.font: headerFont]).width + padding
            var maxWidth: CGFloat = headerWidth
            let colId = col.identifier

            for (i, child) in kids.enumerated() {
                let text: String
                switch colId {
                case .subIdx: text = "\(i + 1)"
                case .subGo:  text = "↗"
                case .subTag: text = child.name
                case .subText: text = child.textValue
                default:
                    if colId.rawValue.hasPrefix("attr:") {
                        let n = String(colId.rawValue.dropFirst(5))
                        text = child.attributes.first(where: { $0.name == n })?.value ?? ""
                    } else { text = "" }
                }
                if text.isEmpty { continue }
                let w = (text as NSString).size(withAttributes: [.font: cellFont]).width + padding
                if w > maxWidth { maxWidth = w }
            }
            let clamped = max(col.minWidth, min(maxWidth, 360))
            col.width = clamped
        }
    }

    var isEditingCell: Bool { table.editedRow >= 0 }

    func refreshValuesOnly() {
        guard let node = currentNode, !isEditingCell else { return }
        setNode(node)
    }

    private func rebuildAttrColumns(for node: XMLTreeNode) {
        let victims = table.tableColumns.filter { $0.identifier.rawValue.hasPrefix("attr:") }
        for v in victims { table.removeTableColumn(v) }

        // Use displayedRows so a self-leaf row still surfaces its own
        // attributes as editable columns.
        var names: [String] = []
        var seen = Set<String>()
        for row in displayedRows(for: node) {
            for a in row.attributes where !seen.contains(a.name) {
                seen.insert(a.name)
                names.append(a.name)
            }
        }
        for n in names {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("attr:\(n)"))
            col.title = n
            col.width = 140
            col.minWidth = 60
            col.isEditable = true
            table.addTableColumn(col)
        }
    }

    // MARK: DataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let node = currentNode else { return 0 }
        return displayedRows(for: node).count
    }

    // MARK: Delegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let node = currentNode else { return nil }
        let rows = displayedRows(for: node)
        guard row < rows.count else { return nil }
        let child = rows[row]
        let colId = col.identifier
        let isSelfRow = isSelfLeafRow   // the synthetic self-leaf row

        // Go-button column, custom cell containing an NSButton.
        // Hide the button for the self-leaf synthetic row (there's
        // nowhere to navigate to, we're already viewing this leaf).
        if colId == .subGo {
            let reuseId = NSUserInterfaceItemIdentifier("goCell")
            let cell: GoButtonCell
            if let reused = tableView.makeView(withIdentifier: reuseId, owner: self) as? GoButtonCell {
                cell = reused
            } else {
                cell = GoButtonCell()
                cell.identifier = reuseId
                cell.button.target = self
                cell.button.action = #selector(goButtonClicked(_:))
            }
            cell.button.isHidden = isSelfRow
            return cell
        }

        // All other columns use an editable text-field cell.
        let reuseId = NSUserInterfaceItemIdentifier("txtCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: reuseId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeTextCellView(reuseId: reuseId)
        }
        guard let tf = cell.textField else { return cell }
        tf.font = scaledCellFont
        tf.isEditable = col.isEditable
        switch colId {
        case .subIdx:
            tf.stringValue = "\(row + 1)"
            tf.textColor = XMColor.text3
        case .subTag:
            tf.stringValue = child.name
            tf.textColor = XMColor.syntaxTag
        case .subText:
            tf.stringValue = child.textValue
            tf.textColor = XMColor.syntaxText
        default:
            if colId.rawValue.hasPrefix("attr:") {
                let attrName = String(colId.rawValue.dropFirst(5))
                tf.stringValue = child.attributes.first(where: { $0.name == attrName })?.value ?? ""
                tf.textColor = XMColor.syntaxVal
            } else {
                tf.stringValue = ""
                tf.textColor = XMColor.text
            }
        }
        return cell
    }

    private func makeTextCellView(reuseId: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = reuseId
        let tf = NSTextField()
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.font = scaledCellFont
        tf.usesSingleLineMode = true
        tf.maximumNumberOfLines = 1
        tf.cell?.wraps = false
        tf.cell?.truncatesLastVisibleLine = true
        tf.lineBreakMode = .byTruncatingTail
        tf.target = self
        tf.action = #selector(cellCommitted(_:))
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

    // MARK: Row selection → PREVIEW

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        guard let node = currentNode else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        let rows = displayedRows(for: node)
        guard row < rows.count else { return }
        // Self-leaf row: we're already on this node, no preview jump.
        if isSelfLeafRow { return }
        onSubtagPreview?(rows[row])
    }

    // MARK: Go button → NAVIGATE

    @objc private func goButtonClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, let node = currentNode else { return }
        let rows = displayedRows(for: node)
        guard row < rows.count else { return }
        if isSelfLeafRow { return }
        onSubtagSelected?(rows[row])
    }

    // Clicking the ↑ column HEADER climbs to the parent element.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if tableColumn.identifier == .subGo { onGoUp?() }
    }

    // Double-click = EDIT the cell in place. Navigation stays on the
    // "↗" button: double-click-to-navigate only duplicated that
    // arrow, so the double-click opens the cell for typing instead.
    // Works on the Text column and every attribute column (including
    // the synthetic self-leaf row, its commits already route to the
    // node itself). Committing the edit fires cellCommitted →
    // onTextEdit / onAttributeEdit → source document, as before.
    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        let col = table.clickedColumn
        guard row >= 0, col >= 0, let node = currentNode else { return }
        let rows = displayedRows(for: node)
        guard row < rows.count else { return }
        guard table.tableColumns[col].isEditable else { return }
        // editColumn requires the row to be selected and the table to
        // have focus; the first click of the double-click usually did
        // both, but enforce it so the call can't throw.
        if table.selectedRow != row {
            suppressSelection = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelection = false
        }
        view.window?.makeFirstResponder(table)
        table.editColumn(col, row: row, with: nil, select: true)
    }

    // MARK: Cell edit commits

    @objc private func cellCommitted(_ sender: NSTextField) {
        let row = table.row(for: sender)
        let col = table.column(for: sender)
        guard row >= 0, col >= 0, let node = currentNode else { return }
        let colId = table.tableColumns[col].identifier
        let rows = displayedRows(for: node)
        guard row < rows.count else { return }
        let target = rows[row]   // self-leaf: == node; otherwise a child
        let newValue = sender.stringValue
        if colId == .subText {
            onTextEdit?(target, newValue)
        } else if colId == .subTag {
            // No-op commits (focus loss without typing) must not
            // trigger a rename + tree rebuild.
            if newValue != target.name { onTagRename?(target, newValue) }
        } else if colId.rawValue.hasPrefix("attr:") {
            let attrName = String(colId.rawValue.dropFirst(5))
            onAttributeEdit?(target, attrName, newValue)
        }
    }
}

// Custom cell hosting a chevron NSButton for the Go column.
private final class GoButtonCell: NSTableCellView {
    let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.title = "↗"
        button.font = XMFont.ui(13, .semibold)
        button.contentTintColor = XMColor.accent
        button.focusRingType = .none
        button.toolTip = "Navigate to this element"
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private extension NSUserInterfaceItemIdentifier {
    static let subIdx  = NSUserInterfaceItemIdentifier("#")
    static let subGo   = NSUserInterfaceItemIdentifier("go")
    static let subTag  = NSUserInterfaceItemIdentifier("tag")
    static let subText = NSUserInterfaceItemIdentifier("text")
}
