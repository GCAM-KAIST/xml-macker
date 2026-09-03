import Cocoa

// DIFF (v0.39.0): a git-diff style view, two sources beside each
// other, the differences highlighted, copy from left or copy from
// right, and go next / go previous between them.
//
// Follows the conventions of git/VS Code/Kaleidoscope side-by-side
// diffs: line-based PATIENCE diff (git's --patience algorithm, 
// anchors on lines that are unique in both files, recurses between
// anchors; more readable hunks than plain Myers on structured text
// like XML), aligned rows (a pure insertion on one side gets a grey
// filler row on the other so everything lines up), red = only-left
// (removed), green = only-right (added), amber = changed, ◀ ▶ hunk
// navigation, and per-hunk "Use Left ▶ / ◀ Use Right" that applies
// the copy to the REAL document in its tab.

// MARK: - Engine

enum DiffEngine {

    struct Hunk {
        var leftStart: Int      // 0-based line index into the left doc
        var leftCount: Int
        var rightStart: Int
        var rightCount: Int
    }

    // Line-based patience diff. Returns hunks over 0-based line
    // indices; equal regions are implicit between hunks.
    static func diff(left: [String], right: [String]) -> [Hunk] {
        var hunks: [Hunk] = []
        diffRange(left, 0, left.count, right, 0, right.count, &hunks)
        return coalesce(hunks)
    }

    /// The same comparison over a SLICE of both files. StructuralDiff
    /// uses it to compare only the lines inside a matched pair of
    /// elements.
    static func diffSlice(left: [String], lFrom: Int, lTo: Int,
                          right: [String], rFrom: Int, rTo: Int) -> [Hunk] {
        var hunks: [Hunk] = []
        diffRange(left, lFrom, lTo, right, rFrom, rTo, &hunks)
        return coalesce(hunks)
    }

    private static func diffRange(_ l: [String], _ ls: Int, _ le: Int,
                                  _ r: [String], _ rs: Int, _ re: Int,
                                  _ out: inout [Hunk]) {
        var ls = ls, le = le, rs = rs, re = re
        // Trim common prefix / suffix, the huge win on near-identical
        // model files.
        while ls < le, rs < re, l[ls] == r[rs] { ls += 1; rs += 1 }
        while le > ls, re > rs, l[le - 1] == r[re - 1] { le -= 1; re -= 1 }
        if ls == le, rs == re { return }
        if ls == le || rs == re {
            out.append(Hunk(leftStart: ls, leftCount: le - ls,
                            rightStart: rs, rightCount: re - rs))
            return
        }

        // Patience anchors: lines that appear exactly once on EACH side.
        var lCount: [String: (n: Int, idx: Int)] = [:]
        for i in ls..<le { lCount[l[i], default: (0, i)].n += 1; if lCount[l[i]]!.n == 1 { lCount[l[i]]!.idx = i } }
        var candidates: [(li: Int, ri: Int)] = []
        var rCount: [String: (n: Int, idx: Int)] = [:]
        for i in rs..<re { rCount[r[i], default: (0, i)].n += 1; if rCount[r[i]]!.n == 1 { rCount[r[i]]!.idx = i } }
        for (line, info) in lCount where info.n == 1 {
            if let ri = rCount[line], ri.n == 1 {
                candidates.append((info.idx, ri.idx))
            }
        }
        guard !candidates.isEmpty else {
            out.append(Hunk(leftStart: ls, leftCount: le - ls,
                            rightStart: rs, rightCount: re - rs))
            return
        }

        // Longest increasing subsequence over the right indices (the
        // anchors that keep both sides in order).
        candidates.sort { $0.li < $1.li }
        var tails: [Int] = []            // tails[k] = candidate idx of LIS length k+1
        var prev = [Int](repeating: -1, count: candidates.count)
        for (i, c) in candidates.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[tails[mid]].ri < c.ri { lo = mid + 1 } else { hi = mid }
            }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
            prev[i] = lo > 0 ? tails[lo - 1] : -1
        }
        var chain: [(li: Int, ri: Int)] = []
        var cur = tails.last ?? -1
        while cur >= 0 { chain.append(candidates[cur]); cur = prev[cur] }
        chain.reverse()

        // Recurse between consecutive anchors.
        var pl = ls, pr = rs
        for a in chain {
            diffRange(l, pl, a.li, r, pr, a.ri, &out)
            pl = a.li + 1
            pr = a.ri + 1
        }
        diffRange(l, pl, le, r, pr, re, &out)
    }

    // Merge adjacent/overlapping hunks emitted by the recursion.
    private static func coalesce(_ hunks: [Hunk]) -> [Hunk] {
        let sorted = hunks.sorted { $0.leftStart < $1.leftStart }
        var out: [Hunk] = []
        for h in sorted {
            if var last = out.last,
               h.leftStart <= last.leftStart + last.leftCount,
               h.rightStart <= last.rightStart + last.rightCount {
                last.leftCount = max(last.leftCount, h.leftStart + h.leftCount - last.leftStart)
                last.rightCount = max(last.rightCount, h.rightStart + h.rightCount - last.rightStart)
                out[out.count - 1] = last
            } else {
                out.append(h)
            }
        }
        return out
    }
}

// MARK: - Window

enum DiffSide { case left, right }

