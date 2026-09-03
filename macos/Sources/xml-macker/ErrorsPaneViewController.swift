import Cocoa

// Errors detail section, v0.44.3. The errors are a single window
// option beside Inspector, Chart and Preview rather than a tab
// buried inside Preview, and when a file has an error a red circle
// above the tab title marks it so it is clear there is something to
// click.
// The table, scope header and Fix buttons moved here verbatim from
// the old Preview ▸ Errors tab; the red badge sits on the Details
// rail's segmented control (ErrorBadgeView, owned by
// MainWindowController) and follows onErrorCountChanged.

// NSTableView subclass that fires its `action` selector when the
// user presses Return/Enter while a row is selected. Used for the
// Errors tables so the arrow keys navigate errors and Return jumps
// to the selected row's line in the source editor, matches the
// keyboard pattern in Xcode / VS Code.
final class KeyActivatableTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "\r" || key == "\n" || key == "\u{3}" {
            if selectedRow >= 0, let action = self.action {
                NSApp.sendAction(action, to: self.target, from: self)
            }
            return
        }
        super.keyDown(with: event)
    }
}

final class ErrorsPaneViewController: NSViewController,
                                      NSTableViewDataSource, NSTableViewDelegate {

    var onErrorClicked: ((_ line: Int, _ column: Int) -> Void)?
    // Fires when the user clicks a row's Fix button; the handler
    // applies error.fix to the source editor and re-validates.
    var onFixClicked: ((_ error: XMLStreamParser.ParseError) -> Void)?
    // Drives the red badge on the Details rail.
    var onErrorCountChanged: ((Int) -> Void)?

    private let headerNote = NSTextField(labelWithString: "")
    private let errorsScroll = NSScrollView()
    private let errorsTable = KeyActivatableTableView()

    private(set) var errors: [XMLStreamParser.ParseError] = []
    // The element that scoped the current live validation, shown in
    // the header so users know which subtree the list refers to.
    private var validationScopeLabel: String = ""

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        headerNote.translatesAutoresizingMaskIntoConstraints = false
        headerNote.font = XMFont.uiCaption
        headerNote.lineBreakMode = .byTruncatingTail
        v.addSubview(headerNote)

        errorsScroll.translatesAutoresizingMaskIntoConstraints = false
        errorsScroll.hasVerticalScroller = true
        errorsScroll.autohidesScrollers = true
        errorsScroll.drawsBackground = true
        errorsScroll.backgroundColor = XMColor.bgDeep
        errorsScroll.borderType = .noBorder

        errorsTable.style = .inset
        errorsTable.headerView = NSTableHeaderView()
        errorsTable.backgroundColor = .clear
        errorsTable.gridColor = XMColor.hairline
        errorsTable.usesAlternatingRowBackgroundColors = false
        errorsTable.rowHeight = 22
        errorsTable.dataSource = self
        errorsTable.delegate = self
        errorsTable.target = self
        errorsTable.action = #selector(errorRowClicked(_:))
        errorsTable.doubleAction = #selector(errorRowClicked(_:))
        // Fix comes FIRST: at the far right it was easy to miss.
        let fixCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fix"))
        fixCol.title = "Fix"; fixCol.width = 60; fixCol.minWidth = 50
        errorsTable.addTableColumn(fixCol)
        let lineCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        lineCol.title = "Line";  lineCol.width = 60;  lineCol.minWidth = 50
        errorsTable.addTableColumn(lineCol)
        let colCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        colCol.title = "Col";    colCol.width = 50;   colCol.minWidth = 40
        errorsTable.addTableColumn(colCol)
        let msgCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("msg"))
        msgCol.title = "Message"; msgCol.width = 340; msgCol.minWidth = 160
        msgCol.resizingMask = [.autoresizingMask, .userResizingMask]
        errorsTable.addTableColumn(msgCol)
        errorsScroll.documentView = errorsTable
        v.addSubview(errorsScroll)

        NSLayoutConstraint.activate([
            headerNote.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            headerNote.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            headerNote.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            errorsScroll.topAnchor.constraint(equalTo: headerNote.bottomAnchor, constant: 6),
            errorsScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            errorsScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            errorsScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        refreshHeader()
        view = v
    }

    // MARK: public API

    func setErrors(_ errors: [XMLStreamParser.ParseError]) {
        self.errors = errors
        errorsTable.reloadData()
        refreshHeader()
        onErrorCountChanged?(errors.count)
    }

    // Set by MainWindowController after a scoped validation run.
    func setValidationScope(_ label: String) {
        validationScopeLabel = label
        refreshHeader()
    }

    private func refreshHeader() {
        let scope = validationScopeLabel.isEmpty ? "" : "  ·  scope \(validationScopeLabel)"
        headerNote.stringValue = errors.isEmpty
            ? "No errors, XML is well-formed" + scope
            : "\(errors.count) error\(errors.count == 1 ? "" : "s"), click a row to jump to it" + scope
        headerNote.textColor = errors.isEmpty ? XMColor.ok : XMColor.err
    }

    // Global zoom slider hook, reloads the table so its cell fonts
    // (cached at viewFor:row: time) rebuild.
    func rebuildFonts() {
        headerNote.font = XMFont.uiCaption
        errorsTable.reloadData()
    }

    // Theme hook.
    func rebuildColors() {
        errorsScroll.backgroundColor = XMColor.bgDeep
        errorsTable.gridColor = XMColor.hairline
        refreshHeader()
        errorsTable.reloadData()
    }

    @objc private func errorRowClicked(_ sender: Any?) {
        let row = errorsTable.clickedRow >= 0 ? errorsTable.clickedRow : errorsTable.selectedRow
        guard row >= 0, row < errors.count else { return }
        let e = errors[row]
        onErrorClicked?(e.line, e.column)
    }

    @objc private func fixButtonClicked(_ sender: NSButton) {
        let row = errorsTable.row(for: sender)
        guard row >= 0, row < errors.count else { return }
        onFixClicked?(errors[row])
    }

    // MARK: table data source

    func numberOfRows(in tableView: NSTableView) -> Int { errors.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < errors.count else { return nil }
        let e = errors[row]
        if col.identifier.rawValue == "fix" {
            return FixCell.make(in: tableView, error: e,
                                target: self, action: #selector(fixButtonClicked(_:)))
        }
        let id = NSUserInterfaceItemIdentifier("errCell")
        let cell: NSTableCellView
        if let r = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = r
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = XMFont.mono(11.5, .regular)
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
            cell.textField?.font = XMFont.mono(11.5, .bold)
            cell.textField?.textColor = XMColor.accent
        case "col":
            cell.textField?.stringValue = "\(e.column)"
            cell.textField?.font = XMFont.mono(11.5, .regular)
            cell.textField?.textColor = XMColor.text3
        default:
            cell.textField?.stringValue = e.message
            cell.textField?.font = XMFont.mono(11.5, .regular)
            cell.textField?.textColor = XMColor.text
        }
        return cell
    }

    // Shared "Fix" button cell used by both error tables (Details rail
    // Errors section + Validation window). The button's tooltip spells
    // out exactly what the repair will do (e.g. Change to </period>);
    // rows without an automatic repair get an empty cell.
    enum FixCell {
        static func make(in tableView: NSTableView,
                         error: XMLStreamParser.ParseError,
                         target: AnyObject,
                         action: Selector) -> NSView {
            let id = NSUserInterfaceItemIdentifier("errFixCell")
            let cell: NSTableCellView
            let button: NSButton
            if let r = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
               let b = r.subviews.compactMap({ $0 as? NSButton }).first {
                cell = r; button = b
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let b = NSButton(title: "Fix", target: nil, action: nil)
                b.translatesAutoresizingMaskIntoConstraints = false
                b.bezelStyle = .inline
                b.controlSize = .small
                b.font = XMFont.ui(10, .semibold)
                cell.addSubview(b)
                NSLayoutConstraint.activate([
                    b.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    b.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                button = b
            }
            button.target = target
            button.action = action
            button.isHidden = (error.fix == nil)
            button.toolTip = error.fix?.title
            return cell
        }
    }
}

// Red count bubble pinned to the top-right corner of the "Errors"
// segment on the Details rail, the red circle above the tab title
// that flags a file with errors. Hidden at zero so a clean file
// shows nothing.
final class ErrorBadgeView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count == 0
            toolTip = count == 0 ? nil : "\(count) error\(count == 1 ? "" : "s"), open the Errors section"
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private var label: String { count > 99 ? "99+" : "\(count)" }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = (label as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(16, ceil(w) + 8), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        XMColor.err.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        let text = label as NSString
        let size = text.size(withAttributes: [.font: font])
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: [.font: font, .foregroundColor: XMColor.bgDeep])
        setAccessibilityLabel(toolTip ?? "")
    }
}
