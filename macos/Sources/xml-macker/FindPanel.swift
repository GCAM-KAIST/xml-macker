import Cocoa
import UniformTypeIdentifiers

// Find & Replace pop-up window, one panel for both scopes: the
// whole file (Edit ▸ Find and Replace…, ⌘F) or a single element
// (tree right-click ▸ Find & Replace in <x>).
//
// Buttons: ◀ Previous · Next ▶ · Find All · Replace · Replace All.
// Find All results dock INTO this window, Excel-style (v0.30.0):
// the results stay inside the find and replace window instead of a
// separate one, the panel growing downward with a bordered
// Line | Path | Text table; click a row to jump; Export CSV… saves
// the table.
final class FindPanelController: NSWindowController, NSWindowDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate {

    struct Row { let line: Int; let path: String; let text: String }

    weak var source: SourceViewController?
    // Ancestor path for a line ("region[USA] › supplysector[…]"), 
    // provided by MainWindowController, which owns the tree.
    var pathForLine: ((Int) -> String)?
    // Fires after ANY replacement so MainWindowController can decide:
    // tag-touching → rebuild tree; value-only → refresh + revalidate.
    var onReplaced: ((_ find: String, _ replacement: String) -> Void)?
    var onClose: (() -> Void)?

    // nil scope = whole document (recomputed live so it tracks edits).
    private var scopeTitle: String = "whole file"
    private var scopeRange: NSRange?   // element scope; adjusted after replaces
    private var lastMatch: NSRange?
    private var rows: [Row] = []
    private var resultsShown = false

    private let findField = NSTextField()
    private let replField = NSTextField()
    private let caseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wordBox = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let scopeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsHeader = NSTextField(labelWithString: "")
    private let resultsScroll = NSScrollView()
    private let resultsTable = KeyActivatableTableView()
    private var exportButton: NSButton!
    private var resultsHeightCon: NSLayoutConstraint!

    private static let collapsedHeight: CGFloat = 190
    private static let resultsHeight: CGFloat = 300

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: Self.collapsedHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Find & Replace"
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.animationBehavior = .none
        super.init(window: win)
        win.delegate = self
        buildLayout()
        installLocalZoom()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Configure for a fresh invocation. scope == nil → whole file.
    func present(scopeTitle: String?, scopeRange: NSRange?, focusReplace: Bool) {
        self.scopeTitle = scopeTitle ?? "whole file"
        self.scopeRange = scopeRange
        self.lastMatch = nil
        scopeLabel.stringValue = "Scope: \(self.scopeTitle)"
        statusLabel.stringValue = ""
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(focusReplace ? replField : findField)
    }