final class DiffWindowController: NSWindowController, NSWindowDelegate,
                                  NSOutlineViewDataSource, NSOutlineViewDelegate,
                                  NSTextViewDelegate {

    // Applies a copy-hunk edit to the REAL document behind a side.
    // (MainWindowController routes: active tab → undoable performEdit,
    // parked tab → direct storage edit + dirty + reparse-on-activate.)
    var applyEdit: ((DiffSide, NSRange, String) -> Bool)?

    private var leftName: String
    private var rightName: String
    private weak var leftNameField: NSTextField?
    private weak var rightNameField: NSTextField?
    private var leftText: String
    private var rightText: String
    private var leftLineStarts: [Int] = []
    private var rightLineStarts: [Int] = []

    private var hunks: [DiffEngine.Hunk] = []
    // Navigation walks scopedIndices (all hunks, or only those inside
    // the tree-selected element). anchorPending = the next ▶ press
    // lands ON the first candidate instead of stepping past it.
    private var scopedIndices: [Int] = []
    private var scopedPos = 0
    private var anchorPending = false
    private var scopeNode: XMLTreeNode?
    private var scopeLines: ClosedRange<Int>?   // 0-based left lines
    private let scopeClearButton = NSButton()
    private let mainSplit = NSSplitView()
    // Per-side char offset of each hunk's first line in the DIFF VIEW
    // text (not the original doc).
    private var hunkViewOffsetsL: [Int] = []
    private var hunkViewOffsetsR: [Int] = []
    private var hunkViewRangesL: [NSRange] = []
    private var hunkViewRangesR: [NSRange] = []

    private let leftView = NSTextView()
    private let rightView = NSTextView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let statusField = NSTextField(labelWithString: "")
    private var syncing = false
    private var selfRef: DiffWindowController?
    var onClose: (() -> Void)?
    /// The tabs the host has open, so each side can be swapped without
    /// closing the window.
    var openFilesProvider: (() -> [(name: String, url: URL)])?
    /// Asks the host to put another file on one side. The host loads it
    /// if it is not open yet and calls replaceSide when it is ready.
    var onChangeSide: ((DiffSide, URL?) -> Void)?

    // v0.44.2, work on a compare that ran slowly: the compare runs
    // off the main thread, line arrays are cached so a copy re-diffs
    // without re-splitting 39 MB of text, and a generation counter
    // drops stale results. Navigation/copy buttons rest while a
    // compare is in flight because the view offsets are being rebuilt.
    private var leftLines: [String] = []
    private var rightLines: [String] = []
    private var compareGeneration = 0
    private var isComparing = false {
        didSet { for b in navButtons { b.isEnabled = !isComparing } }
    }
    private var navButtons: [NSButton] = []
    private weak var copyLeftButton: NSButton?
    private weak var copyRightButton: NSButton?
    private weak var undoCopyButton: NSButton?
    private weak var changeLeftButton: NSButton?
    private weak var changeRightButton: NSButton?

    /// Every copy applied from this window, newest last: where it went,
    /// how long the inserted text was, what it replaced, and the row the
    /// copy was made on so an undo can put the difference back there.
    private var copyUndo: [(target: DiffSide, start: Int, insertedLength: Int, removed: String, row: Int)] = []
    /// Set while re-running a copy the user chose to widen to the whole
    /// block, so the balance question is not asked twice.
    private var copyForced = false
    /// The comparison mode before the last copy, so a copy that broke the
    /// XML can be called out.
    private var noteBeforeCopy: CompareMode = .byElement

    // Tree sidebar for the cases where the comparison has to be
    // focused on one specific element: the LEFT file's element tree;
    // clicking jumps BOTH sides to that element's first line.
    private let treeOutline = NSOutlineView()
    private let treeScroll = NSScrollView()
    /// Which file the sidebar tree is read from. The file-name row at
    /// the top of the tree switches it, because a difference can only be
    /// scoped by one file's line ranges at a time and the interesting
    /// element is not always in the left one.
    private var treeSide: DiffSide = .left
    private var leftTree: XMLTreeNode?
    private var rightTree: XMLTreeNode?
    private var treeRoot: XMLTreeNode? { treeSide == .left ? leftTree : rightTree }
    private var treeSideName: String { treeSide == .left ? leftName : rightName }
    /// Parse errors from the tree's own parse, kept so opening the
    /// sidebar can still say where the tree stops.
    private var treeErrors: [XMLStreamParser.ParseError] = []
    private var treeParseStarted = false
    // Aligned-row bookkeeping filled by recompare().
    private var rowStartsL: [Int] = []
    private var rowStartsR: [Int] = []
    private var rowForLeftLine: [Int] = []
    private var rowForRightLine: [Int] = []
    private var hunkRowStart: [Int] = []
    private var hunkRowSpan: [Int] = []

    init(leftName: String, leftText: String, rightName: String, rightText: String) {
        self.leftName = leftName
        self.rightName = rightName
        self.leftText = leftText
        self.rightText = rightText

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Diff, \(leftName) ⟷ \(rightName)"
        win.minSize = NSSize(width: 800, height: 480)
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.setFrameAutosaveName("xml-mackerDiff")
        super.init(window: win)
        win.delegate = self
        buildUI()
        recompareAsync(scrollToFirst: true, reuseLines: false, refreshViews: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        selfRef = self
        if zoomMonitor == nil { installZoomMonitor() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        balanceSidesIfLopsided()
    }

    /// A saved divider position from an earlier session can leave one side
    /// a sliver, which makes a comparison look as though the second file
    /// never loaded. Two files being compared deserve equal room, so
    /// anything under a quarter of the width is evened out.
    private func balanceSidesIfLopsided() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainSplit.arrangedSubviews.count == 3 else { return }
            let total = self.mainSplit.bounds.width
            guard total > 200 else { return }
            let treeW = self.mainSplit.arrangedSubviews[0].isHidden ? 0 : self.mainSplit.arrangedSubviews[0].frame.width
            let leftW = self.mainSplit.arrangedSubviews[1].frame.width
            let rightW = self.mainSplit.arrangedSubviews[2].frame.width
            let textTotal = leftW + rightW
            guard textTotal > 100 else { return }
            if min(leftW, rightW) < textTotal * 0.25 {
                self.mainSplit.setPosition(treeW, ofDividerAt: 0)
                self.mainSplit.setPosition(treeW + textTotal / 2, ofDividerAt: 1)
            }
        }
    }

    /// Re-read cached colours after a theme switch.
    func rebuildColors() {
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        statusField.textColor = XMColor.text2
        for tv in [leftView, rightView] {
            tv.backgroundColor = XMColor.bgDeep
            tv.textColor = XMColor.text
        }
        for sc in [leftScroll, rightScroll, treeScroll] {
            sc.backgroundColor = XMColor.bgDeep
        }
        treeOutline.backgroundColor = .clear
        treeOutline.reloadData()
        window?.contentView?.needsDisplayRecursively()
    }

    func windowWillClose(_ notification: Notification) {
        if let m = zoomMonitor { NSEvent.removeMonitor(m); zoomMonitor = nil }
        compareGeneration += 1   // drop any in-flight result
        onClose?()
        selfRef = nil
    }

    // MARK: UI

    private func buildUI() {
        let content = NSView()

        func bar(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(b)
            return b
        }
        let prev = bar("◀ Previous", #selector(prevHunk))
        let next = bar("Next ▶", #selector(nextHunk))
        let treeBtn = bar("Tree", #selector(toggleTree))
        treeBtn.toolTip = "Show the element tree, click an element to jump to it and limit Next/Previous to differences inside it"
        let useLeft = bar("Copy From Left ▶", #selector(copyLeftToRight))
        useLeft.toolTip = "Replace this difference in \(rightName) with the lines from \(leftName)"
        let useRight = bar("◀ Copy From Right", #selector(copyRightToLeft))
        useRight.toolTip = "Replace this difference in \(leftName) with the lines from \(rightName)"
        copyLeftButton = useLeft
        copyRightButton = useRight
        // Undo Copy goes through the same edit path as the copy, so it
        // reaches a tab that is not the active one, where the editor's own
        // Undo cannot.
        let lineModeBox = NSButton(checkboxWithTitle: "Line by line",
                                   target: self, action: #selector(toggleLineMode(_:)))
        lineModeBox.state = lineMode ? .on : .off
        lineModeBox.controlSize = .small
        lineModeBox.font = XMFont.uiCaption
        lineModeBox.toolTip = "Next and Previous step one line at a time, and Copy moves that one line"
        lineModeBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(lineModeBox)
        let undoBtn = bar("Undo Copy", #selector(undoLastCopy))
        undoBtn.toolTip = "Put back what the last copy from this window replaced"
        undoBtn.isEnabled = false
        undoCopyButton = undoBtn
        navButtons = [prev, next, useLeft, useRight]

        scopeClearButton.title = "✕ Whole File"
        scopeClearButton.bezelStyle = .rounded
        scopeClearButton.controlSize = .small
        scopeClearButton.target = self
        scopeClearButton.action = #selector(clearScope)
        scopeClearButton.toolTip = "Stop limiting to the selected element, walk every difference again"
        scopeClearButton.isHidden = true
        scopeClearButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scopeClearButton)

        statusField.font = XMFont.uiBody
        statusField.textColor = XMColor.text2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusField)

        let leftChange = NSButton(title: "Change left ▾", target: self, action: #selector(changeLeft))
        let rightChange = NSButton(title: "Change right ▾", target: self, action: #selector(changeRight))
        for b in [leftChange, rightChange] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = XMFont.uiCaption
            b.toolTip = "Compare a different file on this side"
            b.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(b)
        }
        changeLeftButton = leftChange
        changeRightButton = rightChange

        func nameLabel(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = XMFont.mono(11, .semibold)
            f.textColor = XMColor.syntaxTag
            f.lineBreakMode = .byTruncatingMiddle
            f.translatesAutoresizingMaskIntoConstraints = false
            return f
        }

        func setupSide(_ tv: NSTextView, _ sc: NSScrollView) {
            tv.isEditable = false
            tv.isRichText = false
            tv.font = XMFont.mono(11, .regular)
            tv.backgroundColor = XMColor.bgDeep
            tv.textColor = XMColor.text
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
            tv.layoutManager?.allowsNonContiguousLayout = true
            tv.textContainerInset = NSSize(width: 4, height: 4)
            sc.documentView = tv
            sc.hasVerticalScroller = true
            sc.hasHorizontalScroller = true
            sc.drawsBackground = true
            sc.backgroundColor = XMColor.bgDeep
        }
        setupSide(leftView, leftScroll)
        setupSide(rightView, rightScroll)
        leftView.delegate = self
        rightView.delegate = self

        // Tree sidebar, organized single-line rows.
        treeOutline.dataSource = self
        treeOutline.delegate = self
        // Double-click a row to open or close it, not only the triangle.
        treeOutline.target = self
        treeOutline.doubleAction = #selector(treeDoubleClick)
        treeOutline.headerView = nil
        treeOutline.backgroundColor = .clear
        treeOutline.rowHeight = 20
        treeOutline.indentationPerLevel = 12
        treeOutline.intercellSpacing = NSSize(width: 3, height: 2)
        treeOutline.autoresizesOutlineColumn = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("el"))
        col.width = 600
        col.minWidth = 120
        treeOutline.addTableColumn(col)
        treeOutline.outlineTableColumn = col
        treeScroll.documentView = treeOutline
        treeScroll.hasVerticalScroller = true
        treeScroll.hasHorizontalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = true
        treeScroll.backgroundColor = XMColor.bgDeep

        // Mouse-adjustable dividers: a real split view holds
        // [tree | left source | right source].
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.autosaveName = "xml-mackerDiffSplit"

        func pane(label: NSTextField?, body: NSView) -> NSView {
            let p = NSView()
            body.translatesAutoresizingMaskIntoConstraints = false
            p.addSubview(body)
            var topAnchor = p.topAnchor
            var topConst: CGFloat = 0
            if let label {
                p.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: p.topAnchor, constant: 2),
                    label.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: p.trailingAnchor, constant: -6),
                ])
                topAnchor = label.bottomAnchor
                topConst = 4
            }
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: topAnchor, constant: topConst),
                body.leadingAnchor.constraint(equalTo: p.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: p.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: p.bottomAnchor),
            ])
            return p
        }
        let treePane = pane(label: nil, body: treeScroll)
        treePane.isHidden = true    // Tree button reveals it
        let lName = nameLabel(leftName)
        let rName = nameLabel(rightName)
        leftNameField = lName
        rightNameField = rName
        let leftPane = pane(label: lName, body: leftScroll)
        let rightPane = pane(label: rName, body: rightScroll)
        mainSplit.addArrangedSubview(treePane)
        mainSplit.addArrangedSubview(leftPane)
        mainSplit.addArrangedSubview(rightPane)
        mainSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        content.addSubview(mainSplit)

        // Mirrored scrolling: aligned rows → identical heights, so the
        // clip origins can be mirrored 1:1.
        for (sc, other) in [(leftScroll, rightScroll), (rightScroll, leftScroll)] {
            sc.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sc.contentView, queue: .main
            ) { [weak self, weak sc, weak other] _ in
                guard let self, let sc, let other, !self.syncing else { return }
                self.syncing = true
                other.contentView.setBoundsOrigin(sc.contentView.bounds.origin)
                other.reflectScrolledClipView(other.contentView)
                self.syncing = false
            }
        }

        // The left group is a stack view, not a chain of anchors. Two of
        // its buttons come and go (✕ Whole File only exists while a scope
        // is set), and with hand-written anchors that meant either an
        // overlap, which is what happened, or a hole where a hidden
        // button used to be. A stack view lays out only what is visible.
        let leftGroup = NSStackView(views: [prev, next, treeBtn, leftChange, rightChange, scopeClearButton])
        leftGroup.orientation = .horizontal
        leftGroup.alignment = .centerY
        leftGroup.spacing = 6
        leftGroup.setCustomSpacing(12, after: next)
        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(leftGroup)

        let rightGroup = NSStackView(views: [lineModeBox, undoBtn, useLeft, useRight])
        rightGroup.orientation = .horizontal
        rightGroup.alignment = .centerY
        rightGroup.spacing = 6
        rightGroup.setCustomSpacing(10, after: lineModeBox)
        rightGroup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rightGroup)

        NSLayoutConstraint.activate([
            leftGroup.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            leftGroup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            rightGroup.centerYAnchor.constraint(equalTo: leftGroup.centerYAnchor),
            rightGroup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            rightGroup.leadingAnchor.constraint(greaterThanOrEqualTo: leftGroup.trailingAnchor, constant: 12),
            statusField.centerYAnchor.constraint(equalTo: leftGroup.centerYAnchor),
            statusField.leadingAnchor.constraint(greaterThanOrEqualTo: leftGroup.trailingAnchor, constant: 12),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: rightGroup.leadingAnchor, constant: -8),

            mainSplit.topAnchor.constraint(equalTo: leftGroup.bottomAnchor, constant: 8),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window?.contentView = content
    }

    // MARK: Tree sidebar

    @objc private func toggleTree() {
        let treePane = mainSplit.arrangedSubviews[0]
        let showing = !treePane.isHidden
        treePane.isHidden = showing
        mainSplit.adjustSubviews()
        if !showing { mainSplit.setPosition(240, ofDividerAt: 0) }
        if !showing, treeParseStarted, treeRoot != nil {
            reloadTreeRows()
        } else if !showing, !treeParseStarted {
            treeParseStarted = true
            statusField.stringValue = "Reading the tree…"
            let text = leftText
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = XMLStreamParser().parseText(text)
                DispatchQueue.main.async {
                    guard let self else { return }
                    result.root.name = self.leftName
                    self.leftTree = result.root
                    self.treeOutline.reloadData()
                    self.treeOutline.expandItem(nil, expandChildren: false)
                    for child in self.elementChildren(of: result.root) {
                        self.treeOutline.expandItem(child)
                    }
                    if let first = result.errors.first {
                        // The tree comes from a real XML parse, which stops at
                        // the first error, so it can look as though the file
                        // holds only one region. Say so instead of looking
                        // truncated.
                        self.statusField.stringValue = "Tree stops at line \(first.line): \(first.message). Fix that spot to see the rest"
                    } else {
                        self.statusField.stringValue = "Click an element to jump to it"
                    }
                }
            }
        }
    }

    private func elementChildren(of node: XMLTreeNode) -> [XMLTreeNode] {
        node.children.filter { $0.kind == .element }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let root = treeRoot else { return 0 }
        return elementChildren(of: (item as? XMLTreeNode) ?? root).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let root = treeRoot else { return XMLTreeNode(id: -1, kind: .element, name: "?") }
        return elementChildren(of: (item as? XMLTreeNode) ?? root)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? XMLTreeNode else { return false }
        return !elementChildren(of: n).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? XMLTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.usesSingleLineMode = true
            tf.maximumNumberOfLines = 1
            tf.cell?.wraps = false
            tf.cell?.truncatesLastVisibleLine = true
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let isRoot = n === treeRoot
        let detail = isRoot
            ? "\(treeSide == .left ? "left" : "right") file · click here to show the tree of the \(treeSide == .left ? "right" : "left") file"
            : n.displayDetail
        let str = NSMutableAttributedString(string: isRoot ? treeSideName : n.displayLabel, attributes: [
            .font: XMFont.mono(11, .medium),
            .foregroundColor: isRoot ? XMColor.accent : XMColor.syntaxTag])
        if !detail.isEmpty {
            str.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: XMFont.mono(10, .regular), .foregroundColor: XMColor.text3]))
        }
        cell.textField?.attributedStringValue = str
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = treeOutline.selectedRow
        guard row >= 0, let node = treeOutline.item(atRow: row) as? XMLTreeNode else { return }
        // The file-name row is the switch to the other file's tree.
        if node === treeRoot {
            switchTreeSide()
            return
        }
        // Selecting an element SCOPES the diff walk to it: Next ▶ /
        // ◀ Previous only visit differences inside its line range.
        if node.parent == nil || node.kind == .document {
            clearScope()
        } else {
            scopeNode = node
            scopeLines = (node.startLine - 1)...(max(node.startLine, node.endLine) - 1)
            rebuildScopedIndices()
            scopedPos = 0
            anchorPending = true
            scopeClearButton.isHidden = false
            updateStatus()
        }
        jumpToTreeLine(node.startLine)
    }

    /// Read the tree from the OTHER file. The scope belongs to the old
    /// side's line numbers, so it is dropped; the comparison itself is
    /// untouched.
    private func switchTreeSide() {
        treeSide = treeSide == .left ? .right : .left
        clearScope()
        if treeRoot == nil {
            statusField.stringValue = "Reading the tree of \(treeSideName)…"
            let text = treeSide == .left ? leftText : rightText
            let side = treeSide
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = XMLStreamParser().parseText(text)
                DispatchQueue.main.async {
                    guard let self, self.treeSide == side else { return }
                    result.root.name = self.treeSideName
                    if side == .left { self.leftTree = result.root } else { self.rightTree = result.root }
                    self.treeErrors = result.errors
                    self.reloadTreeRows()
                }
            }
        } else {
            reloadTreeRows()
        }
    }

    private func reloadTreeRows() {
        // A re-read after a copy must not throw the user back to the top
        // of the tree, so the row and the scroll position come back.
        let keptRow = treeOutline.selectedRow
        let keptOffset = treeScroll.contentView.bounds.origin.y
        defer {
            if keptRow >= 0, keptRow < treeOutline.numberOfRows {
                treeOutline.selectRowIndexes(IndexSet(integer: keptRow), byExtendingSelection: false)
            }
            if keptOffset > 0 {
                treeScroll.contentView.scroll(to: NSPoint(x: 0, y: keptOffset))
                treeScroll.reflectScrolledClipView(treeScroll.contentView)
            }
        }
        treeOutline.reloadData()
        guard let root = treeRoot else { return }
        treeOutline.expandItem(nil, expandChildren: false)
        // Open the single-child chain down to the first level that
        // branches, so the tree shows real content at once instead of one
        // row called #document. Never open a level that would add
        // thousands of rows.
        var node: XMLTreeNode? = root
        var added = 0
        while let n = node {
            let kids = elementChildren(of: n)
            guard !kids.isEmpty, added + kids.count <= 2000 else { break }
            treeOutline.expandItem(n)
            added += kids.count
            node = kids.count == 1 ? kids[0] : nil
        }
        if let first = treeErrors.first {
            statusField.stringValue = "Tree stops at line \(first.line): \(first.message). Fix that spot to see the rest"
        } else {
            updateStatus()
        }
    }

    /// Scroll both sides to the aligned row of a 1-based line in the file
    /// the TREE is showing.
    private func jumpToTreeLine(_ line: Int) {
        let map = treeSide == .left ? rowForLeftLine : rowForRightLine
        let i = line - 1
        guard i >= 0, i < map.count else { return }
        let row = map[i]
        syncing = true
        let lr = rowsRange(rowStartsL, leftView, row, 1)
        let rr = rowsRange(rowStartsR, rightView, row, 1)
        leftView.scrollRangeToVisible(lr)
        rightView.scrollRangeToVisible(rr)
        syncing = false
    }

    @objc private func changeLeft()  { showChangeMenu(.left) }
    @objc private func changeRight() { showChangeMenu(.right) }

    /// The other open tabs, plus a way to reach a file that is not open.
    private func showChangeMenu(_ side: DiffSide) {
        let menu = NSMenu()
        let current = side == .left ? leftName : rightName
        for f in openFilesProvider?() ?? [] where f.name != current {
            let item = NSMenuItem(title: f.name, action: #selector(pickChange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [side == .left ? "left" : "right", f.url] as [Any]
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let browse = NSMenuItem(title: "Open another file…", action: #selector(pickChange(_:)), keyEquivalent: "")
        browse.target = self
        browse.representedObject = [side == .left ? "left" : "right"] as [Any]
        menu.addItem(browse)
        let anchor = side == .left ? changeLeftButton : changeRightButton
        if let anchor {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
        }
    }

    @objc private func pickChange(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [Any], let which = parts.first as? String else { return }
        let side: DiffSide = which == "left" ? .left : .right
        onChangeSide?(side, parts.count > 1 ? parts[1] as? URL : nil)
    }

    /// Put a different file on one side and compare again.
    func replaceSide(_ side: DiffSide, name: String, text: String) {
        if side == .left {
            leftName = name; leftText = text; leftTree = nil
        } else {
            rightName = name; rightText = text; rightTree = nil
        }
        // The copy history belongs to the file that just left.
        copyUndo.removeAll()
        undoCopyButton?.isEnabled = false
        treeParseStarted = false
        clearScope()
        window?.title = "Diff, \(leftName) ⟷ \(rightName)"
        leftNameField?.stringValue = leftName
        rightNameField?.stringValue = rightName
        recompareAsync(scrollToFirst: true, reuseLines: false, refreshViews: true)
    }

    /// Escape drops a row selection, so the next copy takes the whole
    /// difference again.
    override func cancelOperation(_ sender: Any?) {
        if selectedRows() != nil { clearRowSelection() }
    }

    @objc private func treeDoubleClick() {
        let row = treeOutline.clickedRow
        guard row >= 0, let item = treeOutline.item(atRow: row) else { return }
        if treeOutline.isItemExpanded(item) { treeOutline.collapseItem(item) }
        else { treeOutline.expandItem(item) }
    }

    @objc private func clearScope() {
        scopeNode = nil
        scopeLines = nil
        rebuildScopedIndices()
        scopedPos = scopedIndices.isEmpty ? 0 : min(scopedPos, scopedIndices.count - 1)
        anchorPending = false
        scopeClearButton.isHidden = true
        updateStatus()
    }

    /// Keeps the scope over the same element after a copy changed the
    /// number of lines above or inside it.
    private func shiftScope(target: DiffSide, editLine: Int, delta: Int) {
        guard delta != 0, treeSide == target, let r = scopeLines else { return }
        if editLine <= r.lowerBound {
            scopeLines = max(0, r.lowerBound + delta)...max(0, r.upperBound + delta)
        } else if editLine <= r.upperBound {
            scopeLines = r.lowerBound...max(r.lowerBound, r.upperBound + delta)
        }
    }

    private func rebuildScopedIndices() {
        if let range = scopeLines {
            // Filter by the line ranges of the file the tree is showing:
            // the scope came from that file's element.
            scopedIndices = hunks.indices.filter { i in
                let h = hunks[i]
                let start = treeSide == .left ? h.leftStart : h.rightStart
                let count = treeSide == .left ? h.leftCount : h.rightCount
                let end = count > 0 ? start + count - 1 : start
                return start <= range.upperBound && end >= range.lowerBound
            }
        } else {
            scopedIndices = Array(hunks.indices)
        }
    }

    // "inside region USA" rather than "inside <region>": the key
    // attribute is the name people actually use.
    /// How the last comparison was made. Element-aware pairs sectors by
    /// identity wherever they sit; the line fallback is used when either
    /// file has an XML error or its shape defeats the walker.
    private enum CompareMode {
        case byElement
        case byLine(reason: String)
    }
    private var compareMode: CompareMode = .byLine(reason: "not compared yet")

    private var modeSuffix: String {
        switch compareMode {
        case .byElement: return " · by element"
        case .byLine(let reason): return " · line by line, \(reason)"
        }
    }

    private var scopeSuffix: String {
        guard let n = scopeNode else { return "" }
        let key = n.attributes.first(where: { ["name", "year", "id", "key", "type"].contains($0.name) })
            ?? n.attributes.first
        let label = key.map { "\(n.displayLabel) \($0.value)" } ?? "<\(n.displayLabel)>"
        return ", inside \(label) only"
    }

    /// " · 108 lines" for the current difference. A merged block is one
    /// difference but many lines, so the count of differences alone tells
    /// you nothing about how much a copy would move.
    private var hunkSizeNote: String {
        guard !scopedIndices.isEmpty, scopedPos >= 0, scopedPos < scopedIndices.count else { return "" }
        let idx = scopedIndices[scopedPos]
        guard idx < hunkRowSpan.count else { return "" }
        let rows = hunkRowSpan[idx]
        return " · \(Self.grouped(rows)) line\(rows == 1 ? "" : "s")"
    }

    /// How many differences there are outside the scope, so the
    /// restriction is unmissable.
    /// 36,158 rather than 36158: at these sizes the grouping is the
    /// difference between a number and a smear.
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private var wholeFileHint: String {
        scopeNode != nil ? " (\(Self.grouped(hunks.count)) in the whole file)" : ""
    }

    /// Prefix for the next status line after a copy or an undo, so the
    /// copy is visibly acknowledged even when the next difference looks
    /// just like the last one.
    private var lastCopyNote = ""

    /// Shown until the user moves on. lastCopyNote is consumed by the
    /// first status refresh, and in line mode adopt() refreshes twice, so
    /// the one thing worth reading was being wiped a moment after it
    /// appeared. This is the message that explains a broken file, so it
    /// stays until Next, Previous, another copy or an undo.
    private var brokeWarning = ""

    // MARK: this window's own zoom
    //
    // The slider in the main window is the whole application's zoom.
    // Command-scroll and command +/-/0 zoom only the window they are used
    // in, which is what you want when the Diff text is too small but
    // everything else is fine. Both sides scale together, so the rows stay
    // level.
    private var localZoom: CGFloat = 1
    private var zoomMonitor: Any?

    private func installZoomMonitor() {
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // A pinch on the trackpad zooms on its own; the wheel needs
            // Command so an ordinary scroll still scrolls.
            if event.type == .magnify {
                let m = event.magnification
                if m != 0 { self.setLocalZoom(self.localZoom * (1 + m)) }
                return nil
            }
            guard event.modifierFlags.contains(.command) else { return event }
            let dy = event.scrollingDeltaY
            if dy != 0 { self.setLocalZoom(self.localZoom * (dy > 0 ? 1.06 : 1 / 1.06)) }
            return nil
        }
    }

    private func setLocalZoom(_ z: CGFloat) {
        localZoom = max(0.5, min(3.0, z))
        let f = XMFont.mono(11 * localZoom, .regular)
        for v in [leftView, rightView] {
            guard let storage = v.textStorage, storage.length > 0 else { continue }
            storage.addAttribute(.font, value: f, range: NSRange(location: 0, length: storage.length))
        }
        // The rows changed height, so the row bands have to be redrawn
        // where they now are.
        if !scopedIndices.isEmpty, scopedPos < scopedIndices.count {
            let idx = scopedIndices[scopedPos]
            if idx < hunkRowStart.count { setEmphasis(row: hunkRowStart[idx], span: hunkRowSpan[idx]) }
        }
    }

    @objc func xmZoomIn(_ sender: Any?)    { setLocalZoom(localZoom * 1.1) }
    @objc func xmZoomOut(_ sender: Any?)   { setLocalZoom(localZoom / 1.1) }
    @objc func xmZoomReset(_ sender: Any?) { setLocalZoom(1) }

    // "Stay where we are" after a copy or an undo: the row to continue
    // from and the viewport position, consumed by the next adopt().
    private var keepRow = -1
    private var keepOffset: CGFloat = -1
    /// True when a copy or an undo left no difference at or below where
    /// the user was: nothing is current, and Next starts from the top.
    private var pastEnd = false

    /// `row` is the aligned row to continue from: the row right after the
    /// lines a copy put in (they become "same" rows exactly where they
    /// were selected), the row now standing where lines were removed, or
    /// the row an undo restores a difference at.
    ///
    /// Rows, not line numbers: rows above an edit are unchanged in the new
    /// alignment, whereas pairing elements by identity can map a line
    /// number on one side to a row far away. And not the block's first
    /// row: a line-by-line copy splits a block, and the top part above the
    /// copied line used to win, which is the "selection goes up" report.
    private func rememberPlace(_ row: Int) {
        keepRow = row
        keepOffset = leftScroll.contentView.bounds.origin.y
    }

    /// Index of the first difference whose rows END AFTER `row`, or the
    /// count when there is none.
    private func firstHunkEndingAfterRow(_ row: Int) -> Int {
        var lo = 0, hi = hunkRowStart.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hunkRowStart[mid] + hunkRowSpan[mid] <= row { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func updateStatus() {
        if isComparing { statusField.stringValue = "Comparing…"; return }
        if scopedIndices.isEmpty {
            statusField.stringValue = brokeWarning + (hunks.isEmpty
                ? "No differences, the files are identical\(modeSuffix)"
                : "No differences\(scopeSuffix)\(modeSuffix)")
        } else if pastEnd {
            statusField.stringValue = "\(brokeWarning)\(lastCopyNote)No differences after this point\(scopeSuffix)\(wholeFileHint), press ◀ Previous, or Next ▶ to start from the top\(modeSuffix)"
            lastCopyNote = ""
        } else if anchorPending {
            statusField.stringValue = "\(brokeWarning)\(scopedIndices.count) difference\(scopedIndices.count == 1 ? "" : "s")\(hunkSizeNote)\(scopeSuffix), press Next ▶\(wholeFileHint)\(modeSuffix)"
        } else {
            statusField.stringValue = "\(brokeWarning)\(lastCopyNote)\(linePrefix)Difference \(Self.grouped(scopedPos + 1)) of \(Self.grouped(scopedIndices.count))\(hunkSizeNote)\(selectionNote)\(scopeSuffix)\(wholeFileHint)\(modeSuffix)"
            lastCopyNote = ""
        }
    }

    // Scroll BOTH sides to the aligned row of a 1-based LEFT line.
    private func jumpToLeftLine(_ line: Int) {
        let idx = line - 1
        guard idx >= 0, idx < rowForLeftLine.count else { return }
        let row = rowForLeftLine[idx]
        guard row < rowStartsL.count, row < rowStartsR.count else { return }
        let offL = rowStartsL[row]
        let offR = rowStartsR[row]
        let lenL = (row + 1 < rowStartsL.count ? rowStartsL[row + 1] : offL) - offL
        let lenR = (row + 1 < rowStartsR.count ? rowStartsR[row + 1] : offR) - offR
        syncing = true
        leftView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: offL, length: min(1, max(0, lenL))))
        rightView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: offR, length: min(1, max(0, lenR))))
        leftView.scrollRangeToVisible(NSRange(location: offL, length: max(0, lenL)))
        rightView.scrollRangeToVisible(NSRange(location: offR, length: max(0, lenR)))
        leftView.setSelectedRange(NSRange(location: offL, length: max(0, lenL)))
        rightView.setSelectedRange(NSRange(location: offR, length: max(0, lenR)))
        syncing = false
    }

    // MARK: Model → view

    private static func splitLines(_ s: String) -> [String] {
        // NATIVE lines. The document text arrives NSString-backed (it is
        // the editor's storage); splitting that with Foundation yields
        // NSString-backed pieces whose hashing and comparison inside the
        // diff run about 100× slower (measured 11.8 s vs 0.15 s on the
        // 37 MB GCAM file). One contiguous UTF-8 copy first, then a byte
        // split on LF (so CRLF files still split per line).
        var text = s
        text.makeContiguousUTF8()
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // A trailing newline yields one phantom empty tail, drop it so
        // line counts match the editor's.
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // Everything the aligned views need, built off the main thread.
    private struct AlignedModel {
        var hunks: [DiffEngine.Hunk] = []
        var leftLineStarts: [Int] = []
        var rightLineStarts: [Int] = []
        var lOut = ""
        var rOut = ""
        var lRuns: [(NSRange, NSColor)] = []
        var rRuns: [(NSRange, NSColor)] = []
        var hunkViewOffsetsL: [Int] = []
        var hunkViewOffsetsR: [Int] = []
        var hunkViewRangesL: [NSRange] = []
        var hunkViewRangesR: [NSRange] = []
        var rowStartsL: [Int] = []
        var rowStartsR: [Int] = []
        var rowForLeftLine: [Int] = []
        var rowForRightLine: [Int] = []
        /// First aligned row of each difference, and how many rows it
        /// spans. Everything that has to "stay where you are" after a copy
        /// works in rows, because rows above an edit are unchanged while a
        /// line number on one side can map to a row far away once elements
        /// are paired by identity.
        var hunkRowStart: [Int] = []
        var hunkRowSpan: [Int] = []
        /// Character ranges on each side where the other file has the
        /// content and this one has nothing.
        ///
        /// These were briefly used to draw a diagonal hatch through a
        /// custom NSLayoutManager. That hung the app: drawBackground ran
        /// enumerateLineFragments over every filler run on every repaint,
        /// and with 36,000 differences, some of them a thousand lines
        /// long, it never finished. A filler run is marked by its
        /// background colour and by the caption on its first row instead,
        /// neither of which asks the layout engine anything. Do not put
        /// layout queries inside a draw pass on documents this size.
        var fillerL: [NSRange] = []
        var fillerR: [NSRange] = []
        /// The note at the head of a filler run. Drawn dim and italic in
        /// the interface face so it reads as a remark about the file
        /// rather than a line from inside it, which is how it read when
        /// it was set in the same monospace as the XML.
        var captionsL: [NSRange] = []
        var captionsR: [NSRange] = []
    }

    private struct RunColors {
        let changed: NSColor
        let removed: NSColor
        let added: NSColor
        let filler: NSColor
    }

    // Re-diff both texts and rebuild the aligned model in the
    // background; the window stays responsive and says "Comparing…".
    // reuseLines: the caller already patched leftLines/rightLines
    // (copy hunk), so the 39 MB split is skipped. refreshViews false =
    // the text views were patched in place and only the model needs to
    // catch up, a length check guards against drift.
    private func recompareAsync(scrollToFirst: Bool, reuseLines: Bool, refreshViews: Bool) {
        compareGeneration += 1
        let gen = compareGeneration
        isComparing = true
        statusField.stringValue = "Comparing…"
        let lt = leftText, rt = rightText
        let cachedL: [String]? = reuseLines ? leftLines : nil
        let cachedR: [String]? = reuseLines ? rightLines : nil
        let colors = RunColors(changed: XMColor.warn.withAlphaComponent(0.16),
                               removed: XMColor.err.withAlphaComponent(0.16),
                               added: XMColor.ok.withAlphaComponent(0.16),
                               // Not a 10 percent grey: a filler run used
                               // to be nearly invisible on the Light theme
                               // and read as "the file did not load".
                               filler: XMColor.text3.withAlphaComponent(0.22))
        let tStart = Date()
        let lName = leftName, rName = rightName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lLines = cachedL ?? Self.splitLines(lt)
            let rLines = cachedR ?? Self.splitLines(rt)
            let tSplit = Date()

            // Element-aware alignment first. Two GCAM files that list the
            // same sectors in a different order cannot be paired by a line
            // algorithm: it can only report "1,146 lines removed here,
            // 1,146 added there", which reads as if the second file had
            // not loaded. Pairing by (tag name, key attribute) puts USA's
            // trn_aviation_intl beside the other file's trn_aviation_intl
            // wherever it sits.
            let lParse = XMLStreamParser().parseText(lt)
            let rParse = XMLStreamParser().parseText(rt)
            var aligned: [StructuralDiff.Segment]? = nil
            var mode: CompareMode
            if let e = lParse.errors.first {
                mode = .byLine(reason: "\(lName) has an XML error at line \(e.line)")
            } else if let e = rParse.errors.first {
                mode = .byLine(reason: "\(rName) has an XML error at line \(e.line)")
            } else {
                aligned = StructuralDiff.align(leftRoot: lParse.root, rightRoot: rParse.root,
                                               leftLines: lLines, rightLines: rLines)
                mode = aligned == nil
                    ? .byLine(reason: "the files do not line up element by element")
                    : .byElement
            }
            let tAlign = Date()

            let model = Self.buildModel(lLines: lLines, rLines: rLines,
                                        aligned: aligned,
                                        leftName: lName, rightName: rName,
                                        colors: colors)
            let tModel = Date()
            DispatchQueue.main.async {
                guard let self, gen == self.compareGeneration else { return }
                Diag.log("diff compare: split \(String(format: "%.3f", tSplit.timeIntervalSince(tStart)))s parse+align \(String(format: "%.3f", tAlign.timeIntervalSince(tSplit)))s model \(String(format: "%.3f", tModel.timeIntervalSince(tAlign)))s, on main after \(String(format: "%.3f", Date().timeIntervalSince(tStart)))s")
                // A copy that turned an element-aware comparison into a
                // line-by-line one broke the XML. Say so where the user is
                // already looking.
                if !self.lastCopyNote.isEmpty,
                   case .byElement = self.noteBeforeCopy,
                   case .byLine(let why) = mode {
                    self.brokeWarning = "⚠ That copy broke the XML (\(why)). Press Undo Copy to put it back., "
                }
                if case .byElement = mode { self.brokeWarning = "" }
                self.noteBeforeCopy = mode
                self.compareMode = mode
                // The sidebar wanted this parse anyway; hand it over so
                // opening the tree is instant and always matches the
                // comparison.
                if lParse.errors.isEmpty || self.leftTree == nil {
                    lParse.root.name = self.leftName
                    self.leftTree = lParse.root
                    self.treeParseStarted = true
                    if self.treeSide == .left {
                        self.treeErrors = lParse.errors
                        self.reloadTreeRows()
                    }
                }
                // The same for the right file, so a copy into it does not
                // leave the tree showing the lines it used to have.
                if rParse.errors.isEmpty || self.rightTree == nil {
                    rParse.root.name = self.rightName
                    self.rightTree = rParse.root
                    if self.treeSide == .right {
                        self.treeErrors = rParse.errors
                        self.reloadTreeRows()
                    }
                }
                self.leftLines = lLines
                self.rightLines = rLines
                let tAdopt = Date()
                // Cleared BEFORE adopt: adopt writes the status line, and
                // the "Comparing…" guard would otherwise win and stay.
                self.isComparing = false
                self.adopt(model, refreshViews: refreshViews, scrollToFirst: scrollToFirst)
                Diag.log("diff compare: adopt \(String(format: "%.3f", Date().timeIntervalSince(tAdopt)))s (refreshViews=\(refreshViews))")
            }
        }
    }

    private static func buildModel(lLines: [String], rLines: [String],
                                   aligned: [StructuralDiff.Segment]?,
                                   leftName: String, rightName: String,
                                   colors: RunColors) -> AlignedModel {
        var m = AlignedModel()
        m.leftLineStarts = lineStarts(of: lLines)
        m.rightLineStarts = lineStarts(of: rLines)
        // One code path: the line engine's implicit equal runs are made
        // explicit so both engines hand over the same shape.
        let segments = aligned ?? StructuralDiff.segments(
            fromLineHunks: DiffEngine.diff(left: lLines, right: rLines),
            leftCount: lLines.count, rightCount: rLines.count)
        m.hunks = segments.filter(\.isHunk).map {
            DiffEngine.Hunk(leftStart: $0.leftStart, leftCount: $0.leftCount,
                            rightStart: $0.rightStart, rightCount: $0.rightCount)
        }
        m.lOut.reserveCapacity((m.leftLineStarts.last ?? 0) + 64)
        m.rOut.reserveCapacity((m.rightLineStarts.last ?? 0) + 64)

        var li = 0, ri = 0
        var lOff = 0, rOff = 0   // UTF-16 offsets into the aligned texts

        // Side-specific appenders that also build the aligned-row maps
        // the tree sidebar jumps through.
        func appendL(_ from: Int, _ count: Int) {
            for k in from..<(from + count) {
                m.rowForLeftLine.append(m.rowStartsL.count)
                m.rowStartsL.append(lOff)
                m.lOut += lLines[k]; m.lOut += "\n"
                lOff += (lLines[k] as NSString).length + 1
            }
        }
        // A filler row is blank. A note naming the missing lines was
        // tried twice and read as part of the file both times; the status
        // line already says how many lines a difference holds and which
        // file they are in.
        func fillL(_ count: Int, _ caption: String? = nil) {
            for k in 0..<count {
                m.rowStartsL.append(lOff)
                let text = (k == 0 ? (caption ?? "") : "")
                if !text.isEmpty {
                    m.captionsL.append(NSRange(location: lOff, length: (text as NSString).length))
                }
                m.lOut += text; m.lOut += "\n"
                lOff += (text as NSString).length + 1
            }
        }
        func appendR(_ from: Int, _ count: Int) {
            for k in from..<(from + count) {
                m.rowForRightLine.append(m.rowStartsR.count)
                m.rowStartsR.append(rOff)
                m.rOut += rLines[k]; m.rOut += "\n"
                rOff += (rLines[k] as NSString).length + 1
            }
        }
        func fillR(_ count: Int, _ caption: String? = nil) {
            for k in 0..<count {
                m.rowStartsR.append(rOff)
                let text = (k == 0 ? (caption ?? "") : "")
                if !text.isEmpty {
                    m.captionsR.append(NSRange(location: rOff, length: (text as NSString).length))
                }
                m.rOut += text; m.rOut += "\n"
                rOff += (text as NSString).length + 1
            }
        }

        for seg in segments {
            guard seg.isHunk else {
                // An equal run. Its two starts are explicit because
                // pairing by identity can visit the right file out of
                // order.
                appendL(seg.leftStart, seg.leftCount)
                appendR(seg.rightStart, seg.rightCount)
                li = seg.leftStart + seg.leftCount
                ri = seg.rightStart + seg.rightCount
                continue
            }
            let h = DiffEngine.Hunk(leftStart: seg.leftStart, leftCount: seg.leftCount,
                                    rightStart: seg.rightStart, rightCount: seg.rightCount)
            li = h.leftStart; ri = h.rightStart

            m.hunkViewOffsetsL.append(lOff)
            m.hunkViewOffsetsR.append(rOff)
            m.hunkRowStart.append(m.rowStartsL.count)
            let lStartOff = lOff, rStartOff = rOff

            let paired = min(h.leftCount, h.rightCount)
            // Paired rows = changed (amber both sides).
            appendL(li, paired)
            appendR(ri, paired)
            if paired > 0 {
                m.lRuns.append((NSRange(location: lStartOff, length: lOff - lStartOff), colors.changed))
                m.rRuns.append((NSRange(location: rStartOff, length: rOff - rStartOff), colors.changed))
            }
            // Remainder = one-sided + filler on the other.
            let lExtra = h.leftCount - paired
            let rExtra = h.rightCount - paired
            if lExtra > 0 {
                let s = lOff, sr = rOff
                appendL(li + paired, lExtra)
                fillR(lExtra)
                m.lRuns.append((NSRange(location: s, length: lOff - s), colors.removed))
                let fr = NSRange(location: sr, length: rOff - sr)
                m.rRuns.append((fr, colors.filler))
                m.fillerR.append(fr)
            }
            if rExtra > 0 {
                let s = rOff, sl = lOff
                appendR(ri + paired, rExtra)
                fillL(rExtra)
                m.rRuns.append((NSRange(location: s, length: rOff - s), colors.added))
                let fl = NSRange(location: sl, length: lOff - sl)
                m.lRuns.append((fl, colors.filler))
                m.fillerL.append(fl)
            }
            li += h.leftCount
            ri += h.rightCount
            m.hunkViewRangesL.append(NSRange(location: lStartOff, length: lOff - lStartOff))
            m.hunkViewRangesR.append(NSRange(location: rStartOff, length: rOff - rStartOff))
            m.hunkRowSpan.append(m.rowStartsL.count - (m.hunkRowStart.last ?? 0))
        }
        // Every line is inside a segment now, so there is no tail to add.
        return m
    }

    private func adopt(_ m: AlignedModel, refreshViews: Bool, scrollToFirst: Bool) {
        hunks = m.hunks
        leftLineStarts = m.leftLineStarts
        rightLineStarts = m.rightLineStarts
        hunkViewOffsetsL = m.hunkViewOffsetsL; hunkViewOffsetsR = m.hunkViewOffsetsR
        hunkViewRangesL = m.hunkViewRangesL; hunkViewRangesR = m.hunkViewRangesR
        rowStartsL = m.rowStartsL; rowStartsR = m.rowStartsR
        rowForLeftLine = m.rowForLeftLine
        rowForRightLine = m.rowForRightLine
        hunkRowStart = m.hunkRowStart; hunkRowSpan = m.hunkRowSpan

        // An in-place patch must leave the views byte-identical to a
        // full rebuild; if they ever drift, rebuild rather than trust.
        let inSync = leftView.textStorage?.length == m.lOut.utf16.count
            && rightView.textStorage?.length == m.rOut.utf16.count
        if refreshViews || !inSync {
            Diag.time("diff adopt: apply both views (inSync=\(inSync))") {
                apply(text: m.lOut, runs: m.lRuns, captions: m.captionsL, to: leftView)
                apply(text: m.rOut, runs: m.rRuns, captions: m.captionsR, to: rightView)
            }
        }

        rebuildScopedIndices()
        let keptRow = (keepRow >= 0 && keepRow < rowStartsL.count) ? keepRow : -1
        if scrollToFirst {
            scopedPos = 0
            pastEnd = false
        } else if keepRow >= 0, !hunks.isEmpty {
            // The first difference at or below the row that follows what
            // the copy just put in, never one above it.
            let first = keptRow < 0 ? hunks.count : firstHunkEndingAfterRow(keptRow)
            var pos = 0
            while pos < scopedIndices.count, scopedIndices[pos] < first { pos += 1 }
            pastEnd = pos >= scopedIndices.count
            scopedPos = min(pos, max(0, scopedIndices.count - 1))
        }
        if scopedPos >= scopedIndices.count { scopedPos = max(0, scopedIndices.count - 1) }

        if scopedIndices.isEmpty {
            pastEnd = false
            updateStatus()
        } else if pastEnd {
            // Stay exactly where the user was; nothing is current until
            // Next or Previous is pressed.
            clearEmphasis()
            if keepOffset >= 0 { scrollBothTo(keepOffset) }
            updateCopyButtons()
            updateStatus()
        } else {
            focusCurrentHunk(keepOffset >= 0 ? keepOffset : nil)
        }
        // In line mode land on the row right after the copied line while
        // it is still inside the current difference; otherwise on the
        // difference's first row. Never when nothing is current.
        if !scopedIndices.isEmpty, lineMode, !anchorPending, !pastEnd,
           scopedPos < scopedIndices.count {
            let idx = scopedIndices[scopedPos]
            if idx < hunkRowStart.count {
                var row = hunkRowStart[idx]
                if keptRow >= row, keptRow < row + hunkRowSpan[idx] { row = keptRow }
                selectRow(row, idx)
            }
        }
        keepRow = -1
        keepOffset = -1
    }

    private static func lineStarts(of lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count + 1)
        var off = 0
        for l in lines { starts.append(off); off += (l as NSString).length + 1 }
        starts.append(off)
        return starts
    }

    private func apply(text: String, runs: [(NSRange, NSColor)],
                       captions: [NSRange] = [], to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        // Every row is pinned to the monospace line height. The two sides
        // are mirrored row for row, so a single row that came out a
        // fraction taller than its partner would put everything below it
        // out of step. Pinning it makes that impossible whatever face a
        // run uses.
        let mono = XMFont.mono(11, .regular)
        let rowHeight = NSLayoutManager().defaultLineHeight(for: mono)
        let rows = NSMutableParagraphStyle()
        rows.minimumLineHeight = rowHeight
        rows.maximumLineHeight = rowHeight
        rows.lineBreakMode = .byClipping
        let full = NSMutableAttributedString(string: text, attributes: [
            .font: mono,
            .foregroundColor: XMColor.text,
            .paragraphStyle: rows,
        ])
        for (range, color) in runs where NSMaxRange(range) <= full.length {
            full.addAttribute(.backgroundColor, value: color, range: range)
        }
        // The note at the head of a filler run is about the file, not from
        // inside it: dim, italic, and in the interface face rather than
        // the editor's monospace, so it cannot be read as a line of XML.
        let noteFont = NSFontManager.shared.convert(XMFont.ui(11, .regular),
                                                    toHaveTrait: .italicFontMask)
        for range in captions where NSMaxRange(range) <= full.length {
            full.addAttributes([.foregroundColor: XMColor.text3, .font: noteFont], range: range)
        }
        storage.setAttributedString(full)
    }

    // MARK: Navigation

    /// Drop the current-difference band without moving anything.
    private func clearEmphasis() {
        setEmphasis(row: -1, span: 0)
        clearRowSelection()
    }

    private func scrollBothTo(_ y: CGFloat) {
        syncing = true
        for sc in [leftScroll, rightScroll] {
            sc.contentView.setBoundsOrigin(NSPoint(x: sc.contentView.bounds.origin.x, y: y))
            sc.reflectScrolledClipView(sc.contentView)
        }
        syncing = false
    }

    /// `keepOffset`: stay where the user was, unless that would leave the
    /// difference off screen.
    private func focusCurrentHunk(_ keepOffset: CGFloat? = nil) {
        let tF = Date()
        defer { Diag.log("diff focus: \(String(format: "%.3f", Date().timeIntervalSince(tF)))s") }
        guard !scopedIndices.isEmpty, scopedPos < scopedIndices.count else { updateStatus(); return }
        anchorPending = false
        pastEnd = false
        updateCopyButtons()
        updateStatus()
        let idx = scopedIndices[scopedPos]
        let lr = hunkViewRangesL[idx]
        let rr = hunkViewRangesR[idx]
        syncing = true
        leftView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: lr.location, length: min(1, lr.length)))
        rightView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: rr.location, length: min(1, rr.length)))
        if let keepOffset {
            leftScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: keepOffset))
            leftScroll.reflectScrolledClipView(leftScroll.contentView)
        }
        leftView.scrollRangeToVisible(lr)
        rightView.scrollRangeToVisible(rr)
        // A band, not the text selection: the selection belongs to the
        // user, who uses it to pick rows inside a difference.
        if idx < hunkRowStart.count, idx < hunkRowSpan.count {
            setEmphasis(row: hunkRowStart[idx], span: hunkRowSpan[idx])
        }
        leftView.setSelectedRange(NSRange(location: 0, length: 0))
        rightView.setSelectedRange(NSRange(location: 0, length: 0))
        syncing = false
    }

    // MARK: line-by-line mode

    static let lineModeKey = "xml-macker.diffLineMode"
    private var lineMode = UserDefaults.standard.bool(forKey: DiffWindowController.lineModeKey)

    @objc private func toggleLineMode(_ sender: NSButton) {
        lineMode = sender.state == .on
        UserDefaults.standard.set(lineMode, forKey: Self.lineModeKey)
        if lineMode, !scopedIndices.isEmpty, !anchorPending {
            let idx = scopedIndices[scopedPos]
            if idx < hunkRowStart.count { selectRow(hunkRowStart[idx], idx) }
        } else {
            updateCopyButtons()
            updateStatus()
        }
    }

    /// Moves the one-row selection by `delta`. Leaving a difference at
    /// either end steps into the next or previous one, wrapping.
    private func stepLine(_ delta: Int) {
        let count = scopedIndices.count
        guard count > 0 else { return }
        var idx = scopedIndices[scopedPos]
        guard idx < hunkRowStart.count else { return }
        let start = hunkRowStart[idx], span = hunkRowSpan[idx]
        let sel = selectedRows()
        let inside = sel.map { $0.start >= start && $0.start < start + span } ?? false

        var row: Int
        if anchorPending || !inside {
            anchorPending = false
            row = delta > 0 ? start : start + span - 1
        } else {
            row = (sel?.start ?? start) + delta
            if row >= start + span {
                scopedPos = (scopedPos + 1) % count
                idx = scopedIndices[scopedPos]
                row = hunkRowStart[idx]
            } else if row < start {
                scopedPos = (scopedPos - 1 + count) % count
                idx = scopedIndices[scopedPos]
                row = hunkRowStart[idx] + hunkRowSpan[idx] - 1
            }
        }
        selectRow(row, idx)
    }

    /// Selects exactly one row on both sides and scrolls to it.
    private func selectRow(_ row: Int, _ idx: Int) {
        guard idx < hunkRowStart.count else { return }
        syncing = true
        let lr = rowsRange(rowStartsL, leftView, row, 1)
        let rr = rowsRange(rowStartsR, rightView, row, 1)
        leftView.setSelectedRange(lr)
        rightView.setSelectedRange(rr)
        setEmphasis(row: hunkRowStart[idx], span: hunkRowSpan[idx])
        leftView.scrollRangeToVisible(lr)
        rightView.scrollRangeToVisible(rr)
        syncing = false
        pastEnd = false
        updateCopyButtons()
        updateStatus()
    }

    /// "Line 3 of 108 in ", only in line mode with one row selected
    /// inside the current difference.
    private var linePrefix: String {
        guard lineMode, let sel = selectionInCurrentHunk(),
              scopedPos < scopedIndices.count else { return "" }
        let idx = scopedIndices[scopedPos]
        guard idx < hunkRowSpan.count else { return "" }
        return "Line \(Self.grouped(sel.start - hunkRowStart[idx] + 1)) of \(Self.grouped(hunkRowSpan[idx])) in "
    }

    private var selectionNote: String {
        guard let sel = selectionInCurrentHunk(), !(lineMode && sel.count == 1) else { return "" }
        return " · \(sel.count) selected"
    }

    @objc private func nextHunk() {
        brokeWarning = ""
        guard !scopedIndices.isEmpty else { NSSound.beep(); updateStatus(); return }
        if pastEnd { pastEnd = false; scopedPos = 0; focusCurrentHunk(); return }
        if lineMode { stepLine(1); return }
        if anchorPending {
            // First press after selecting an element lands ON the
            // first difference inside it instead of stepping past.
            focusCurrentHunk()
            return
        }
        scopedPos = (scopedPos + 1) % scopedIndices.count
        focusCurrentHunk()
    }

    @objc private func prevHunk() {
        brokeWarning = ""
        guard !scopedIndices.isEmpty else { NSSound.beep(); updateStatus(); return }
        if pastEnd { pastEnd = false; scopedPos = scopedIndices.count - 1; focusCurrentHunk(); return }
        if lineMode { stepLine(-1); return }
        if anchorPending {
            scopedPos = scopedIndices.count - 1
            focusCurrentHunk()
            return
        }
        scopedPos = (scopedPos - 1 + scopedIndices.count) % scopedIndices.count
        focusCurrentHunk()
    }

    // MARK: Copy hunks

    @objc private func copyLeftToRight() { copyHunk(from: .left) }
    @objc private func copyRightToLeft() { copyHunk(from: .right) }

    // MARK: rows and selection
    //
    // The aligned views share one row grid, so a row index means the same
    // thing on both sides. The current difference is drawn as a temporary
    // background band rather than as the text selection, which leaves the
    // selection free for the user to pick rows inside a difference and
    // copy only those.

    private var emphasisL = NSRange(location: 0, length: 0)
    private var emphasisR = NSRange(location: 0, length: 0)

    private func rowIndex(_ starts: [Int], _ offset: Int) -> Int {
        guard !starts.isEmpty else { return -1 }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The character range covering `count` rows starting at `row`.
    private func rowsRange(_ starts: [Int], _ view: NSTextView, _ row: Int, _ count: Int) -> NSRange {
        guard row >= 0, count > 0, row < starts.count else { return NSRange(location: 0, length: 0) }
        let from = starts[row]
        let end = row + count < starts.count
            ? starts[row + count]
            : (view.textStorage?.length ?? from)
        return NSRange(location: from, length: max(0, end - from))
    }

    private func setEmphasis(row: Int, span: Int) {
        for (v, r) in [(leftView, emphasisL), (rightView, emphasisR)] where r.length > 0 {
            v.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        emphasisL = NSRange(location: 0, length: 0)
        emphasisR = NSRange(location: 0, length: 0)
        guard row >= 0, span > 0 else { return }
        let lr = rowsRange(rowStartsL, leftView, row, span)
        let rr = rowsRange(rowStartsR, rightView, row, span)
        let band = XMColor.accent.withAlphaComponent(0.20)
        if lr.length > 0 { leftView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: band, forCharacterRange: lr) }
        if rr.length > 0 { rightView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: band, forCharacterRange: rr) }
        emphasisL = lr; emphasisR = rr
    }

    /// The rows the user has selected, snapped to whole rows.
    private func selectedRows() -> (start: Int, count: Int)? {
        let r = leftView.selectedRange()
        guard r.length > 0, !rowStartsL.isEmpty else { return nil }
        let first = rowIndex(rowStartsL, r.location)
        let last = rowIndex(rowStartsL, max(r.location, NSMaxRange(r) - 1))
        guard first >= 0, last >= first else { return nil }
        return (first, last - first + 1)
    }

    /// The selected rows when they lie inside the CURRENT difference.
    private func selectionInCurrentHunk() -> (start: Int, count: Int)? {
        guard !scopedIndices.isEmpty, scopedPos >= 0, scopedPos < scopedIndices.count,
              let sel = selectedRows() else { return nil }
        let idx = scopedIndices[scopedPos]
        guard idx < hunkRowStart.count, idx < hunkRowSpan.count else { return nil }
        let base = hunkRowStart[idx]
        guard sel.start >= base, sel.start + sel.count <= base + hunkRowSpan[idx] else { return nil }
        return sel
    }

    /// Index of the difference whose rows contain `row`, or nil.
    private func hunkAtRow(_ row: Int) -> Int? {
        var lo = 0, hi = hunkRowStart.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if row < hunkRowStart[mid] { hi = mid - 1 }
            else if row >= hunkRowStart[mid] + hunkRowSpan[mid] { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Snap what the user dragged to whole rows, mirror it to the other
    /// side (the rows are shared, so the mirror is exact), and make the
    /// difference they landed in the current one.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !syncing, let from = notification.object as? NSTextView,
              from === leftView || from === rightView else { return }
        let fromStarts = from === leftView ? rowStartsL : rowStartsR
        let r = from.selectedRange()
        guard r.length > 0, !fromStarts.isEmpty else {
            if r.length == 0 { updateCopyButtons(); updateStatus() }
            return
        }
        let first = rowIndex(fromStarts, r.location)
        let last = rowIndex(fromStarts, max(r.location, NSMaxRange(r) - 1))
        guard first >= 0, last >= first else { return }
        let count = last - first + 1

        syncing = true
        leftView.setSelectedRange(rowsRange(rowStartsL, leftView, first, count))
        rightView.setSelectedRange(rowsRange(rowStartsR, rightView, first, count))
        syncing = false

        if pastEnd {
            pastEnd = false
            copyLeftButton?.isEnabled = !scopedIndices.isEmpty
            copyRightButton?.isEnabled = !scopedIndices.isEmpty
        }
        // Selecting rows inside another difference makes THAT one current.
        if let idx = hunkAtRow(first), let pos = scopedIndices.firstIndex(of: idx) {
            scopedPos = pos
            anchorPending = false
            setEmphasis(row: hunkRowStart[idx], span: hunkRowSpan[idx])
        }
        updateCopyButtons()
        updateStatus()
    }

    private func clearRowSelection() {
        syncing = true
        leftView.setSelectedRange(NSRange(location: 0, length: 0))
        rightView.setSelectedRange(NSRange(location: 0, length: 0))
        syncing = false
        updateCopyButtons()
        updateStatus()
    }

    /// What a copy moves: the whole difference, or only the selected rows.
    ///
    /// Rows inside a difference are laid out as the paired rows (a line on
    /// each side), then the left-only rows (filler on the right), then the
    /// right-only rows (filler on the left). A side with no selected
    /// content becomes an insertion point, so copying left-only rows to
    /// the right inserts them, and copying from the left onto right-only
    /// rows removes them.
    private func copyRange(_ h: DiffEngine.Hunk, hunkIndex: Int, from source: DiffSide)
        -> (srcStart: Int, srcCount: Int, dstStart: Int, dstCount: Int) {
        let paired = min(h.leftCount, h.rightCount)
        let leftExtra = h.leftCount - paired
        var lStart = h.leftStart, lCount = h.leftCount
        var rStart = h.rightStart, rCount = h.rightCount

        if let sel = selectionInCurrentHunk(), hunkIndex < hunkRowStart.count {
            let a = sel.start - hunkRowStart[hunkIndex]
            let b = a + sel.count - 1
            if a >= 0, b >= a {
                var lFirst = -1, lLast = -1, rFirst = -1, rLast = -1
                for r in a...b {
                    if let lLine = Self.sourceLineAtRow(h, r, .left) {
                        if lFirst < 0 { lFirst = lLine }; lLast = lLine
                    }
                    if let rLine = Self.sourceLineAtRow(h, r, .right) {
                        if rFirst < 0 { rFirst = rLine }; rLast = rLine
                    }
                }
                _ = leftExtra
                lStart = lFirst >= 0 ? lFirst : h.leftStart + h.leftCount
                lCount = lFirst >= 0 ? lLast - lFirst + 1 : 0
                rStart = rFirst >= 0 ? rFirst : h.rightStart + paired
                rCount = rFirst >= 0 ? rLast - rFirst + 1 : 0
            }
        }
        return source == .left ? (lStart, lCount, rStart, rCount) : (rStart, rCount, lStart, lCount)
    }

    /// The Copy buttons say what they will move once rows are selected.
    private func updateCopyButtons() {
        let suffix = selectionInCurrentHunk().map { " (\($0.count) line\($0.count == 1 ? "" : "s"))" } ?? ""
        copyLeftButton?.title = "Copy From Left ▶" + suffix
        copyRightButton?.title = "◀ Copy From Right" + suffix
        undoCopyButton?.isEnabled = !copyUndo.isEmpty && !isComparing
        if pastEnd {
            copyLeftButton?.isEnabled = false
            copyRightButton?.isEnabled = false
        }
    }

    /// True when a fragment opens and closes its own elements.
    ///
    /// Every opening tag must meet its own closing tag inside the
    /// fragment, and no closing tag may stand alone: that is what keeps a
    /// copy from breaking the other file. Self-closing tags, comments,
    /// CDATA and declarations are skipped, and text between tags does not
    /// matter. This replaced a call to the linter, which accepted a stray
    /// closing tag, and a stray closing tag is exactly the shape that
    /// broke a real file.
    static func isBalancedFragment(_ fragment: String) -> Bool {
        if fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let ns = fragment as NSString
        let n = ns.length
        guard ns.range(of: "<").location != NSNotFound else { return true }
        var open: [String] = []
        var i = 0
        while i < n {
            let ltRange = ns.range(of: "<", options: [], range: NSRange(location: i, length: n - i))
            if ltRange.location == NSNotFound { break }
            let lt = ltRange.location
            func matches(_ s: String) -> Bool {
                lt + (s as NSString).length <= n
                    && ns.substring(with: NSRange(location: lt, length: (s as NSString).length)) == s
            }
            func skipPast(_ terminator: String, from: Int) -> Int? {
                let r = ns.range(of: terminator, options: [], range: NSRange(location: from, length: n - from))
                return r.location == NSNotFound ? nil : r.location + r.length
            }
            if matches("<!--") {
                guard let e = skipPast("-->", from: lt + 4) else { return true }
                i = e; continue
            }
            if matches("<![CDATA[") {
                guard let e = skipPast("]]>", from: lt + 9) else { return true }
                i = e; continue
            }
            if lt + 1 < n {
                let c = ns.character(at: lt + 1)
                if c == 0x3F || c == 0x21 {                 // <? or <!
                    guard let e = skipPast(">", from: lt) else { return true }
                    i = e; continue
                }
            }
            // Walk to the tag's '>' , ignoring one inside a quoted value.
            var j = lt + 1
            var quote: unichar = 0
            while j < n {
                let ch = ns.character(at: j)
                if quote != 0 { if ch == quote { quote = 0 } }
                else if ch == 0x22 || ch == 0x27 { quote = ch }
                else if ch == 0x3E { break }
                j += 1
            }
            if j >= n { return true }   // an unfinished tag is the parser's business
            let closing = lt + 1 < n && ns.character(at: lt + 1) == 0x2F
            let selfClosing = !closing && j - 1 > lt && ns.character(at: j - 1) == 0x2F
            let nameStart = lt + (closing ? 2 : 1)
            var k = nameStart
            while k < j {
                let ch = ns.character(at: k)
                if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x2F || ch == 0x3E { break }
                k += 1
            }
            let name = ns.substring(with: NSRange(location: nameStart, length: max(0, k - nameStart)))
            if closing {
                if open.isEmpty || open.removeLast() != name { return false }
            } else if !selfClosing {
                open.append(name)
            }
            i = j + 1
        }
        return open.isEmpty
    }

    /// The line of `side` shown at row `k` of a difference (0-based within
    /// it), or nil for a filler row.
    private static func sourceLineAtRow(_ h: DiffEngine.Hunk, _ k: Int, _ side: DiffSide) -> Int? {
        let paired = min(h.leftCount, h.rightCount)
        let leftExtra = h.leftCount - paired
        if side == .left { return k < paired + leftExtra ? h.leftStart + k : nil }
        if k < paired { return h.rightStart + k }
        return k >= paired + leftExtra ? h.rightStart + paired + (k - paired - leftExtra) : nil
    }

    /// How far the widening may reach inside one difference.
    private static let widenCap = 4000

    /// Widens the row selection inside the current difference until the
    /// lines it covers form complete XML on BOTH sides, the lines copied
    /// and the lines replaced: forward first, then backward when the
    /// selection began with a closing tag.
    ///
    /// This is why "copy this one line" no longer breaks the other file.
    /// Picking the middle line of an element and moving it alone leaves a
    /// tag without its partner; the selection now takes the whole element
    /// instead. Returns the rows added, 0 when the selection was already
    /// complete or there is none, and -1 when nothing inside the
    /// difference would make it complete.
    @discardableResult
    private func widenSelectionToWholeElement(_ hunkIndex: Int, from source: DiffSide) -> Int {
        guard let sel = selectionInCurrentHunk(), hunkIndex < hunkRowStart.count else { return 0 }
        let h = hunks[hunkIndex]
        let rowBase = hunkRowStart[hunkIndex]
        let last = rowBase + hunkRowSpan[hunkIndex] - 1
        let target: DiffSide = source == .left ? .right : .left

        func fragment(_ a: Int, _ b: Int, _ side: DiffSide) -> String {
            let lines = side == .left ? leftLines : rightLines
            var out = ""
            for r in a...b {
                if let line = Self.sourceLineAtRow(h, r - rowBase, side), line >= 0, line < lines.count {
                    out += lines[line]
                    out += "\n"
                }
            }
            return out
        }
        func complete(_ a: Int, _ b: Int) -> Bool {
            a <= b
                && Self.isBalancedFragment(fragment(a, b, source))
                && Self.isBalancedFragment(fragment(a, b, target))
        }

        let a = sel.start, b = sel.start + sel.count - 1
        if complete(a, b) { return 0 }
        var a2 = a, b2 = b, tried = 0
        while b2 < last, tried < Self.widenCap, !complete(a2, b2) { b2 += 1; tried += 1 }
        while a2 > rowBase, tried < Self.widenCap, !complete(a2, b2) { a2 -= 1; tried += 1 }
        if !complete(a2, b2) { return -1 }
        // The smallest complete stretch, not the whole block.
        for e in b...b2 where complete(a2, e) { b2 = e; break }

        syncing = true
        leftView.setSelectedRange(rowsRange(rowStartsL, leftView, a2, b2 - a2 + 1))
        rightView.setSelectedRange(rowsRange(rowStartsR, rightView, a2, b2 - a2 + 1))
        syncing = false
        return (b2 - a2 + 1) - sel.count
    }

    @objc private func undoLastCopy() {
        brokeWarning = ""
        guard !copyUndo.isEmpty, !isComparing else { NSSound.beep(); return }
        let entry = copyUndo.removeLast()
        undoCopyButton?.isEnabled = !copyUndo.isEmpty
        let range = NSRange(location: entry.start, length: entry.insertedLength)
        guard applyEdit?(entry.target, range, entry.removed) == true else {
            NSSound.beep()
            statusField.stringValue = "Couldn't undo the copy"
            return
        }
        let ns = (entry.target == .right ? rightText : leftText) as NSString
        let safeLen = min(entry.insertedLength, max(0, ns.length - entry.start))
        let restored = ns.replacingCharacters(in: NSRange(location: min(entry.start, ns.length), length: safeLen),
                                              with: entry.removed)
        if entry.target == .right { rightText = restored } else { leftText = restored }
        // The restored difference comes back at the row the copy was made on.
        rememberPlace(entry.row)
        lastCopyNote = "Undid the last copy in \(entry.target == .left ? leftName : rightName), "
        recompareAsync(scrollToFirst: false, reuseLines: false, refreshViews: true)
    }

    private func copyHunk(from source: DiffSide) {
        guard !isComparing else { NSSound.beep(); return }
        guard !scopedIndices.isEmpty, scopedPos < scopedIndices.count else { NSSound.beep(); return }
        let idx = scopedIndices[scopedPos]
        let h = hunks[idx]
        var range4 = copyRange(h, hunkIndex: idx, from: source)
        var anchorRow = selectionInCurrentHunk()?.start ?? (idx < hunkRowStart.count ? hunkRowStart[idx] : 0)

        // Line by line must still move whole elements. A selected line
        // that only opens an element, or only closes one, takes its
        // element along, on both sides, before anything is written.
        let widened = widenSelectionToWholeElement(idx, from: source)
        if widened > 0 {
            range4 = copyRange(h, hunkIndex: idx, from: source)
            if let wide = selectionInCurrentHunk() { anchorRow = wide.start }
        }

        let srcLines = source == .left ? leftLines : rightLines
        let srcStart = range4.srcStart
        let srcCount = range4.srcCount
        guard srcStart >= 0, srcStart + srcCount <= srcLines.count else { NSSound.beep(); return }
        var replacement = srcCount == 0 ? "" :
            srcLines[srcStart..<(srcStart + srcCount)].joined(separator: "\n") + "\n"

        let dstStarts = source == .left ? rightLineStarts : leftLineStarts
        let dstStart = range4.dstStart
        let dstCount = range4.dstCount
        // lineStarts has lines+1 entries (final = text length), so the
        // hunk's end offset is always indexable when the model is sane.
        guard dstStart >= 0, dstStart + dstCount <= dstStarts.count - 1 else { NSSound.beep(); return }
        let lo = dstStarts[dstStart]
        let hi = dstStarts[dstStart + dstCount]
        let range = NSRange(location: lo, length: hi - lo)

        let target: DiffSide = source == .left ? .right : .left
        // A file whose last line has no line break must not gain one from
        // a copy that lands at its end, and must not lose one either.
        let targetText = target == .right ? rightText : leftText
        if range.location + range.length >= (targetText as NSString).length,
           !targetText.hasSuffix("\n"), replacement.hasSuffix("\n") {
            replacement.removeLast()
        }

        // Refuse to break the file quietly. A copy that moves an opening
        // tag without its closing tag (or the reverse) leaves the target
        // malformed: the tree then stops there and the comparison drops to
        // line by line. Check the fragment going in AND the one it
        // replaces.
        let targetNS = (target == .right ? rightText : leftText) as NSString
        let removedRange = NSRange(location: min(range.location, targetNS.length),
                                   length: min(range.length, max(0, targetNS.length - range.location)))
        let removedText = targetNS.substring(with: removedRange)
        if !copyForced,
           !Self.isBalancedFragment(replacement) || !Self.isBalancedFragment(removedText) {
            let rows = idx < hunkRowSpan.count ? hunkRowSpan[idx] : 0
            let a = NSAlert()
            a.messageText = "This copy would break the XML"
            a.informativeText = "It would move an opening tag without its closing tag, or the other way round, and leave \(target == .left ? leftName : rightName) malformed.\n\nCopying the whole difference moves complete elements instead. Nothing is written to the file on disk until you save, and Undo Copy puts it back either way."
            a.addButton(withTitle: "Copy the Whole Difference (\(rows) lines)")
            a.addButton(withTitle: "Copy These Lines Anyway")
            a.addButton(withTitle: "Cancel")
            let answer = a.runModal()
            if answer == .alertThirdButtonReturn { return }
            if answer == .alertFirstButtonReturn {
                clearRowSelection()
                copyForced = true              // the whole block is complete elements
                defer { copyForced = false }
                copyHunk(from: source)
                return
            }
        }

        let t0 = Date()
        Diag.log("diff copy: start (hunk \(idx), \(srcCount) lines)")
        guard applyEdit?(target, range, replacement) == true else {
            NSSound.beep()
            statusField.stringValue = "Couldn't apply the change"
            return
        }
        // Mirror the edit into our copy of the target text AND its line
        // cache, so the re-diff skips the 39 MB split.
        let ns = (target == .right ? rightText : leftText) as NSString
        let updated = ns.replacingCharacters(in: range, with: replacement)
        let newLines = Array(srcLines[srcStart..<(srcStart + srcCount)])
        if target == .right {
            rightText = updated
            rightLines.replaceSubrange(dstStart..<(dstStart + dstCount), with: newLines)
        } else {
            leftText = updated
            leftLines.replaceSubrange(dstStart..<(dstStart + dstCount), with: newLines)
        }
        // Patch BOTH aligned views in place: this hunk's rows (real +
        // filler) on each side become the copied lines, uncoloured.
        // Instant, versus rebuilding two 39 MB text views.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: XMFont.mono(11, .regular), .foregroundColor: XMColor.text]
        let rows = NSAttributedString(string: replacement, attributes: attrs)
        Diag.log("diff copy: applyEdit done \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
        if idx < hunkViewRangesL.count, idx < hunkViewRangesR.count {
            leftView.textStorage?.replaceCharacters(in: hunkViewRangesL[idx], with: rows)
            rightView.textStorage?.replaceCharacters(in: hunkViewRangesR[idx], with: rows)
        }
        Diag.log("diff copy: views patched \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
        let targetName = target == .left ? leftName : rightName
        let whole = widened > 0 ? " (the whole element: one line alone would break the XML)" : ""
        lastCopyNote = srcCount > 0
            ? "Copied \(Self.grouped(srcCount)) line\(srcCount == 1 ? "" : "s") into \(targetName)\(whole), "
            : "Removed \(Self.grouped(dstCount)) line\(dstCount == 1 ? "" : "s") from \(targetName)\(whole), "
        copyUndo.append((target, range.location, (replacement as NSString).length, removedText, anchorRow))
        undoCopyButton?.isEnabled = true
        noteBeforeCopy = compareMode
        // Continue from the row right after the copied lines, or from the
        // row now standing where lines were removed.
        rememberPlace(anchorRow + srcCount)
        // A scope is a stretch of lines in one file; lines put in or taken
        // out above it move it down or up by the same amount.
        shiftScope(target: target, editLine: dstStart, delta: srcCount - dstCount)
        // A partial copy changes the line count, so the cached line arrays
        // and the in-place view patch can no longer be trusted.
        let partial = srcCount != (source == .left ? h.leftCount : h.rightCount)
        recompareAsync(scrollToFirst: false, reuseLines: !partial, refreshViews: partial)
        Diag.log("diff copy: handler returned \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
    }
}
