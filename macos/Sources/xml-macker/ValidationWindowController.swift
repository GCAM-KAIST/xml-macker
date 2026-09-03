import Cocoa

// Window that lists XML parse errors + warnings from the most recent
// load/re-parse. Each row is click-to-jump, selecting an error
// scrolls the source editor to the reported line and highlights it,
// same path as clicking a tree node.
//
// The case this exists for: deleting an opening tag leaves the file
// broken, so the window has to name the place that broke, and the row
// has to lead straight to it.
final class ValidationWindowController: NSWindowController, NSWindowDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate {

    // Fires when the user clicks a row. MainWindowController wires
    // this to scroll the source editor + select the containing node.
    var onErrorClicked: ((_ line: Int, _ column: Int) -> Void)?
    var onFixClicked: ((_ error: XMLStreamParser.ParseError) -> Void)?
    var onRevalidateRequested: (() -> Void)?
    var onClose: (() -> Void)?

    private let table = KeyActivatableTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var errors: [XMLStreamParser.ParseError] = []

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Validation"
        // Follow the active theme rather than pinning dark.
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        win.animationBehavior = .none
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        super.init(window: win)
        win.delegate = self
        buildLayout()
        installLocalZoom()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setErrors(_ errors: [XMLStreamParser.ParseError]) {
        self.errors = errors
        table.reloadData()
        if errors.isEmpty {
            statusLabel.stringValue = "No errors, XML is well-formed."
            statusLabel.textColor = XMColor.ok
        } else {
            statusLabel.stringValue = "\(errors.count) error\(errors.count == 1 ? "" : "s")"
            statusLabel.textColor = XMColor.err
        }
        hintLabel.stringValue = """
        Live check is scoped to the selected element's parent: mismatched \
        or missing closing tags, stray closes, unquoted or duplicate \
        attributes, unescaped '&', malformed tags. Click or press Return \
        on a row to jump to its line; rows with a Fix button can be \
        repaired in one click (⌘Z undoes). Tag-name typos that are still valid \
        XML (<peiod> vs <period>) need schema (XSD/DTD) validation, \
        point the app at a GCAM schema to enable that someday.
        """
    }

    // Small explainer beneath the status line so the user knows what
    // "validation" means here. Changing "period" to "peiod" still
    // parses as well-formed XML and raises nothing, catching that is a
    // schema check, not a syntax check.
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    // This window's own zoom: Command with the wheel, or with +, - and
    // 0. The toolbar slider stays the zoom of the whole app.
    private var localScale: CGFloat = 1
    private let wheelZoom = WheelZoom()

    private func installLocalZoom() {
        wheelZoom.install(in: window) { [weak self] zoomIn, _ in
            guard let self else { return }
            self.setLocalScale(self.localScale * (zoomIn ? 1.06 : 1 / 1.06))
        }
    }

    private func setLocalScale(_ s: CGFloat) {
        localScale = max(0.6, min(2.5, s))
        statusLabel.font = XMFont.ui(12 * localScale, .semibold)
        hintLabel.font = XMFont.ui(11 * localScale, .regular)
        table.rowHeight = (22 * localScale).rounded()
        table.reloadData()
    }

    @objc func xmZoomIn(_ sender: Any?)    { setLocalScale(localScale * 1.1) }
    @objc func xmZoomOut(_ sender: Any?)   { setLocalScale(localScale / 1.1) }
    @objc func xmZoomReset(_ sender: Any?) { setLocalScale(1) }

    private func buildLayout() {
        guard let win = window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = XMColor.bg.cgColor

        // Status row + "Re-validate" action.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = XMFont.ui(12 * localScale, .semibold)
        statusLabel.textColor = XMColor.text2
        root.addSubview(statusLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = XMFont.ui(11 * localScale, .regular)
        hintLabel.textColor = XMColor.text3
        hintLabel.maximumNumberOfLines = 0
        root.addSubview(hintLabel)

        let reBtn = NSButton(title: "Re-validate", target: self, action: #selector(revalidate(_:)))
        reBtn.translatesAutoresizingMaskIntoConstraints = false
        reBtn.bezelStyle = .rounded
        root.addSubview(reBtn)

        // Errors table.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = XMColor.bgDeep
        scroll.borderType = .noBorder

        table.style = .inset
        table.headerView = NSTableHeaderView()
        table.backgroundColor = .clear
        table.gridColor = XMColor.hairline
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = (22 * localScale).rounded()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.action = #selector(rowClicked(_:))

        // Fix comes FIRST: at the far right it was easy to miss.
        let fixCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fix"))
        fixCol.title = "Fix"
        fixCol.width = 60; fixCol.minWidth = 50
        table.addTableColumn(fixCol)
        let lineCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        lineCol.title = "Line"
        lineCol.width = 60; lineCol.minWidth = 50
        table.addTableColumn(lineCol)
        let colCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        colCol.title = "Col"
        colCol.width = 50; colCol.minWidth = 40
        table.addTableColumn(colCol)
        let msgCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("msg"))
        msgCol.title = "Message"
        msgCol.width = 420; msgCol.minWidth = 200
        msgCol.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(msgCol)
        scroll.documentView = table
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            reBtn.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            reBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        win.contentView = root
    }

    @objc private func revalidate(_ sender: Any?) { onRevalidateRequested?() }

    @objc private func rowClicked(_ sender: Any?) { fireRow() }
    @objc private func rowDoubleClicked(_ sender: Any?) { fireRow() }

    private func fireRow() {
        let row = table.selectedRow
        guard row >= 0, row < errors.count else { return }
        let e = errors[row]
        onErrorClicked?(e.line, e.column)
    }

    @objc private func fixButtonClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < errors.count else { return }
        onFixClicked?(errors[row])
    }

    // MARK: Data source
    func numberOfRows(in tableView: NSTableView) -> Int { errors.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < errors.count else { return nil }
        let e = errors[row]
        if col.identifier.rawValue == "fix" {
            return ErrorsPaneViewController.FixCell.make(
                in: tableView, error: e,
                target: self, action: #selector(fixButtonClicked(_:)))
        }
        let id = NSUserInterfaceItemIdentifier("valCell")
        let cell: NSTableCellView
        if let r = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = r
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = XMFont.mono(11.5 * localScale, .regular)
            tf.textColor = XMColor.text
            tf.lineBreakMode = .byTruncatingTail
            tf.usesSingleLineMode = true
            cell.addSubview(tf); cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        switch col.identifier.rawValue {
        case "line":
            cell.textField?.stringValue = "\(e.line)"
            cell.textField?.textColor = XMColor.accent
            cell.textField?.font = XMFont.mono(11.5 * localScale, .bold)
        case "col":
            cell.textField?.stringValue = "\(e.column)"
            cell.textField?.textColor = XMColor.text3
            cell.textField?.font = XMFont.mono(11.5 * localScale, .regular)
        default:
            cell.textField?.stringValue = e.message
            cell.textField?.textColor = XMColor.text
            cell.textField?.font = XMFont.mono(11.5 * localScale, .regular)
        }
        return cell
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    /// Re-read cached colours after a theme switch.
    func rebuildColors() {
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        window?.contentView?.layer?.backgroundColor = XMColor.bg.cgColor
        statusLabel.textColor = XMColor.text2
        hintLabel.textColor = XMColor.text3
        (table.enclosingScrollView)?.backgroundColor = XMColor.bgDeep
        table.backgroundColor = .clear
        table.reloadData()
        window?.contentView?.needsDisplayRecursively()
    }

}