    // This window's own zoom, like every other window: Command with the
    // wheel, or with +, - and 0. The slider stays the whole-app zoom.
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
        for f in [findField, replField] { f.font = XMFont.mono(12 * localScale, .regular) }
        caseBox.font = XMFont.ui(11 * localScale, .regular)
        wordBox.font = XMFont.ui(11 * localScale, .regular)
        scopeLabel.font = XMFont.ui(11 * localScale, .semibold)
        statusLabel.font = XMFont.ui(11 * localScale, .regular)
        resultsHeader.font = XMFont.ui(11 * localScale, .semibold)
        resultsTable.rowHeight = (20 * localScale).rounded()
        resultsTable.reloadData()
    }

    @objc func xmZoomIn(_ sender: Any?)    { setLocalScale(localScale * 1.1) }
    @objc func xmZoomOut(_ sender: Any?)   { setLocalScale(localScale / 1.1) }
    @objc func xmZoomReset(_ sender: Any?) { setLocalScale(1) }

    private func buildLayout() {
        guard let win = window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = XMColor.bg.cgColor

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = XMFont.uiCaption
            l.textColor = XMColor.text3
            return l
        }
        let findLabel = label("Find")
        let replLabel = label("Replace")

        for f in [findField, replField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.font = XMFont.mono(12 * localScale, .regular)
            f.bezelStyle = .roundedBezel
            root.addSubview(f)
        }
        findField.placeholderString = "Text to find"
        replField.placeholderString = "Replacement"
        findField.target = self
        findField.action = #selector(findNext(_:))   // Return in Find = Next
        root.addSubview(findLabel)
        root.addSubview(replLabel)

        caseBox.translatesAutoresizingMaskIntoConstraints = false
        caseBox.font = XMFont.ui(11 * localScale, .regular)
        root.addSubview(caseBox)

        // Whole word: "price" won't hit inside "price-elasticity".
        wordBox.translatesAutoresizingMaskIntoConstraints = false
        wordBox.font = XMFont.ui(11 * localScale, .regular)
        root.addSubview(wordBox)

        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.font = XMFont.ui(11 * localScale, .semibold)
        scopeLabel.textColor = XMColor.accent
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(scopeLabel)

        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.bezelStyle = .rounded
            b.controlSize = .regular
            return b
        }
        let prevBtn = button("◀ Previous", #selector(findPrev(_:)))
        let nextBtn = button("Next ▶", #selector(findNext(_:)))
        let allBtn  = button("Find All", #selector(findAll(_:)))
        let replBtn = button("Replace", #selector(replaceCurrent(_:)))
        let replAllBtn = button("Replace All", #selector(replaceAll(_:)))
        nextBtn.keyEquivalent = "\r"

        let findRow = NSStackView(views: [prevBtn, nextBtn, allBtn])
        let replRow = NSStackView(views: [replBtn, replAllBtn])
        for row in [findRow, replRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.orientation = .horizontal
            row.spacing = 8
            root.addSubview(row)
        }

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = XMFont.ui(11 * localScale, .regular)
        statusLabel.textColor = XMColor.text2
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        // ---- Docked results section (hidden until Find All) ----
        resultsHeader.translatesAutoresizingMaskIntoConstraints = false
        resultsHeader.font = XMFont.ui(11 * localScale, .semibold)
        resultsHeader.textColor = XMColor.text2
        resultsHeader.lineBreakMode = .byTruncatingTail
        root.addSubview(resultsHeader)

        exportButton = button("Export CSV…", #selector(exportCSV(_:)))
        exportButton.controlSize = .small
        root.addSubview(exportButton)

        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true
        resultsScroll.drawsBackground = true
        resultsScroll.backgroundColor = XMColor.bgDeep
        resultsScroll.borderType = .lineBorder

        resultsTable.style = .inset
        resultsTable.headerView = NSTableHeaderView()
        resultsTable.backgroundColor = .clear
        resultsTable.gridColor = XMColor.hairline
        resultsTable.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        resultsTable.usesAlternatingRowBackgroundColors = false
        resultsTable.rowHeight = (20 * localScale).rounded()
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.action = #selector(rowClicked(_:))
        resultsTable.doubleAction = #selector(rowClicked(_:))

        let lineCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        lineCol.title = "Line"
        lineCol.width = 66; lineCol.minWidth = 50
        resultsTable.addTableColumn(lineCol)
        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathCol.title = "Path"
        pathCol.width = 220; pathCol.minWidth = 100
        resultsTable.addTableColumn(pathCol)
        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textCol.title = "Text"
        textCol.width = 230; textCol.minWidth = 120
        textCol.resizingMask = [.autoresizingMask, .userResizingMask]
        resultsTable.addTableColumn(textCol)
        resultsScroll.documentView = resultsTable
        root.addSubview(resultsScroll)

        resultsHeightCon = resultsScroll.heightAnchor.constraint(equalToConstant: 0)
        setResultsVisible(false, animate: false)

        NSLayoutConstraint.activate([
            findLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            findLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 76),
            findField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            replLabel.topAnchor.constraint(equalTo: findLabel.bottomAnchor, constant: 16),
            replLabel.leadingAnchor.constraint(equalTo: findLabel.leadingAnchor),
            replField.centerYAnchor.constraint(equalTo: replLabel.centerYAnchor),
            replField.leadingAnchor.constraint(equalTo: findField.leadingAnchor),
            replField.trailingAnchor.constraint(equalTo: findField.trailingAnchor),

            caseBox.topAnchor.constraint(equalTo: replLabel.bottomAnchor, constant: 12),
            caseBox.leadingAnchor.constraint(equalTo: findLabel.leadingAnchor),
            wordBox.centerYAnchor.constraint(equalTo: caseBox.centerYAnchor),
            wordBox.leadingAnchor.constraint(equalTo: caseBox.trailingAnchor, constant: 12),
            scopeLabel.centerYAnchor.constraint(equalTo: caseBox.centerYAnchor),
            scopeLabel.leadingAnchor.constraint(equalTo: wordBox.trailingAnchor, constant: 16),
            scopeLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),

            findRow.topAnchor.constraint(equalTo: caseBox.bottomAnchor, constant: 12),
            findRow.leadingAnchor.constraint(equalTo: findLabel.leadingAnchor),
            replRow.centerYAnchor.constraint(equalTo: findRow.centerYAnchor),
            replRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            statusLabel.topAnchor.constraint(equalTo: findRow.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: findLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            resultsHeader.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            resultsHeader.leadingAnchor.constraint(equalTo: findLabel.leadingAnchor),
            resultsHeader.trailingAnchor.constraint(lessThanOrEqualTo: exportButton.leadingAnchor, constant: -10),
            exportButton.centerYAnchor.constraint(equalTo: resultsHeader.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            resultsScroll.topAnchor.constraint(equalTo: resultsHeader.bottomAnchor, constant: 6),
            resultsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            resultsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            resultsHeightCon,
            resultsScroll.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])

        win.contentView = root
    }

    // Grow/shrink the panel window so the docked results appear
    // below the buttons, Excel-style, keeping the top edge pinned.
    private func setResultsVisible(_ visible: Bool, animate: Bool = true) {
        guard resultsShown != visible || !animate else { return }
        resultsShown = visible
        resultsHeader.isHidden = !visible
        exportButton.isHidden = !visible
        resultsScroll.isHidden = !visible
        resultsHeightCon.constant = visible ? Self.resultsHeight : 0
        guard let win = window else { return }
        var f = win.frame
        let target = Self.collapsedHeight + (visible ? Self.resultsHeight + 40 : 0)
        let delta = target - win.contentRect(forFrameRect: f).height
        f.size.height += delta
        f.origin.y -= delta
        if animate { win.animator().setFrame(f, display: true) }
        else { win.setFrame(f, display: true) }
    }

    // MARK: mechanics

    private var needle: String { findField.stringValue }
    private var caseSensitive: Bool { caseBox.state == .on }
    private var wholeWord: Bool { wordBox.state == .on }

    private func effectiveScope() -> NSRange {
        if let r = scopeRange { return r }
        return source?.fullDocumentRange ?? NSRange(location: 0, length: 0)
    }

    private func note(_ s: String, isError: Bool = false) {
        statusLabel.stringValue = s
        statusLabel.textColor = isError ? XMColor.err : XMColor.text2
        if isError { NSSound.beep() }
    }

    @objc private func findNext(_ sender: Any?) { step(forward: true) }
    @objc private func findPrev(_ sender: Any?) { step(forward: false) }

    private func step(forward: Bool) {
        guard !needle.isEmpty, let src = source else { return }
        let scope = effectiveScope()
        let from: Int
        if let last = lastMatch {
            from = forward ? NSMaxRange(last) : last.location
        } else {
            from = forward ? scope.location : NSMaxRange(scope)
        }
        guard let hit = src.matchRange(of: needle, from: from, forward: forward,
                                       caseSensitive: caseSensitive,
                                       wholeWord: wholeWord, in: scope) else {
            lastMatch = nil
            note("Not found in \(scopeTitle)", isError: true)
            return
        }
        lastMatch = hit
        src.revealMatch(hit)
        note("Line \(src.lineNumber(forOffset: hit.location))")
    }

    @objc private func replaceCurrent(_ sender: Any?) {
        guard let src = source, !needle.isEmpty else { return }
        if lastMatch == nil { step(forward: true); return }
        guard let hit = lastMatch else { return }
        let replacement = replField.stringValue
        guard src.performEdit(range: hit, replacement: replacement) else {
            note("Could not replace", isError: true); return
        }
        let delta = (replacement as NSString).length - hit.length
        if var r = scopeRange { r.length += delta; scopeRange = r }
        lastMatch = NSRange(location: hit.location, length: (replacement as NSString).length)
        onReplaced?(needle, replacement)
        note("Replaced, finding next…")
        step(forward: true)
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard let src = source, !needle.isEmpty else { return }
        let replacement = replField.stringValue
        let scope = effectiveScope()
        let n = src.replaceAll(find: needle, with: replacement,
                               caseSensitive: caseSensitive,
                               wholeWord: wholeWord, in: scope)
        if n < 0 { note("Scope too large (over 100 M characters)", isError: true); return }
        if n == 0 { note("Not found in \(scopeTitle)", isError: true); return }
        let delta = ((replacement as NSString).length - (needle as NSString).length) * n
        if var r = scopeRange { r.length += delta; scopeRange = r }
        lastMatch = nil
        onReplaced?(needle, replacement)
        note("Replaced \(n) occurrence\(n == 1 ? "" : "s") in \(scopeTitle)")
    }

    @objc private func findAll(_ sender: Any?) {
        guard let src = source, !needle.isEmpty else { return }
        let scope = effectiveScope()
        let hits = src.allMatchRanges(of: needle, caseSensitive: caseSensitive,
                                      wholeWord: wholeWord, in: scope)
        guard !hits.isEmpty else {
            rows = []
            resultsTable.reloadData()
            setResultsVisible(false)
            note("Not found in \(scopeTitle)", isError: true)
            return
        }
        var built: [Row] = []
        built.reserveCapacity(hits.count)
        var lastLine = -1
        var lastPath = ""
        for h in hits {
            let line = src.lineNumber(forOffset: h.location)
            if line != lastLine {           // matches on the same line share a path
                lastPath = pathForLine?(line) ?? ""
                lastLine = line
            }
            // 4000, not the 300 default: the same rows feed the CSV, and
            // a GCAM line longer than 300 characters was silently clipped
            // in the export with nothing to say so.
            built.append(Row(line: line, path: lastPath, text: src.lineText(forLine: line, cap: 4000)))
        }
        rows = built
        let capped = hits.count >= 5000
        resultsHeader.stringValue = "\(rows.count)\(capped ? "+" : "") matches for \"\(needle)\" in \(scopeTitle)"
            + (capped ? " · first 5000" : "")
        resultsTable.reloadData()
        setResultsVisible(true)
        note("\(rows.count)\(capped ? "+" : "") match\(rows.count == 1 ? "" : "es")")
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = resultsTable.clickedRow >= 0 ? resultsTable.clickedRow : resultsTable.selectedRow
        guard row >= 0, row < rows.count else { return }
        source?.scrollToLine(rows[row].line)
    }

    /// Re-read cached colours after a theme switch.
    func rebuildColors() {
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        window?.contentView?.layer?.backgroundColor = XMColor.bg.cgColor
        scopeLabel.textColor = XMColor.accent
        statusLabel.textColor = XMColor.text2
        resultsHeader.textColor = XMColor.text2
        resultsScroll.backgroundColor = XMColor.bgDeep
        resultsTable.backgroundColor = .clear
        resultsTable.reloadData()
        window?.contentView?.needsDisplayRecursively()
    }

    // MARK: CSV export

    @objc private func exportCSV(_ sender: Any?) {
        guard let win = window, !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "find-results.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "Export the Find All results as CSV"
        let data = rows
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            // The byte-order mark CSVExport writes is what stops Excel
            // guessing MacRoman and turning "›" into mojibake. The path
            // is ours, so it also folds to plain ASCII; the matched text
            // is the user's own file and goes out untouched.
            // Named `table`, not `rows`: the controller already has a
            // `rows` property and shadowing it inside this closure reads
            // like a bug even though it compiles.
            let table = data.map { r in
                ["\(r.line)",
                 CSVExport.field(r.path, foldTypography: true),
                 CSVExport.field(r.text)]
            }
            guard CSVExport.write(header: ["Line", "Path", "Text"], rows: table, to: url) else {
                self?.note("Could not write \(url.lastPathComponent)", isError: true)
                return
            }
            NSWorkspace.shared.open(url)   // auto-open the export
        }
    }

    // MARK: table data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < rows.count else { return nil }
        let r = rows[row]
        let id = NSUserInterfaceItemIdentifier("findResCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = XMFont.mono(11 * localScale, .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.usesSingleLineMode = true
            cell.addSubview(tf); cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        switch col.identifier.rawValue {
        case "line":
            cell.textField?.stringValue = "\(r.line)"
            cell.textField?.textColor = XMColor.accent
            cell.textField?.font = XMFont.mono(11 * localScale, .bold)
        case "path":
            cell.textField?.stringValue = r.path
            cell.textField?.textColor = XMColor.syntaxAttr
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.textField?.toolTip = r.path
        default:
            cell.textField?.stringValue = r.text
            cell.textField?.textColor = XMColor.text
        }
        return cell
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
