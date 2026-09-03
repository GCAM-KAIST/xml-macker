import Cocoa
import UniformTypeIdentifiers

// Standalone chart window, opened by the ↗ button on the inline
// chart in the inspector. Aurora-themed: translucent hudWindow
// background via NSVisualEffectView, glass toolbar at top with
// pill-shaped toggles (Aurora palette), the chart body, and an
// optional data table below.
//
// Dynamic sizing: toggling the data table GROWS the window so the
// chart stays the same height. Turning labels on doesn't resize.
// The window has to be dynamic here: at a fixed height the table was
// clipped below the window's lower edge.
final class ChartPopoutWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?
    private static let frameAutosaveName = "xml-mackerChart"

    private let chart = TrendView(frame: .zero)
    private let chartScroll = NSScrollView()
    private var chartWidthCon: NSLayoutConstraint?
    // Minimum width per bar before the chart starts scrolling sideways.
    private let minBarSlot: CGFloat = 46
    private let tableScroll = NSScrollView()
    private let dataTable = NSTableView()
    private var tableVisible: Bool = false
    private var currentSeries: TrendSeries?

    // Height constraint on the table area, zero when hidden.
    private var tableHeightCon: NSLayoutConstraint?
    private let tableHeight: CGFloat = 240
    // Chrome tall enough for the toolbar + vertical padding.
    private let toolbarH: CGFloat = 52
    private let chartMinH: CGFloat = 360

    private var labelsToggle: GlassPillButton!
    private var tableToggle: GlassPillButton!
    private var saveButton: GlassPillButton!
    private var copyButton: GlassPillButton!
    private var csvButton: GlassPillButton!

    // Chart Builder (v1.0.3), see ChartQuery.swift.
    private var buildToggle: GlassPillButton!
    private let builderBar = NSView()
    private let pathScroll = NSScrollView()
    private let pathStack = NSStackView()
    private let valueRow = NSStackView()
    private var builderHeightCon: NSLayoutConstraint?
    private let valuePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var levelPopups: [NSPopUpButton] = []
    private var followToggle: GlassPillButton!
    private var revealButton: GlassPillButton!
    private let builderNote = NSTextField(labelWithString: "")
    private var builderVisible = false
    private var followTree = true
    private var builder: ChartPathBuilder?
    private var builderRootID: ObjectIdentifier?
    private weak var contextNode: XMLTreeNode?
    private weak var documentRoot: XMLTreeNode?
    private var mirroredSeries: TrendSeries?
    private var mirroredPath = ""
    /// "Show in Tree": MainWindowController selects the node.
    var onRevealNode: ((XMLTreeNode) -> Void)?

    init() {
        // Start with the table hidden, chart-only height.
        let startFrame = NSRect(x: 0, y: 0, width: 1100, height: 100 + 360 + 20)
        // No miniaturize: as a child of the main window a minimized
        // pop-out can come back ordered behind everything.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        let win = NSWindow(contentRect: startFrame, styleMask: styleMask,
                           backing: .buffered, defer: false)
        win.title = "Chart"
        win.tabbingMode = .disallowed
        win.appearance = ThemeManager.current.appearance
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        // No visible titlebar → let the user drag the window by any
        // empty glass area, like modern utility windows.
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.level = MainWindowController.popoutsFloat ? .floating : .normal
        super.init(window: win)
        win.setFrameAutosaveName(Self.frameAutosaveName)
        win.delegate = self
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    // A brand-new pop-out used to appear wherever its (0,0) frame
    // landed, the screen's bottom-left corner, behind the Dock, so
    // "Open" looked like it had done nothing and got clicked again and
    // again. Centre it on the screen that owns the document window
    // instead.
    func placeNearMainWindow(_ main: NSWindow?) {
        guard let win = window else { return }
        // A remembered position wins (frame autosave); centring is only
        // for the very first pop-out.
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") != nil { return }
        let screen = main?.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { win.center(); return }
        // 86 percent of the work area, the same proportion the Windows
        // edition uses, instead of a fixed 1100 by 480 that ignored how
        // much screen there is.
        var f = win.frame
        f.size.width = vf.width * 0.86
        f.size.height = vf.height * 0.86
        f.size.width = min(f.width, vf.width - 40)
        f.size.height = min(f.height, vf.height - 40)
        f.origin = NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
        win.setFrame(win.constrainFrameRect(f, to: screen), display: false)
    }

    /// Wide enough for every bar to keep its label; otherwise the window.
    private func updateChartWidth() {
        let visible = chartScroll.contentView.bounds.width
        var wanted = visible
        if let s = currentSeries, s.kind == .bar {
            // Ask the chart itself: it knows how much room the y-axis
            // numbers take and scales the slot with its own text size.
            wanted = max(visible, chart.preferredWidth(barSlot: minBarSlot))
        }
        if abs((chartWidthCon?.constant ?? 0) - wanted) > 0.5 {
            chartWidthCon?.constant = wanted
            chart.needsDisplay = true
        }
    }

    func setSeries(_ series: TrendSeries, path: String = "") {
        currentSeries = series
        chart.series = series
        updateChartWidth()
        dataTable.reloadData()
        // Title shown in the toolbar label (title bar is hidden);
        // beneath it the tree path says exactly WHERE in the file
        // this chart comes from ("region[USA] › supplysector[trn_pass]").
        toolbarTitle.stringValue = series.title
        pathLabel.stringValue = path
        pathLabel.toolTip = path
        window?.title = path.isEmpty ? series.title : "\(series.title), \(path)"
    }

    func clearSeries(message: String = "No repeating numbers under this element") {
        currentSeries = nil
        chart.series = nil
        updateChartWidth()
        chart.placeholderText = message
        toolbarTitle.stringValue = "No chart available"
        pathLabel.stringValue = ""
        pathLabel.toolTip = nil
        window?.title = "Chart"
        dataTable.reloadData()
    }

    private let toolbarTitle = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    /// Kept so a theme switch can swap the vibrancy material.
    private weak var backdrop: NSVisualEffectView?
    private weak var rootBackdrop: NSView?

    private func buildLayout() {
        guard let win = window else { return }

        // Whole-window visual-effect backdrop → Aurora glass.
        let backdrop = NSVisualEffectView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        // Flat rendering, matching the main window's GlassPanels, 
        // .active let the wallpaper tint the chart backdrop.
        backdrop.state = .inactive
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = XMMetric.radiusWindow
        backdrop.layer?.masksToBounds = true
        backdrop.material = ThemeManager.current.glassMaterial
        self.backdrop = backdrop

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.cornerRadius = XMMetric.radiusWindow
        root.layer?.masksToBounds = true
        self.rootBackdrop = root
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Toolbar strip, borderless (title + pills float directly on
        // the glass, Safari-style). The old boxed card sat UNDER the
        // traffic-light buttons; now the strip starts to their right.
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        toolbarTitle.translatesAutoresizingMaskIntoConstraints = false
        toolbarTitle.font = XMFont.ui(13, .semibold)
        toolbarTitle.textColor = XMColor.text
        toolbarTitle.lineBreakMode = .byTruncatingTail
        toolbar.addSubview(toolbarTitle)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = XMFont.ui(11, .medium)
        pathLabel.textColor = XMColor.text   // full-strength, not grey
        pathLabel.lineBreakMode = .byTruncatingMiddle
        toolbar.addSubview(pathLabel)

        labelsToggle = GlassPillButton(title: "Labels", toggle: true) { [weak self] pressed in
            self?.chart.showLabels = pressed
        }
        tableToggle = GlassPillButton(title: "Table", toggle: true) { [weak self] pressed in
            self?.setTableVisible(pressed)
        }
        saveButton = GlassPillButton(title: "Save Image…", toggle: false) { [weak self] _ in
            self?.saveImage()
        }
        copyButton = GlassPillButton(title: "Copy", toggle: false) { [weak self] _ in
            self?.copyImage()
        }
        csvButton = GlassPillButton(title: "Export CSV…", toggle: false) { [weak self] _ in
            self?.exportCSV()
        }

        buildToggle = GlassPillButton(title: "Build", toggle: true) { [weak self] pressed in
            self?.setBuilderVisible(pressed)
        }
        let actions = NSStackView(views: [buildToggle, labelsToggle, tableToggle, saveButton, copyButton, csvButton])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.spacing = 8
        actions.orientation = .horizontal
        toolbar.addSubview(actions)

        NSLayoutConstraint.activate([
            toolbarTitle.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarTitle.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 2),
            toolbarTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

            pathLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: toolbarTitle.bottomAnchor, constant: 1),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

            actions.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        // Chart Builder strip, hidden until Build is pressed: the path
        // of dropdowns on a horizontally scrolling row, Value + pills on
        // a second row so nothing is ever cut off.
        builderBar.translatesAutoresizingMaskIntoConstraints = false
        builderBar.wantsLayer = true
        builderBar.layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35).cgColor
        builderBar.layer?.cornerRadius = XMMetric.radiusCard
        builderBar.layer?.borderColor = XMColor.hairline.cgColor
        builderBar.layer?.borderWidth = XMMetric.hairline
        builderBar.isHidden = true
        pathStack.translatesAutoresizingMaskIntoConstraints = false
        pathStack.orientation = .horizontal
        pathStack.spacing = 6
        pathStack.alignment = .centerY
        pathScroll.translatesAutoresizingMaskIntoConstraints = false
        pathScroll.drawsBackground = false
        pathScroll.borderType = .noBorder
        pathScroll.hasHorizontalScroller = true
        pathScroll.hasVerticalScroller = false
        pathScroll.autohidesScrollers = true
        pathScroll.horizontalScrollElasticity = .none
        pathScroll.documentView = pathStack
        builderBar.addSubview(pathScroll)
        valueRow.translatesAutoresizingMaskIntoConstraints = false
        valueRow.orientation = .horizontal
        valueRow.spacing = 8
        valueRow.alignment = .centerY
        builderBar.addSubview(valueRow)
        builderNote.font = XMFont.uiCaption
        builderNote.textColor = XMColor.text3
        builderNote.lineBreakMode = .byTruncatingTail
        valuePopup.controlSize = .small
        valuePopup.font = XMFont.ui(11, .medium)
        valuePopup.target = self
        valuePopup.action = #selector(valueChanged(_:))
        followToggle = GlassPillButton(title: "Follow tree", toggle: true) { [weak self] pressed in
            guard let self else { return }
            self.followTree = pressed
            if pressed, let node = self.contextNode { self.seedBuilder(from: node) }
        }
        followToggle.isOn = true
        revealButton = GlassPillButton(title: "Show in Tree", toggle: false) { [weak self] _ in
            guard let self, let node = self.builder?.deepestPinnedNode else { return }
            self.onRevealNode?(node)
        }
        NSLayoutConstraint.activate([
            pathScroll.topAnchor.constraint(equalTo: builderBar.topAnchor, constant: 5),
            pathScroll.leadingAnchor.constraint(equalTo: builderBar.leadingAnchor, constant: 10),
            pathScroll.trailingAnchor.constraint(equalTo: builderBar.trailingAnchor, constant: -10),
            pathScroll.heightAnchor.constraint(equalToConstant: 30),
            pathStack.leadingAnchor.constraint(equalTo: pathScroll.contentView.leadingAnchor),
            pathStack.topAnchor.constraint(equalTo: pathScroll.contentView.topAnchor),
            pathStack.heightAnchor.constraint(equalTo: pathScroll.contentView.heightAnchor),
            valueRow.topAnchor.constraint(equalTo: pathScroll.bottomAnchor, constant: 4),
            valueRow.leadingAnchor.constraint(equalTo: builderBar.leadingAnchor, constant: 10),
            valueRow.trailingAnchor.constraint(lessThanOrEqualTo: builderBar.trailingAnchor, constant: -10),
            valueRow.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Chart card.
        let chartCard = NSView()
        chartCard.translatesAutoresizingMaskIntoConstraints = false
        chartCard.wantsLayer = true
        chartCard.layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35).cgColor
        chartCard.layer?.cornerRadius = XMMetric.radiusCard
        chartCard.layer?.borderColor = XMColor.hairline.cgColor
        chartCard.layer?.borderWidth = XMMetric.hairline
        // The chart lives in a horizontal scroller: with many bars (32
        // regions) it grows wider than the window instead of squeezing,
        // and the window scrolls left and right to reach the rest.
        chartScroll.translatesAutoresizingMaskIntoConstraints = false
        chartScroll.drawsBackground = false
        chartScroll.borderType = .noBorder
        chartScroll.hasHorizontalScroller = true
        chartScroll.hasVerticalScroller = false
        chartScroll.autohidesScrollers = true
        chartScroll.horizontalScrollElasticity = .none
        chart.translatesAutoresizingMaskIntoConstraints = false
        chartScroll.documentView = chart
        chartCard.addSubview(chartScroll)
        let chartW = chart.widthAnchor.constraint(equalToConstant: 800)
        self.chartWidthCon = chartW
        NSLayoutConstraint.activate([
            chartScroll.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 4),
            chartScroll.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 4),
            chartScroll.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -4),
            chartScroll.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -4),
            chart.leadingAnchor.constraint(equalTo: chartScroll.contentView.leadingAnchor),
            chart.topAnchor.constraint(equalTo: chartScroll.contentView.topAnchor),
            chart.heightAnchor.constraint(equalTo: chartScroll.contentView.heightAnchor),
            chartW,
        ])
        chartScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: chartScroll.contentView, queue: .main) { [weak self] _ in
            self?.updateChartWidth()
        }
        // Disable the inline chart's ↗ button here, we're already
        // the pop-out window.
        chart.onPopoutRequested = nil
        // The pop-out is the BIG chart, labels, axis values and
        // title all render half again larger than the inline card.
        chart.fontScale = 1.5

        // Table card (height can be 0 to hide).
        let tableCard = NSView()
        tableCard.translatesAutoresizingMaskIntoConstraints = false
        tableCard.wantsLayer = true
        tableCard.layer?.backgroundColor = XMColor.bgDeep.withAlphaComponent(0.35).cgColor
        tableCard.layer?.cornerRadius = XMMetric.radiusCard
        tableCard.layer?.borderColor = XMColor.hairline.cgColor
        tableCard.layer?.borderWidth = XMMetric.hairline
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.documentView = dataTable
        tableCard.addSubview(tableScroll)
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: tableCard.topAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: tableCard.leadingAnchor, constant: 4),
            tableScroll.trailingAnchor.constraint(equalTo: tableCard.trailingAnchor, constant: -4),
            tableScroll.bottomAnchor.constraint(equalTo: tableCard.bottomAnchor, constant: -4),
        ])

        dataTable.style = .inset
        dataTable.headerView = NSTableHeaderView()
        dataTable.backgroundColor = .clear
        dataTable.gridColor = XMColor.hairline
        dataTable.usesAlternatingRowBackgroundColors = false
        dataTable.rowHeight = 22
        dataTable.dataSource = self
        dataTable.delegate = self
        let keyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        keyCol.title = "Label"; keyCol.width = 260; keyCol.minWidth = 100
        dataTable.addTableColumn(keyCol)
        let valCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valCol.title = "Value"; valCol.width = 180; valCol.minWidth = 80
        dataTable.addTableColumn(valCol)

        root.addSubview(toolbar)
        root.addSubview(builderBar)
        root.addSubview(chartCard)
        root.addSubview(tableCard)

        let pad: CGFloat = 12
        let tableH = tableCard.heightAnchor.constraint(equalToConstant: 0)
        self.tableHeightCon = tableH
        let builderH = builderBar.heightAnchor.constraint(equalToConstant: 0)
        self.builderHeightCon = builderH
        NSLayoutConstraint.activate([
            // Leading 84 keeps the title clear of the traffic-light
            // buttons (fullSizeContentView puts them over our content).
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 84),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH - 12),

            builderBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            builderBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            builderBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            builderH,
            chartCard.topAnchor.constraint(equalTo: builderBar.bottomAnchor, constant: 10),
            chartCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            chartCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            chartCard.heightAnchor.constraint(greaterThanOrEqualToConstant: chartMinH),

            tableCard.topAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: 10),
            tableCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            tableCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            tableCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            tableH,
        ])

        win.contentView = root
        applySurface()
    }

    // MARK: Chart Builder (v1.0.3)

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = XMFont.uiCaption
        l.textColor = XMColor.text3
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// Called by MainWindowController whenever the inline chart changes.
    /// The mirrored series shows unless the builder is open; then the
    /// builder follows the tree selection (if Follow tree is on).
    func setMirroredSeries(_ series: TrendSeries?, path: String, node: XMLTreeNode?, documentRoot: XMLTreeNode?) {
        mirroredSeries = series
        mirroredPath = path
        contextNode = node
        self.documentRoot = documentRoot
        if builderVisible {
            ensureBuilder()
            if followTree, let node { seedBuilder(from: node) } else { recompute() }
        } else if let series {
            setSeries(series, path: path)
        } else {
            clearSeries()
        }
    }

    func showBuilder(root: XMLTreeNode?, documentRoot: XMLTreeNode?) {
        contextNode = root
        self.documentRoot = documentRoot
        buildToggle.isOn = true
        setBuilderVisible(true)
    }

    private func setBuilderVisible(_ visible: Bool) {
        builderVisible = visible
        builderBar.isHidden = !visible
        builderHeightCon?.constant = visible ? 72 : 0
        if visible {
            ensureBuilder()
            if let node = contextNode { seedBuilder(from: node) } else { rebuildControls(); recompute() }
        } else if let s = mirroredSeries {
            setSeries(s, path: mirroredPath)
        } else {
            clearSeries()
        }
    }

    /// One builder per document tree; a reparse (new root object) starts over.
    private func ensureBuilder() {
        guard let docRoot = documentRoot else { builder = nil; builderRootID = nil; return }
        let id = ObjectIdentifier(docRoot)
        if builder == nil || builderRootID != id {
            builder = ChartPathBuilder(root: docRoot)
            builderRootID = id
            builder?.rebuild(seed: contextNode)
        }
    }

    private func seedBuilder(from node: XMLTreeNode) {
        guard let b = builder else { rebuildControls(); recompute(); return }
        let keepValue = b.valueName
        b.rebuild(seed: node)
        if let v = keepValue, b.valueNames.contains(v) { b.valueName = v }
        rebuildControls()
        recompute()
    }

    /// Row 1: one dropdown per level of the path. Row 2: Value + pills.
    private func rebuildControls() {
        pathStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        valueRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        levelPopups = []
        guard let b = builder else {
            pathStack.addArrangedSubview(caption("Open a file first"))
            return
        }
        for (i, lvl) in b.levels.enumerated() {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = XMFont.ui(11, .medium)
            popup.target = self
            popup.action = #selector(levelChanged(_:))
            popup.tag = i
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
            let members = lvl.members.count
            // Item 0 = the axis choice; the rest = the members, one each.
            popup.addItem(withTitle: "across all \(members) \(lvl.tag)s")
            popup.item(at: 0)?.isEnabled = members >= 2
            for (j, o) in lvl.options.enumerated() {
                let title = lvl.mixedTags ? o.label : o.key
                popup.addItem(withTitle: title.isEmpty ? "(\(j + 1))" : title)
                popup.lastItem?.tag = j
            }
            popup.selectItem(at: lvl.isAxis ? 0 : lvl.choice + 1)
            pathStack.addArrangedSubview(caption(i == 0 ? lvl.tag : "› \(lvl.tag)"))
            pathStack.addArrangedSubview(popup)
            levelPopups.append(popup)
        }
        valuePopup.removeAllItems()
        valuePopup.addItems(withTitles: b.valueNames)
        if let v = b.valueName { valuePopup.selectItem(withTitle: v) }
        valueRow.addArrangedSubview(caption("Value"))
        valueRow.addArrangedSubview(valuePopup)
        valueRow.addArrangedSubview(followToggle)
        valueRow.addArrangedSubview(revealButton)
        valueRow.addArrangedSubview(builderNote)
        builderNote.stringValue = b.valueScanTruncated
            ? "first \(ChartPathBuilder.scanCap / 1000)k elements scanned for values"
            : (b.valueNames.isEmpty ? "nothing numeric under this choice" : "")
        pathStack.layoutSubtreeIfNeeded()
    }

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        guard let b = builder else { return }
        let i = sender.tag
        if sender.indexOfSelectedItem == 0 {
            b.setAxis(level: i)
        } else if let item = sender.selectedItem {
            b.setChoice(level: i, option: item.tag)
        }
        rebuildControls()
        recompute()
    }

    @objc private func valueChanged(_ sender: NSPopUpButton) {
        builder?.valueName = sender.titleOfSelectedItem
        recompute()
    }

    private func recompute() {
        guard builderVisible else { return }
        guard let b = builder else { clearSeries(message: "Open a file first"); return }
        guard b.axisIndex != nil else { clearSeries(message: "Pick \"across all …\" in one dropdown"); return }
        guard let value = b.valueName else { clearSeries(message: "Nothing numeric under this choice"); return }
        if let series = b.compute() {
            setSeries(series, path: b.lastPathSummary)
        } else {
            clearSeries(message: "No \(value) values along this path")
        }
    }

    // Toggling the table grows or shrinks the window so the chart
    // area stays the same height. Uses an animated frame change so
    // the resize feels intentional.
    private func setTableVisible(_ visible: Bool) {
        guard tableVisible != visible, let win = window else { return }
        tableVisible = visible
        tableHeightCon?.constant = visible ? tableHeight : 0
        var f = win.frame
        let delta = (visible ? 1 : -1) * (tableHeight + 10)
        f.size.height += delta
        f.origin.y    -= delta   // keep top edge pinned
        win.animator().setFrame(f, display: true)
    }

    private func saveImage() {
        guard let win = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chart.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.message = "Save chart as image"
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard let data = self.renderChartPNGData() else {
                NSSound.beep()
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
                let a = NSAlert()
                a.messageText = "Could not save the image"
                a.informativeText = "\(url.lastPathComponent) could not be written. Try another folder."
                a.runModal()
                return
            }
            NSWorkspace.shared.open(url)   // auto-open the export
        }
    }

    private func copyImage() {
        chart.isRenderingForExport = true
        defer { chart.isRenderingForExport = false; chart.needsDisplay = true }
        guard let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) else { return }
        chart.cacheDisplay(in: chart.bounds, to: rep)
        let img = NSImage(size: chart.bounds.size)
        img.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    // Export the chart's data table (Label,Value) as CSV, works
    // whether or not the on-screen table is currently toggled on.
    private func exportCSV() {
        guard let win = window, let series = currentSeries else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chart-data.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "Export the chart's data as CSV"
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            // Labels are the user's own attribute values, so they go out
            // exactly as they are; the byte-order mark keeps them legible.
            let rows = series.values.indices.map { i in
                [CSVExport.field(i < series.xLabels.count ? series.xLabels[i] : ""),
                 CSVExport.number(series.values[i])]
            }
            guard CSVExport.write(header: ["Label", "Value"], rows: rows, to: url) else {
                NSSound.beep()
                let a = NSAlert()
                a.messageText = "Could not save the CSV"
                a.informativeText = "\(url.lastPathComponent) could not be written. Try another folder."
                a.runModal()
                return
            }
            NSWorkspace.shared.open(url)   // auto-open the export
        }
    }

    private func renderChartPNGData() -> Data? {
        chart.isRenderingForExport = true
        defer { chart.isRenderingForExport = false; chart.needsDisplay = true }
        let rect = chart.bounds
        guard let rep = chart.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        chart.cacheDisplay(in: rect, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Re-read every cached colour after a theme switch. Without this the
    /// pop-out kept the colours of whatever theme was live when it opened,
    /// which left combinations such as near-black text on a dark ground.
    func rebuildColors() {
        window?.appearance = ThemeManager.current.appearance
        applySurface()
        toolbarTitle.textColor = XMColor.text
        pathLabel.textColor = XMColor.text
        builderNote.textColor = XMColor.text3
        for v in pathStack.arrangedSubviews {
            if let tf = v as? NSTextField, !tf.isEditable { tf.textColor = XMColor.text3 }
        }
        for v in valueRow.arrangedSubviews {
            if let tf = v as? NSTextField, !tf.isEditable { tf.textColor = XMColor.text3 }
        }
        tableScroll.backgroundColor = XMColor.bgDeep
        dataTable.backgroundColor = .clear
        dataTable.reloadData()
        chart.needsDisplay = true
        window?.contentView?.needsDisplayRecursively()
    }

    // Blur the desktop only for the two themes built around it; every
    // other theme paints its own surface so the pop-out matches the
    // main window instead of turning grey.
    private func applySurface() {
        let theme = ThemeManager.current
        backdrop?.material = theme.glassMaterial
        backdrop?.isHidden = !theme.usesVibrancy
        rootBackdrop?.layer?.backgroundColor = theme.usesVibrancy ? nil : theme.panelOpaque.cgColor
    }

    // MARK: this window's own zoom
    //
    // Command-scroll and command +/-/0 scale the chart's text, leaving the
    // application zoom alone.
    private var localZoom: CGFloat = 1
    private var zoomMonitor: Any?

    func installZoomMonitor() {
        guard zoomMonitor == nil else { return }
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
        chart.fontScale = 1.5 * localZoom
        updateChartWidth()
        chart.needsDisplay = true
    }

    @objc func xmZoomIn(_ sender: Any?)    { setLocalZoom(localZoom * 1.1) }
    @objc func xmZoomOut(_ sender: Any?)   { setLocalZoom(localZoom / 1.1) }
    @objc func xmZoomReset(_ sender: Any?) { setLocalZoom(1) }

    func windowWillClose(_ notification: Notification) {
        if let m = zoomMonitor { NSEvent.removeMonitor(m); zoomMonitor = nil }
        if let win = window, let p = win.parent { p.removeChildWindow(win) }
        onClose?()
    }

    // Zoom (green button) = fill the screen, same fix as the main
    // window; the default zoom was best-fitting to content size.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }
}

// MARK: - Data source for the table

extension ChartPopoutWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return currentSeries?.values.count ?? 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let s = currentSeries, row < s.values.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("chartCell")
        let cell: NSTableCellView
        if let r = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = r
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.isEditable = false
            tf.font = XMFont.mono(11.5, .regular)
            tf.textColor = XMColor.text
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if col.identifier.rawValue == "label" {
            cell.textField?.stringValue = s.xLabels[row]
        } else {
            cell.textField?.stringValue = String(format: "%g", s.values[row])
        }
        return cell
    }
}

// MARK: - Aurora pill button

// Custom button: rounded-pill glass background, Aurora text, optional
// toggle state. Draws its own fill/border so it fits the dark theme
// far better than NSButton(.rounded) which renders as a system-gray
// bezeled button and looked out of place in v0.13.2.
private final class GlassPillButton: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let isToggle: Bool
    var isOn: Bool = false { didSet { needsDisplay = true } }
    private let onTap: (Bool) -> Void
    private var tracking: NSTrackingArea?
    private var isHover: Bool = false { didSet { needsDisplay = true } }

    init(title: String, toggle: Bool, onTap: @escaping (Bool) -> Void) {
        self.isToggle = toggle
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.ui(12, .semibold)
        titleLabel.textColor = XMColor.text
        titleLabel.stringValue = title
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHover = true  }
    override func mouseExited(with event: NSEvent)  { isHover = false }
    override func mouseDown(with event: NSEvent) {
        if isToggle { isOn.toggle() }
        onTap(isToggle ? isOn : true)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let p = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)

        let fill: NSColor
        let stroke: NSColor
        if isOn {
            fill   = XMColor.accent.withAlphaComponent(0.30)
            stroke = XMColor.accent.withAlphaComponent(0.85)
        } else if isHover {
            fill   = XMColor.hairline.withAlphaComponent(0.55)
            stroke = XMColor.hairlineS
        } else {
            fill   = XMColor.bg.withAlphaComponent(0.55)
            stroke = XMColor.hairline
        }
        ctx.setFillColor(fill.cgColor)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(0.5)
        ctx.addPath(p)
        ctx.drawPath(using: .fillStroke)
        titleLabel.textColor = isOn ? XMColor.text : XMColor.text2
    }
}
