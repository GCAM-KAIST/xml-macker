import Cocoa

// A radial diagram cannot grow typography to 200% while keeping fixed-angle
// chips from colliding. Orbit follows the application's zoom direction, but
// caps only its spatial-canvas typography to a readable 75-125% range. The
// scrollable Details rail guarantees that this fitting never hides data.
private enum OrbitTypography {
    static var scale: CGFloat { min(1.25, max(0.75, XMFont.globalScale)) }

    private static func size(_ base: CGFloat) -> CGFloat {
        let scaled = base * scale
        return (scaled * 2).rounded() / 2
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        .systemFont(ofSize: self.size(size), weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: self.size(size), weight: weight)
    }

    static var caption: NSFont { ui(10, .medium) }
}

// Orbit, a radial "you are here" map of the selected element,
// rebuilt from scratch in v0.34.0: the shapes, the design, the
// frames, the drawing code and the way the data is shown were all
// replaced rather than patched.
//
// The model (what orbits what):
//   • CENTER  , the selected element: a glass "sun" showing the tag,
//                counts, and its key attributes.
//   • RING    , its CHILDREN as chips on the orbit. When there are
//                more children than fit, the scroll wheel ROTATES the
//                ring through all of them (the old design hid
//                everything past 5 behind a dead "+N" chip).
//   • OUTER ARC, SIBLINGS as small dots across the top; hover names
//                them, click jumps to them.
//   • TOP BAR , clickable breadcrumb path from the root, plus an
//                "↑ parent" pill.
//   • INFO CARD, hovering anything shows its full details bottom-left
//                (attributes, text, line span) without navigating.
//
// Interaction contract (unchanged): clicking any node routes through
// MainWindowController.onNodeClicked → treeVC.select, so the tree,
// source, inspector and preview all follow. handleTreeSelection then
// re-presents the orbit, which animates into the new arrangement.
final class OrbitWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "xml-mackerOrbit"

    let orbitView = OrbitView()
    var onNodeClicked: ((XMLTreeNode) -> Void)?
    var onNodeEditRequested: ((XMLTreeNode) -> Void)?
    var onAttributeEdit: ((XMLTreeNode, String, String) -> Bool)?
    var onTextEdit: ((XMLTreeNode, String) -> Bool)?
    private var checkedInitialPlacement = false

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Read the name from the bundle so a future rename never leaves
        // a stale title behind in a screenshot.
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "xml-macker"
        win.title = "Orbit, \(appName)"
        // A scrollable Details rail now lives beside the visualization.
        // Keep enough room for both at the smallest supported size.
        win.minSize = NSSize(width: 760, height: 540)
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bgDeep
        win.collectionBehavior = [.fullScreenAuxiliary]
        // Preserve the existing autosave key so current users keep their
        // preferred Orbit placement after upgrading.
        win.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: win)
        win.delegate = self
        orbitView.onNodeClicked = { [weak self] node in
            self?.onNodeClicked?(node)
        }
        orbitView.onNodeEditRequested = { [weak self] node in
            self?.onNodeEditRequested?(node)
        }
        orbitView.onAttributeEdit = { [weak self] node, name, value in
            self?.onAttributeEdit?(node, name, value) ?? false
        }
        orbitView.onTextEdit = { [weak self] node, text in
            self?.onTextEdit?(node, text) ?? false
        }
        win.contentView = orbitView
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: this window's own zoom
    //
    // Command-scroll and command +/-/0 scale the whole drawing, rings,
    // chips and text together, by scaling the view's coordinate system.
    // Doing it that way means clicks land where they look: the pointer is
    // converted through the same scale.
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
        // Back to identity first: scaleUnitSquare compounds.
        orbitView.bounds = NSRect(origin: .zero, size: orbitView.frame.size)
        if localZoom != 1 {
            orbitView.scaleUnitSquare(to: NSSize(width: localZoom, height: localZoom))
        }
        orbitView.needsDisplay = true
    }

    @objc func xmZoomIn(_ sender: Any?)    { setLocalZoom(localZoom * 1.1) }
    @objc func xmZoomOut(_ sender: Any?)   { setLocalZoom(localZoom / 1.1) }
    @objc func xmZoomReset(_ sender: Any?) { setLocalZoom(1) }

    func present(node: XMLTreeNode?) {
        if zoomMonitor == nil { installZoomMonitor() }
        orbitView.render(node: node)
    }

    func show() {
        orbitView.rebuildTypography()
        placeOnReachableScreenIfNeeded()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(orbitView)
    }

    // NSWindow frame autosaving is useful across launches, but a frame from
    // a disconnected display can otherwise leave a secondary window mostly
    // or completely unreachable. On first use, center an unsaved window on
    // the screen that owns the invoking/key window. Respect a saved frame as
    // long as a useful portion of it is still visible on any current screen.
    private func placeOnReachableScreenIfNeeded() {
        guard let win = window else { return }

        let screens = NSScreen.screens
        let isReachable = screens.contains { screen in
            let intersection = win.frame.intersection(screen.visibleFrame)
            return intersection.width >= min(180, win.frame.width * 0.25)
                && intersection.height >= min(100, win.frame.height * 0.20)
        }
        let frameKey = "NSWindow Frame \(Self.frameAutosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: frameKey) != nil
        let needsInitialPlacement = !checkedInitialPlacement && !hasSavedFrame
        checkedInitialPlacement = true

        guard needsInitialPlacement || !isReachable else { return }

        let invokingWindow = NSApp.keyWindow.flatMap { $0 === win ? nil : $0 }
            ?? NSApp.mainWindow.flatMap { $0 === win ? nil : $0 }
        guard let screen = invokingWindow?.screen ?? NSScreen.main ?? screens.first else { return }

        var frame = win.frame
        if needsInitialPlacement {
            let visible = screen.visibleFrame
            frame.size.width = min(1080, max(860, visible.width * 0.72))
            frame.size.height = min(820, max(640, visible.height * 0.76))
        }
        frame.origin = NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.midY - frame.height / 2
        )
        frame = win.constrainFrameRect(frame, to: screen)
        win.setFrame(frame, display: false)
    }

    // Theme hook, every color is fetched from XMColor at draw time,
    // so a redraw is all the view itself needs.
    func rebuildColors() {
        window?.backgroundColor = XMColor.bgDeep
        orbitView.rebuildColors()
    }

    func rebuildFonts() {
        orbitView.rebuildTypography()
    }
}

// MARK: - Orbit details rail

// Orbit is primarily a visual navigator, but the visualization must never be
// the only way to inspect data. This native table presents every attribute of
// the selected node and scrolls normally, so large attribute sets are not
// silently reduced to a decorative preview.
private enum OrbitNav { case parent, previous, next, firstChild }
private struct OrbitNavAvailability {
    var parent = false
    var previous = false
    var next = false
    var child = false
}

// v0.44.3: Orbit may be the only navigator in use, so it carries its
// own controls on the right, a navigation strip (parent / previous /
// next / first child) and in-place editing, double-click an attribute
// value, or change the text and press Apply. Edits travel the same
// verified source-edit path as the Inspector.
private final class OrbitDetailsView: NSView, NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate, NSTextViewDelegate {
    var onNavigate: ((OrbitNav) -> Void)?
    var onAttributeEdit: ((XMLTreeNode, String, String) -> Bool)?
    var onTextEdit: ((XMLTreeNode, String) -> Bool)?

    private let eyebrow = NSTextField(labelWithString: "SELECTED ELEMENT")
    private let titleField = NSTextField(labelWithString: "")
    private let metadataField = NSTextField(labelWithString: "")
    private let navStack = NSStackView()
    private let parentButton = NSButton(title: "↑ Parent", target: nil, action: nil)
    private let previousButton = NSButton(title: "◀ Prev", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next ▶", target: nil, action: nil)
    private let childButton = NSButton(title: "↓ Child", target: nil, action: nil)
    private let attributesLabel = NSTextField(labelWithString: "ATTRIBUTES")
    private let editHint = NSTextField(labelWithString: "double-click a value to edit")
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let textLabel = NSTextField(labelWithString: "TEXT CONTENT")
    private let applyTextButton = NSButton(title: "Apply", target: nil, action: nil)
    private let textView = NSTextView()
    private let textScroll = NSScrollView()

    private var node: XMLTreeNode?
    private var nav = OrbitNavAvailability()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        eyebrow.alignment = .left

        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadataField.lineBreakMode = .byTruncatingTail
        metadataField.maximumNumberOfLines = 1
        metadataField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureNavButton(parentButton, tag: 0, tip: "Go to the parent element")
        configureNavButton(previousButton, tag: 1, tip: "Go to the previous sibling (← key)")
        configureNavButton(nextButton, tag: 2, tip: "Go to the next sibling (→ key)")
        configureNavButton(childButton, tag: 3, tip: "Go into the first child")
        navStack.orientation = .horizontal
        navStack.distribution = .fillEqually
        navStack.spacing = 4
        for b in [parentButton, previousButton, nextButton, childButton] {
            navStack.addArrangedSubview(b)
        }

        editHint.alignment = .right
        editHint.lineBreakMode = .byTruncatingTail
        editHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("orbit.attribute.name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 78
        nameColumn.width = 105
        nameColumn.resizingMask = .userResizingMask
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("orbit.attribute.value"))
        valueColumn.title = "Value"
        valueColumn.minWidth = 100
        valueColumn.width = 190
        valueColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(valueColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(editClickedValue(_:))

        let menu = NSMenu(title: "Attribute")
        menu.addItem(withTitle: "Copy Attribute Name", action: #selector(copyAttributeName(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Attribute Value", action: #selector(copyAttributeValue(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy name=\"value\"", action: #selector(copyAttributeAssignment(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        tableView.menu = menu

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 7, height: 6)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder

        applyTextButton.bezelStyle = .rounded
        applyTextButton.controlSize = .small
        applyTextButton.target = self
        applyTextButton.action = #selector(applyText(_:))
        applyTextButton.isEnabled = false
        applyTextButton.isHidden = true
        applyTextButton.toolTip = "Write the edited text into the document"

        for view in [eyebrow, titleField, metadataField, navStack, attributesLabel, editHint,
                     tableScroll, textLabel, applyTextButton, textScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            eyebrow.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            eyebrow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            eyebrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            titleField.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),

            metadataField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 5),
            metadataField.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            metadataField.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),

            navStack.topAnchor.constraint(equalTo: metadataField.bottomAnchor, constant: 10),
            navStack.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),

            attributesLabel.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 14),
            attributesLabel.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            editHint.centerYAnchor.constraint(equalTo: attributesLabel.centerYAnchor),
            editHint.leadingAnchor.constraint(greaterThanOrEqualTo: attributesLabel.trailingAnchor, constant: 8),
            editHint.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: attributesLabel.bottomAnchor, constant: 6),
            tableScroll.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),

            textLabel.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 14),
            textLabel.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            applyTextButton.centerYAnchor.constraint(equalTo: textLabel.centerYAnchor),
            applyTextButton.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: applyTextButton.leadingAnchor, constant: -8),

            textScroll.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 6),
            textScroll.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: eyebrow.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            textScroll.heightAnchor.constraint(equalToConstant: 100)
        ])

        rebuildTypography()
        render(node: nil)
        rebuildColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureNavButton(_ button: NSButton, tag: Int, tip: String) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = tag
        button.toolTip = tip
        button.target = self
        button.action = #selector(navButtonPressed(_:))
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @objc private func navButtonPressed(_ sender: NSButton) {
        switch sender.tag {
        case 0: onNavigate?(.parent)
        case 1: onNavigate?(.previous)
        case 2: onNavigate?(.next)
        default: onNavigate?(.firstChild)
        }
    }

    func render(node newNode: XMLTreeNode?, nav newNav: OrbitNavAvailability? = nil) {
        rebuildTypography()
        node = newNode
        if let newNav { nav = newNav }
        if let newNode {
            let elementName = newNode.kind == .document
                ? newNode.displayLabel : "<\(newNode.displayLabel)>"
            titleField.stringValue = elementName
            titleField.toolTip = elementName
            let attributeWord = newNode.attributes.count == 1 ? "attribute" : "attributes"
            let elementChildCount = newNode.children.reduce(into: 0) { count, child in
                if child.kind == .element { count += 1 }
            }
            let childWord = elementChildCount == 1 ? "child" : "children"
            metadataField.stringValue = "lines \(newNode.startLine)-\(newNode.endLine)  ·  \(newNode.attributes.count) \(attributeWord)  ·  \(elementChildCount) \(childWord)"
            // Only a leaf's text is a value; a container's text is the
            // whitespace between its children.
            let canEditText = newNode.kind == .element && elementChildCount == 0 && onTextEdit != nil
            textView.string = newNode.textValue
            textView.isEditable = canEditText
            textLabel.stringValue = canEditText
                ? (newNode.textValue.isEmpty ? "TEXT CONTENT  ·  empty, type to add" : "TEXT CONTENT  ·  editable")
                : (newNode.textValue.isEmpty ? "TEXT CONTENT  ·  none" : "TEXT CONTENT")
            applyTextButton.isHidden = !canEditText
        } else {
            titleField.stringValue = "No selection"
            titleField.toolTip = nil
            metadataField.stringValue = "Select an element to inspect it"
            textView.string = ""
            textView.isEditable = false
            textLabel.stringValue = "TEXT CONTENT"
            applyTextButton.isHidden = true
        }
        applyTextButton.isEnabled = false
        let has = newNode != nil
        parentButton.isEnabled = has && nav.parent
        previousButton.isEnabled = has && nav.previous
        nextButton.isEnabled = has && nav.next
        childButton.isEnabled = has && nav.child
        editHint.isHidden = !(has && onAttributeEdit != nil && !(newNode?.attributes.isEmpty ?? true))
        tableView.reloadData()
        if let newNode, !newNode.attributes.isEmpty {
            tableView.scrollRowToVisible(0)
        }
    }

    private func rebuildTypography() {
        eyebrow.font = OrbitTypography.ui(9, .semibold)
        titleField.font = OrbitTypography.mono(15, .semibold)
        metadataField.font = OrbitTypography.caption
        attributesLabel.font = OrbitTypography.ui(9, .semibold)
        editHint.font = OrbitTypography.ui(9, .regular)
        textLabel.font = OrbitTypography.ui(9, .semibold)
        textView.font = OrbitTypography.mono(10.5, .regular)
        tableView.rowHeight = max(24, 21 * OrbitTypography.scale)
        let buttonFont = OrbitTypography.ui(10, .medium)
        for b in [parentButton, previousButton, nextButton, childButton, applyTextButton] {
            b.font = buttonFont
        }
    }

    func rebuildColors() {
        layer?.backgroundColor = XMColor.panel.withAlphaComponent(0.96).cgColor
        eyebrow.textColor = XMColor.text3
        titleField.textColor = XMColor.syntaxTag
        metadataField.textColor = XMColor.text3
        attributesLabel.textColor = XMColor.text3
        editHint.textColor = XMColor.text3
        textLabel.textColor = XMColor.text3
        tableView.backgroundColor = XMColor.panel
        tableView.gridColor = XMColor.hairline
        textView.backgroundColor = XMColor.bg
        textView.textColor = XMColor.text2
        textView.insertionPointColor = XMColor.accent
        tableView.reloadData()
        needsDisplay = true
    }

    // MARK: Attributes table

    func numberOfRows(in tableView: NSTableView) -> Int {
        node?.attributes.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let node, row >= 0, row < node.attributes.count, let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let isValue = identifier.rawValue == "orbit.attribute.value"
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.usesSingleLineMode = true
            if isValue {
                field.isBezeled = false
                field.drawsBackground = false
                field.isSelectable = true
                field.delegate = self
            }
        }
        field.font = OrbitTypography.mono(10.5, .regular)
        let attribute = node.attributes[row]
        let value = isValue ? attribute.value : attribute.name
        field.stringValue = value
        field.toolTip = value
        field.textColor = isValue ? XMColor.text2 : XMColor.syntaxAttr
        field.isEditable = isValue && onAttributeEdit != nil
        return field
    }

    @objc private func editClickedValue(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, node != nil, onAttributeEdit != nil else { return }
        tableView.editColumn(1, row: row, with: nil, select: true)
    }

    // Commit an in-place attribute edit through the verified source
    // path; a rejected edit snaps the cell back to the real value.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let node else { return }
        let row = tableView.row(for: field)
        guard row >= 0, row < node.attributes.count else { return }
        let attribute = node.attributes[row]
        let newValue = field.stringValue
        guard newValue != attribute.value else { return }
        if onAttributeEdit?(node, attribute.name, newValue) != true {
            NSSound.beep()
            field.stringValue = attribute.value
        }
    }

    // MARK: Text content

    func textDidChange(_ notification: Notification) {
        guard let node else { return }
        applyTextButton.isEnabled = textView.string != node.textValue
    }

    @objc private func applyText(_ sender: Any?) {
        guard let node else { return }
        if onTextEdit?(node, textView.string) == true {
            applyTextButton.isEnabled = false
        } else {
            NSSound.beep()
        }
    }

    // MARK: Copy menu

    private func targetRow() -> Int? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let node, row >= 0, row < node.attributes.count else { return nil }
        return row
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @objc private func copyAttributeName(_ sender: Any?) {
        guard let row = targetRow(), let attribute = node?.attributes[row] else { return }
        copyToPasteboard(attribute.name)
    }

    @objc private func copyAttributeValue(_ sender: Any?) {
        guard let row = targetRow(), let attribute = node?.attributes[row] else { return }
        copyToPasteboard(attribute.value)
    }

    @objc private func copyAttributeAssignment(_ sender: Any?) {
        guard let row = targetRow(), let attribute = node?.attributes[row] else { return }
        copyToPasteboard("\(attribute.name)=\"\(attribute.value)\"")
    }
}

// MARK: - OrbitView

// Draw-based (same idiom as TrendView / HierarchyMiniView): one draw
// pass builds the frame AND the hit regions; hover and the ring
// rotation just invalidate. No layer tree to keep in sync.
final class OrbitView: NSView {
    var onNodeClicked: ((XMLTreeNode) -> Void)?
    // Right-click a chip/sun → quick value editor (handled by
    // MainWindowController so the edit goes through the same verified
    // source-edit path as the inspector).
    var onNodeEditRequested: ((XMLTreeNode) -> Void)?
    // In-place edits from the Details rail; return false to reject.
    var onAttributeEdit: ((XMLTreeNode, String, String) -> Bool)?
    var onTextEdit: ((XMLTreeNode, String) -> Bool)?

    private var node: XMLTreeNode?
    private let detailsView = OrbitDetailsView(frame: .zero)
    private let childPager = NSSegmentedControl(
        labels: ["Previous", "Next"], trackingMode: .momentary,
        target: nil, action: nil
    )
    // "Structure only" (v0.44.1), orbit only the children that contain
    // other elements; plain values (the GCAM noise) stay in the Details
    // rail. One preference shared with the Hierarchy pane.
    private let structureToggle = NSButton(checkboxWithTitle: "Structure only",
                                           target: nil, action: nil)
    private var structureObserver: NSObjectProtocol?

    // Hit testing + hover. Regions are rebuilt every draw pass.
    private struct HitRegion {
        let rect: NSRect
        let node: XMLTreeNode
        let key: String       // stable identity for hover comparisons
    }
    private var hitRegions: [HitRegion] = []
    private var hoverKey: String?
    private var hoverNode: XMLTreeNode?
    private var infoCardRect: NSRect = .zero

    // Ring rotation: which child sits in the first slot. The scroll
    // wheel advances it; spinPhase eases the visual rotation so the
    // ring turns instead of teleporting.
    private var ringStart: Int = 0
    private var spinPhase: CGFloat = 0        // ±1 → 0 while animating
    private var spinTimer: Timer?

    // Appear animation: chips scale/fade in when the center changes.
    private var appearProgress: CGFloat = 1
    private var appearTimer: Timer?

    // Mouse-down is deferred until mouse-up so a child chip remains a normal
    // click target while also acting as a handle for drag-to-rotate.
    private var pendingClick: HitRegion?
    private var dragOrigin: NSPoint?
    private var ringDragLastAngle: CGFloat?
    private var ringDragRemainder: CGFloat = 0
    private var didDragRing = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(detailsView)
        detailsView.onNavigate = { [weak self] direction in self?.navigate(direction) }
        detailsView.onAttributeEdit = { [weak self] node, name, value in
            self?.onAttributeEdit?(node, name, value) ?? false
        }
        detailsView.onTextEdit = { [weak self] node, text in
            self?.onTextEdit?(node, text) ?? false
        }
        childPager.target = self
        childPager.action = #selector(pageChildren(_:))
        childPager.segmentStyle = .rounded
        childPager.controlSize = .small
        childPager.setToolTip("Show the previous children", forSegment: 0)
        childPager.setToolTip("Show the next children", forSegment: 1)
        childPager.setAccessibilityLabel("Orbit child pages")
        addSubview(childPager)

        structureToggle.target = self
        structureToggle.action = #selector(toggleStructure(_:))
        structureToggle.controlSize = .small
        structureToggle.state = StructureFilter.enabled ? .on : .off
        structureToggle.toolTip = "Orbit only the children that contain other elements; plain values stay in Details"
        structureToggle.setAccessibilityLabel("Structure only")
        addSubview(structureToggle)
        structureObserver = NotificationCenter.default.addObserver(
            forName: StructureFilter.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.structureToggle.state = StructureFilter.enabled ? .on : .off
            self.ringStart = 0
            self.spinPhase = 0
            self.needsLayout = true
            self.needsDisplay = true
        }
    }

    @objc private func toggleStructure(_ sender: NSButton) {
        StructureFilter.enabled = sender.state == .on
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        spinTimer?.invalidate()
        appearTimer?.invalidate()
        if let o = structureObserver { NotificationCenter.default.removeObserver(o) }
    }

    func render(node newNode: XMLTreeNode?) {
        let changed = newNode !== node
        node = newNode
        detailsView.render(node: newNode, nav: navAvailability(for: newNode))
        if changed {
            ringStart = 0
            spinPhase = 0
            hoverKey = nil
            hoverNode = nil
            startAppearAnimation()
        }
        updateChildPager()
        needsLayout = true
        needsDisplay = true
    }

    func rebuildColors() {
        detailsView.rebuildColors()
        needsDisplay = true
    }

    func rebuildTypography() {
        detailsView.render(node: node, nav: navAvailability(for: node))
        childPager.font = OrbitTypography.ui(10, .medium)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = detailsWidth()
        detailsView.frame = NSRect(x: bounds.maxX - width, y: bounds.minY,
                                   width: width, height: bounds.height)
        let pagerWidth: CGFloat = 128
        childPager.frame = NSRect(x: canvasRect.maxX - pagerWidth - 14, y: 7,
                                  width: pagerWidth, height: 25)
        childPager.font = OrbitTypography.ui(10, .medium)
        updateChildPager()
        // Structure toggle sits left of the pager (or takes its place).
        structureToggle.font = OrbitTypography.ui(10, .medium)
        structureToggle.sizeToFit()
        let toggleW = structureToggle.frame.width
        let toggleX = childPager.isHidden
            ? canvasRect.maxX - toggleW - 14
            : childPager.frame.minX - toggleW - 12
        structureToggle.frame = NSRect(x: toggleX, y: 9, width: toggleW,
                                       height: structureToggle.frame.height)
        needsDisplay = true
    }

    private func detailsWidth() -> CGFloat {
        // Scale with the window, but preserve a useful radial canvas even at
        // the minimum size. It is one rail, not a stack of competing panels.
        min(350, max(230, bounds.width * 0.31))
    }

    private var canvasRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY,
               width: max(1, bounds.width - detailsWidth() - 1),
               height: bounds.height)
    }

    private func updateChildPager() {
        guard let node else { childPager.isHidden = true; return }
        childPager.isHidden = ringChildren(of: node).count <= ringCapacity()
    }

    @objc private func pageChildren(_ sender: NSSegmentedControl) {
        guard let node else { return }
        let children = ringChildren(of: node)
        let capacity = ringCapacity()
        guard children.count > capacity else { return }
        let delta = sender.selectedSegment == 0 ? -capacity : capacity
        ringStart = ((ringStart + delta) % children.count + children.count) % children.count
        startSpin(from: delta > 0 ? 1 : -1)
    }

    private func startAppearAnimation() {
        appearTimer?.invalidate()
        appearProgress = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.appearProgress = min(1, self.appearProgress + 0.09)
            self.needsDisplay = true
            if self.appearProgress >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        appearTimer = t
    }

    // MARK: Tracking / hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Keep the current hover card stable while the pointer moves across
        // it, and do not let underlying orbit chips steal that hover.
        if !infoCardRect.isEmpty, infoCardRect.contains(p) { return }
        var newKey: String? = nil
        var newNode: XMLTreeNode? = nil
        for region in hitRegions.reversed() where region.rect.contains(p) {
            newKey = region.key
            newNode = region.node
            break
        }
        if newKey != hoverKey {
            hoverKey = newKey
            hoverNode = newNode
            if newKey != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverKey != nil {
            hoverKey = nil
            hoverNode = nil
            NSCursor.arrow.set()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard infoCardRect.isEmpty || !infoCardRect.contains(p) else { return }
        window?.makeFirstResponder(self)
        pendingClick = hitRegions.reversed().first(where: { $0.rect.contains(p) })
        dragOrigin = p
        didDragRing = false
        ringDragRemainder = 0

        guard let node, ringChildren(of: node).count > ringCapacity() else {
            ringDragLastAngle = nil
            return
        }
        let center = orbitCenter()
        let distance = hypot(p.x - center.x, p.y - center.y)
        let isChildChip = pendingClick?.key.hasPrefix("child-") == true
        let isNearRing = abs(distance - currentRingRadius()) <= 72
        if isChildChip || (pendingClick == nil && isNearRing) {
            spinTimer?.invalidate()
            ringDragLastAngle = atan2(p.y - center.y, p.x - center.x)
        } else {
            ringDragLastAngle = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node, let previousAngle = ringDragLastAngle else { return }
        let kids = ringChildren(of: node)
        let shown = min(kids.count, ringCapacity())
        guard kids.count > shown, shown > 0 else { return }

        let p = convert(event.locationInWindow, from: nil)
        let center = orbitCenter()
        let angle = atan2(p.y - center.y, p.x - center.x)
        var delta = angle - previousAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        ringDragLastAngle = angle
        ringDragRemainder += delta

        if let origin = dragOrigin, hypot(p.x - origin.x, p.y - origin.y) > 4 {
            didDragRing = true
        }

        let slotAngle = 2 * .pi / CGFloat(shown)
        let steps = Int(ringDragRemainder / slotAngle)
        if steps != 0 {
            ringStart = ((ringStart - steps) % kids.count + kids.count) % kids.count
            ringDragRemainder -= CGFloat(steps) * slotAngle
        }
        spinPhase = ringDragRemainder / slotAngle
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pendingClick = nil
            dragOrigin = nil
            ringDragLastAngle = nil
            ringDragRemainder = 0
            didDragRing = false
        }

        if didDragRing {
            startSpin(from: spinPhase)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        guard let region = pendingClick, region.rect.contains(p) else { return }
        onNodeClicked?(region.node)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard infoCardRect.isEmpty || !infoCardRect.contains(p) else { return }
        for region in hitRegions.reversed() where region.rect.contains(p) {
            onNodeEditRequested?(region.node)
            return
        }
    }

    // Scroll = rotate the children ring (wraps around, so every child
    // is reachable no matter how many there are). Deltas accumulate so
    // a fast free-spinning wheel (Logitech) advances MANY slots per
    // flick instead of crawling one notch per event.
    private var scrollAccum: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        guard let node, ringChildren(of: node).count > ringCapacity() else { return }
        scrollAccum += event.scrollingDeltaY
        let notch: CGFloat = 12
        let steps = Int(scrollAccum / notch)
        guard steps != 0 else { return }
        scrollAccum -= CGFloat(steps) * notch
        let kids = ringChildren(of: node)
        ringStart = ((ringStart - steps) % kids.count + kids.count) % kids.count
        let magnitude = min(2.0, 0.6 + CGFloat(abs(steps)) * 0.4)
        startSpin(from: steps > 0 ? -magnitude : magnitude)
    }

    override func keyDown(with event: NSEvent) {
        guard let node else { super.keyDown(with: event); return }
        let direction: Int
        switch event.keyCode {
        case 123: direction = -1 // left arrow
        case 124: direction = 1  // right arrow
        default: super.keyDown(with: event); return
        }

        // Plain arrows follow the original Orbit interaction contract and
        // traverse the complete sibling family. Option-arrows rotate one
        // child slot for precise keyboard control of an overflowing ring.
        if event.modifierFlags.contains(.option) {
            let kids = ringChildren(of: node)
            guard kids.count > ringCapacity() else { NSSound.beep(); return }
            ringStart = ((ringStart + direction) % kids.count + kids.count) % kids.count
            startSpin(from: direction > 0 ? 1 : -1)
        } else if let sibling = adjacentSibling(to: node, offset: direction) {
            onNodeClicked?(sibling)
        } else {
            NSSound.beep()
        }
    }

    private func startSpin(from phase: CGFloat) {
        spinTimer?.invalidate()
        spinPhase = phase
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.spinPhase *= 0.62
            if abs(self.spinPhase) < 0.02 { self.spinPhase = 0; timer.invalidate() }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        spinTimer = t
    }

    // MARK: Details-rail navigation

    private func navigate(_ direction: OrbitNav) {
        guard let node else { NSSound.beep(); return }
        let target: XMLTreeNode?
        switch direction {
        case .parent: target = node.parent.flatMap { $0.kind == .element ? $0 : nil }
        case .previous: target = adjacentSibling(to: node, offset: -1)
        case .next: target = adjacentSibling(to: node, offset: 1)
        case .firstChild: target = ringChildren(of: node).first
        }
        if let target { onNodeClicked?(target) } else { NSSound.beep() }
    }

    private func navAvailability(for node: XMLTreeNode?) -> OrbitNavAvailability {
        guard let node else { return OrbitNavAvailability() }
        return OrbitNavAvailability(
            parent: node.parent?.kind == .element,
            previous: adjacentSibling(to: node, offset: -1) != nil,
            next: adjacentSibling(to: node, offset: 1) != nil,
            child: !ringChildren(of: node).isEmpty)
    }

    // MARK: Model helpers

    private func ringChildren(of node: XMLTreeNode) -> [XMLTreeNode] {
        StructureFilter.apply(node.children.filter { $0.kind == .element })
    }

    /// Plain-value children kept off the ring by "Structure only".
    private func hiddenValueCount(of node: XMLTreeNode) -> Int {
        node.children.filter { $0.kind == .element }.count - ringChildren(of: node).count
    }

    /// The element family the selection belongs to. Filtered to
    /// structure when the selection itself is a container; a selected
    /// plain value keeps its full family so ←/→ still walks the values.
    private func family(of node: XMLTreeNode) -> [XMLTreeNode] {
        guard let parent = node.parent else { return [] }
        let all = parent.children.filter { $0.kind == .element }
        return StructureFilter.isContainer(node) ? StructureFilter.apply(all) : all
    }

    private func siblings(of node: XMLTreeNode) -> [XMLTreeNode] {
        family(of: node).filter { $0 !== node }
    }

    private func siblingArcNodes(of node: XMLTreeNode, limit: Int) -> [XMLTreeNode] {
        let family = self.family(of: node)
        guard !family.isEmpty else { return [] }
        guard let centerIndex = family.firstIndex(where: { $0 === node }) else {
            return Array(siblings(of: node).prefix(limit))
        }
        guard family.count - 1 > limit else { return family.filter { $0 !== node } }

        // Show the nearest context on both sides instead of permanently
        // privileging the first 36 siblings. Arrow keys traverse the complete
        // family, including siblings that do not fit on the decorative arc.
        var result: [XMLTreeNode] = []
        let firstOffset = -(limit / 2)
        for offset in firstOffset...(firstOffset + limit) where offset != 0 {
            let index = ((centerIndex + offset) % family.count + family.count) % family.count
            result.append(family[index])
        }
        return result
    }

    private func adjacentSibling(to node: XMLTreeNode, offset: Int) -> XMLTreeNode? {
        let family = self.family(of: node)
        guard family.count > 1,
              let index = family.firstIndex(where: { $0 === node }) else { return nil }
        let next = ((index + offset) % family.count + family.count) % family.count
        return family[next]
    }

    private func breadcrumbChain(of node: XMLTreeNode) -> [XMLTreeNode] {
        var chain: [XMLTreeNode] = []
        var cur: XMLTreeNode? = node
        while let n = cur, n.kind == .element || n.kind == .document {
            chain.insert(n, at: 0)
            cur = n.parent
        }
        return chain
    }

    private func orbitCenter() -> NSPoint {
        NSPoint(x: canvasRect.midX, y: canvasRect.midY - 8)
    }

    private func ringRadius() -> CGFloat {
        // Width is often the limiting dimension now that Details has a
        // dedicated rail. Keep the ring clear of the breadcrumb and footer.
        min(canvasRect.width, canvasRect.height) * 0.325
    }

    private func chipCapacity() -> Int {
        guard let node else { return 6 }
        let children = ringChildren(of: node)
        guard !children.isEmpty else { return 6 }

        // Use the actual bounded card widths and chord distance, rather than
        // pretending every chip is 130 pt. This remains collision-safe when
        // the app is zoomed or element/attribute names are unusually long.
        let widest = children.reduce(CGFloat(0)) { widest, child in
            let detail = representativeAttribute(child) ?? compactPreview(child.textValue, limit: 80)
            return max(widest, chipWidth(label: child.displayLabel, detail: detail))
        }
        let requiredChord = widest + 14
        let radius = ringRadius()
        for candidate in stride(from: 12, through: 5, by: -1) {
            let chord = 2 * radius * sin(.pi / CGFloat(candidate))
            if chord >= requiredChord { return candidate }
        }
        return 5
    }

    // Past the chip capacity the ring goes DENSE (see drawDenseRing):
    // every child gets a dot + a horizontal label in two columns, so
    // the capacity becomes "how many label rows fit", not "how many
    // chips fit". Since v0.44.2 every child is shown, even 50 of them,
    // rather than collapsing the overflow into groups.
    private let denseMinPitch: CGFloat = 13

    private func usesDenseRing() -> Bool {
        guard let node else { return false }
        return ringChildren(of: node).count > chipCapacity()
    }

    /// Vertical band the label columns may use: below the breadcrumb and
    /// sibling lane, above the footer controls.
    private func denseLabelLane() -> NSRect {
        let bottom = canvasRect.minY + 40
        let top = canvasRect.maxY - 76
        return NSRect(x: canvasRect.minX, y: bottom,
                      width: canvasRect.width, height: max(1, top - bottom))
    }

    /// Tighter than the chip ring so the columns get room; never inside
    /// the sun.
    private func denseRingRadius() -> CGFloat {
        max(118, min(ringRadius(), canvasRect.width * 0.21, denseLabelLane().height * 0.40))
    }

    private func currentRingRadius() -> CGFloat {
        usesDenseRing() ? denseRingRadius() : ringRadius()
    }

    private func denseCapacity() -> Int {
        max(2, Int(denseLabelLane().height / denseMinPitch) * 2)
    }

    private func ringCapacity() -> Int {
        guard let node else { return 6 }
        let count = ringChildren(of: node).count
        let chips = chipCapacity()
        return count <= chips ? chips : max(chips, denseCapacity())
    }

    private func representativeAttribute(_ node: XMLTreeNode) -> String? {
        // Showing the first populated parser attribute is deterministic and
        // works for future schemas without assuming a special attribute name.
        guard let attribute = node.attributes.first(where: { !$0.value.isEmpty })
                ?? node.attributes.first else { return nil }
        return "\(attribute.name)=\"\(compactPreview(attribute.value, limit: 80))\""
    }

    private func compactPreview(_ text: String, limit: Int) -> String {
        let sample = text.prefix(limit + 1)
        guard sample.count > limit else { return String(sample) }
        return String(sample.prefix(limit)) + "…"
    }

    private func maximumChipWidth() -> CGFloat {
        min(174, max(112, canvasRect.width * 0.26))
    }

    private func chipWidth(label: String, detail: String) -> CGFloat {
        let labelFont = OrbitTypography.mono(11, .medium)
        let detailFont = OrbitTypography.ui(9.5, .regular)
        let safeLabel = compactPreview(label, limit: 100)
        let safeDetail = compactPreview(detail, limit: 100)
        let labelWidth = (safeLabel as NSString).size(withAttributes: [.font: labelFont]).width
        let detailWidth = (safeDetail as NSString).size(withAttributes: [.font: detailFont]).width
        return min(maximumChipWidth(), max(96, max(labelWidth, detailWidth) + 24))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        hitRegions.removeAll()
        infoCardRect = .zero

        // Deep-space ground + aurora glow behind the sun.
        XMColor.bgDeep.setFill()
        bounds.fill()

        // A single quiet divider separates the interactive map from the
        // native, scrollable data rail.
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: canvasRect.maxX + 0.5, y: bounds.minY))
        divider.line(to: NSPoint(x: canvasRect.maxX + 0.5, y: bounds.maxY))
        divider.lineWidth = 1
        XMColor.hairlineS.setStroke()
        divider.stroke()

        guard let node else { drawPlaceholder(); return }

        let center = orbitCenter()

        if let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [XMColor.syntaxTag.withAlphaComponent(0.16).cgColor,
                     XMColor.accent.withAlphaComponent(0.05).cgColor,
                     XMColor.bgDeep.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 0.4, 1]) {
            ctx.drawRadialGradient(grad,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: min(canvasRect.width, canvasRect.height) * 0.58,
                options: [])
        }

        drawSiblingArc(around: node, center: center)
        drawChildRing(around: node, center: center)
        drawSun(node, center: center)
        drawBreadcrumb(for: node)
        drawFooter(for: node)
        drawInfoCard()
    }

    // The selected element, a glass disc with tag, counts and key
    // attributes inside.
    private func drawSun(_ node: XMLTreeNode, center: NSPoint) {
        let r: CGFloat = 96
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // Disc + double ring.
        let disc = NSBezierPath(ovalIn: rect)
        XMColor.panel.withAlphaComponent(0.92).setFill()
        disc.fill()
        XMColor.syntaxTag.withAlphaComponent(0.75).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
        XMColor.glassTop.setStroke()
        let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 7, dy: 7))
        inner.lineWidth = 1
        inner.stroke()

        // Tag name. Long names are genuinely clipped with a middle ellipsis;
        // the old code only changed the starting x coordinate and then drew
        // outside the sun.
        let elementName = "<\(node.displayLabel)>"
        let largeFont = OrbitTypography.mono(16, .semibold)
        let nameFont = (elementName as NSString).size(withAttributes: [.font: largeFont]).width > r * 1.7
            ? OrbitTypography.mono(12, .semibold) : largeFont
        drawSingleLine(elementName,
                       in: NSRect(x: center.x - r * 0.84, y: center.y + 12,
                                  width: r * 1.68, height: 20),
                       font: nameFont, color: XMColor.syntaxTag,
                       lineBreakMode: .byTruncatingMiddle)

        // Counts.
        let kidCount = node.children.filter { $0.kind == .element }.count
        let attributeWord = node.attributes.count == 1 ? "attr" : "attrs"
        let childWord = kidCount == 1 ? "child" : "children"
        let stats = "\(node.attributes.count) \(attributeWord) · \(kidCount) \(childWord)"
        drawSingleLine(stats,
                       in: NSRect(x: center.x - r * 0.82, y: center.y - 6,
                                  width: r * 1.64, height: 16),
                       font: OrbitTypography.caption, color: XMColor.text3,
                       lineBreakMode: .byTruncatingTail)

        // Two quiet summaries live inside the sun; the adjacent Details rail
        // explicitly exposes every row. A count below prevents this preview
        // from ever looking like the complete attribute set.
        var y: CGFloat = center.y - 26
        for attr in node.attributes.prefix(2) {
            let line = "\(attr.name)=\"\(attr.value)\""
            drawSingleLine(line,
                           in: NSRect(x: center.x - r * 0.79, y: y,
                                      width: r * 1.58, height: 14),
                           font: OrbitTypography.mono(10, .regular), color: XMColor.text2,
                           lineBreakMode: .byTruncatingMiddle)
            y -= 15
        }
        if node.attributes.count > 2 {
            drawSingleLine("+\(node.attributes.count - 2) more in Details",
                           in: NSRect(x: center.x - r * 0.75, y: y - 1,
                                      width: r * 1.5, height: 13),
                           font: OrbitTypography.ui(9, .medium), color: XMColor.accent,
                           lineBreakMode: .byTruncatingTail)
        }

        hitRegions.append(HitRegion(rect: rect, node: node, key: "sun"))
    }

    // Children as chips on the orbit ring, windowed + rotated by the
    // scroll wheel when there are more than fit.
    private func drawChildRing(around node: XMLTreeNode, center: NSPoint) {
        let kids = ringChildren(of: node)
        guard !kids.isEmpty else { return }

        let capacity = ringCapacity()
        let shown = min(kids.count, capacity)
        if usesDenseRing() {
            drawDenseRing(around: node, center: center, kids: kids, shown: shown)
            return
        }
        let radius = ringRadius()

        // Orbit line.
        let orbit = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        orbit.lineWidth = 1
        XMColor.hairline.setStroke()
        orbit.setLineDash([2, 5], count: 2, phase: 0)
        orbit.stroke()

        let slotAngle = 2 * .pi / CGFloat(shown)
        let spinOffset = spinPhase * slotAngle
        let appear = easeOut(appearProgress)

        for i in 0..<shown {
            let kid = kids[(ringStart + i) % kids.count]
            // Slot 0 at the bottom, filling counter-clockwise, keeps
            // the "next" child arriving where the eye expects it.
            let angle = -.pi / 2 + CGFloat(i) * slotAngle + spinOffset
            let dist = radius * (0.82 + 0.18 * appear)
            let pt = NSPoint(x: center.x + dist * cos(angle),
                             y: center.y + dist * sin(angle))
            drawChip(at: pt,
                     label: kid.displayLabel,
                     detail: representativeAttribute(kid) ?? compactPreview(kid.textValue, limit: 80),
                     accentColor: XMColor.syntaxText,
                     alpha: appear,
                     node: kid,
                     key: "child-\(kid.id)")
        }
    }

    // MARK: Dense ring, every child visible

    // Chips look great up to about a dozen children. Past that EVERY
    // child still has to be on screen at once, even 50 of them, rather
    // than collapsed into groups, so the ring goes dense: a dot per
    // child on the orbit and its label in one of two columns beside the
    // ring, leader-lined to its dot. Labels stay horizontal, are sorted
    // by height so leaders never cross, and every child is one click
    // away. Sun, sibling arc and breadcrumb are unchanged.
    private func drawDenseRing(around node: XMLTreeNode, center: NSPoint,
                               kids: [XMLTreeNode], shown: Int) {
        let radius = denseRingRadius()
        let orbit = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        orbit.lineWidth = 1
        XMColor.hairline.setStroke()
        orbit.setLineDash([2, 5], count: 2, phase: 0)
        orbit.stroke()

        struct Item { let kid: XMLTreeNode; let angle: CGFloat; let dot: NSPoint }
        let slotAngle = 2 * .pi / CGFloat(shown)
        var items: [Item] = []
        for i in 0..<shown {
            let kid = kids[(ringStart + i) % kids.count]
            let angle = -.pi / 2 + CGFloat(i) * slotAngle
            items.append(Item(kid: kid, angle: angle,
                              dot: NSPoint(x: center.x + radius * cos(angle),
                                           y: center.y + radius * sin(angle))))
        }
        let sameTag = Set(kids.map { $0.name }).count == 1
        let lane = denseLabelLane()
        let appear = easeOut(appearProgress)
        let right = items.filter { cos($0.angle) >= 0 }.sorted { $0.dot.y > $1.dot.y }
        let left = items.filter { cos($0.angle) < 0 }.sorted { $0.dot.y > $1.dot.y }

        func column(_ list: [Item], onRight: Bool) {
            guard !list.isEmpty else { return }
            let pitch = min(28, lane.height / CGFloat(list.count))
            let rowH = max(12, min(22, pitch - 2))
            let font = OrbitTypography.mono(rowH >= 17 ? 10 : 9, .medium)
            let outerX = onRight ? canvasRect.maxX - 14 : canvasRect.minX + 14
            // Halve the stand-off on a narrow canvas, or the column
            // collapses to nothing while the gap off the ring stays wide.
            let wide = onRight ? center.x + radius + 34 : center.x - radius - 34
            let standOff: CGFloat = abs(outerX - wide) < 96 ? 17 : 34
            let innerX = onRight ? center.x + radius + standOff : center.x - radius - standOff
            let width = max(24, abs(outerX - innerX))
            let blockH = pitch * CGFloat(list.count)
            // Centre the block on the ring, but keep it inside the lane.
            let top = min(lane.maxY, max(lane.minY + blockH, center.y + blockH / 2))
            var rowCenter = top - pitch / 2
            for item in list {
                let rect = NSRect(x: onRight ? innerX : innerX - width,
                                  y: rowCenter - rowH / 2, width: width, height: rowH)
                let key = "child-\(item.kid.id)"
                let hovered = hoverKey == key

                // Leader: dot → short radial stub → the label's near edge.
                let stub = NSPoint(x: center.x + (radius + 10) * cos(item.angle),
                                   y: center.y + (radius + 10) * sin(item.angle))
                let edge = NSPoint(x: onRight ? rect.minX - 5 : rect.maxX + 5, y: rowCenter)
                let leader = NSBezierPath()
                leader.move(to: item.dot)
                leader.line(to: stub)
                leader.line(to: edge)
                leader.lineWidth = hovered ? 1.2 : 0.6
                (hovered ? XMColor.accent : XMColor.hairlineS).withAlphaComponent(appear).setStroke()
                leader.stroke()

                let dotR: CGFloat = hovered ? 4.5 : 3
                let dotRect = NSRect(x: item.dot.x - dotR, y: item.dot.y - dotR,
                                     width: dotR * 2, height: dotR * 2)
                (hovered ? XMColor.accent : XMColor.syntaxText).withAlphaComponent(appear).setFill()
                NSBezierPath(ovalIn: dotRect).fill()

                let hitRect = rect.insetBy(dx: -4, dy: -1)
                if hovered {
                    XMColor.accent.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: hitRect, xRadius: 5, yRadius: 5).fill()
                }
                drawSingleLine(denseLabel(item.kid, sameTag: sameTag),
                               in: verticallyCentered(rect, font: font),
                               font: font,
                               color: (hovered ? XMColor.text : XMColor.text2).withAlphaComponent(appear),
                               lineBreakMode: .byTruncatingMiddle,
                               alignment: onRight ? .left : .right)
                hitRegions.append(HitRegion(rect: hitRect, node: item.kid, key: key))
                hitRegions.append(HitRegion(rect: dotRect.insetBy(dx: -5, dy: -5), node: item.kid, key: key))
                rowCenter -= pitch
            }
        }
        column(right, onRight: true)
        column(left, onRight: false)
    }

    // One line per child: the key value alone when every child shares a
    // tag (33 × <region> → just the region names), else "tag · value".
    private func denseLabel(_ kid: XMLTreeNode, sameTag: Bool) -> String {
        let value = kid.attributes.first(where: { !$0.value.isEmpty })?.value
            ?? (kid.textValue.isEmpty ? "" : compactPreview(kid.textValue, limit: 60))
        if value.isEmpty { return kid.displayLabel }
        return sameTag ? value : "\(kid.displayLabel) · \(value)"
    }

    private func verticallyCentered(_ rect: NSRect, font: NSFont) -> NSRect {
        let h = ceil(font.ascender - font.descender)
        return NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
    }

    // Siblings as small dots on a wide arc across the top, present
    // but quiet. Hover names them (info card), click jumps.
    private func drawSiblingArc(around node: XMLTreeNode, center: NSPoint) {
        let allSiblings = siblings(of: node)
        guard !allSiblings.isEmpty else { return }

        // Leave a fixed safe lane for the breadcrumb even at minimum height.
        let topLimitedRadius = canvasRect.maxY - 62 - center.y
        let radius: CGFloat = usesDenseRing()
            ? denseRingRadius() + 24
            : max(ringRadius() + 28,
                  min(min(canvasRect.width, canvasRect.height) * 0.45,
                      topLimitedRadius))
        // Spread across the top 100° so they read as background stars.
        let arc: CGFloat = 100 * .pi / 180
        let arcCapacity = max(8, min(36, Int((radius * arc) / 22)))
        let sibs = siblingArcNodes(of: node, limit: arcCapacity)
        let shown = sibs.count
        let start: CGFloat = .pi / 2 + arc / 2

        for i in 0..<shown {
            let sib = sibs[i]
            let t = shown == 1 ? 0.5 : CGFloat(i) / CGFloat(shown - 1)
            let angle = start - arc * t
            let pt = NSPoint(x: center.x + radius * cos(angle),
                             y: center.y + radius * sin(angle))
            let key = "sib-\(sib.id)"
            let hovered = hoverKey == key
            let dotR: CGFloat = hovered ? 7 : 4.5
            let rect = NSRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR * 2, height: dotR * 2)
            let dot = NSBezierPath(ovalIn: rect)
            (hovered ? XMColor.accent : XMColor.text3.withAlphaComponent(0.55)).setFill()
            dot.fill()
            // Generous hit target around the small dot.
            hitRegions.append(HitRegion(
                rect: rect.insetBy(dx: -6, dy: -6), node: sib, key: key))
        }
        if allSiblings.count > shown {
            // Keep the status in the empty top-left lane; centering it under
            // the arc made text run directly through the sibling dots.
            drawSingleLine("\(shown) / \(allSiblings.count) siblings  ·  ←/→ all",
                           in: NSRect(x: canvasRect.minX + 16,
                                      y: canvasRect.maxY - 59,
                                      width: min(210, canvasRect.width * 0.36), height: 16),
                           font: OrbitTypography.caption, color: XMColor.text3,
                           lineBreakMode: .byTruncatingTail,
                           alignment: .left)
        }
    }

    // One orbit chip: rounded glass pill with tag + key detail.
    private func drawChip(at pt: NSPoint, label: String, detail: String,
                          accentColor: NSColor, alpha: CGFloat,
                          node: XMLTreeNode, key: String) {
        let hovered = hoverKey == key
        let hasDetail = !detail.isEmpty
        let w = chipWidth(label: label, detail: detail)
        let h: CGFloat = (hasDetail ? 44 : 32) * min(1.15, OrbitTypography.scale)
        let grow: CGFloat = hovered ? 3 : 0
        let rect = NSRect(x: pt.x - w / 2 - grow, y: pt.y - h / 2 - grow,
                          width: w + grow * 2, height: h + grow * 2)

        let pill = NSBezierPath(roundedRect: rect, xRadius: h / 2.8, yRadius: h / 2.8)
        XMColor.panel.withAlphaComponent((hovered ? 0.98 : 0.80) * alpha).setFill()
        pill.fill()
        (hovered ? XMColor.accent : accentColor.withAlphaComponent(0.45 * alpha)).setStroke()
        pill.lineWidth = hovered ? 1.2 : 0.8
        pill.stroke()

        let contentX = rect.minX + 9 + grow
        let contentWidth = max(1, rect.width - 18 - grow * 2)
        drawSingleLine(compactPreview(label, limit: 100),
                       in: NSRect(x: contentX,
                                  y: hasDetail ? pt.y + 1 : pt.y - 8,
                                  width: contentWidth, height: 17),
                       font: OrbitTypography.mono(11, hovered ? .semibold : .medium),
                       color: XMColor.text.withAlphaComponent(alpha),
                       lineBreakMode: .byTruncatingMiddle)
        if hasDetail {
            drawSingleLine(compactPreview(detail, limit: 100),
                           in: NSRect(x: contentX, y: pt.y - 16,
                                      width: contentWidth, height: 15),
                           font: OrbitTypography.ui(9.5, .regular),
                           color: XMColor.text3.withAlphaComponent(alpha),
                           lineBreakMode: .byTruncatingMiddle)
        }

        hitRegions.append(HitRegion(rect: rect, node: node, key: key))
    }

    // Clickable breadcrumb across the top + an "↑ parent" pill.
    private func drawBreadcrumb(for node: XMLTreeNode) {
        let chain = breadcrumbChain(of: node)
        guard !chain.isEmpty else { return }
        var x: CGFloat = 16
        let y = canvasRect.maxY - 34
        var drewEllipsis = false
        let hasParent = node.parent?.kind == .element
        let pathMaxX = canvasRect.maxX - (hasParent ? min(190, canvasRect.width * 0.31) : 16)
        // Reserve a useful lane for the selected (last) segment before
        // drawing ancestors. Without this look-ahead a long filename could
        // consume the row and reduce the current element to a bare ellipsis.
        let selectedFont = OrbitTypography.mono(11, .semibold)
        let selectedIdealWidth = (chain.last!.displayLabel as NSString)
            .size(withAttributes: [.font: selectedFont]).width
        let selectedReserve = min(max(72, selectedIdealWidth),
                                  max(72, canvasRect.width * 0.30))

        for (i, item) in chain.enumerated() {
            let isLast = i == chain.count - 1
            let key = "crumb-\(item.id)"
            let hovered = hoverKey == key
            let text = NSAttributedString(string: item.displayLabel, attributes: [
                .font: OrbitTypography.mono(11, isLast ? .semibold : .regular),
                .foregroundColor: isLast ? XMColor.syntaxTag
                    : (hovered ? XMColor.accent : XMColor.text2)])
            let size = text.size()
            if x + size.width > pathMaxX - selectedReserve, !isLast {
                // Long paths: collapse middle segments to one "…".
                if !drewEllipsis {
                    drewEllipsis = true
                    let dots = NSAttributedString(string: "… ▸ ", attributes: [
                        .font: OrbitTypography.mono(11, .regular), .foregroundColor: XMColor.text3])
                    dots.draw(at: NSPoint(x: x, y: y))
                    x += dots.size().width
                }
                continue
            }
            let availableWidth = max(1, pathMaxX - x)
            if isLast && size.width > availableWidth {
                drawSingleLine(item.displayLabel,
                               in: NSRect(x: x, y: y, width: availableWidth, height: 18),
                               font: OrbitTypography.mono(11, .semibold),
                               color: XMColor.syntaxTag,
                               lineBreakMode: .byTruncatingMiddle,
                               alignment: .left)
            } else {
                text.draw(at: NSPoint(x: x, y: y))
            }
            let drawnWidth = min(size.width, availableWidth)
            hitRegions.append(HitRegion(
                rect: NSRect(x: x - 2, y: y - 4, width: drawnWidth + 4, height: size.height + 8),
                node: item, key: key))
            x += drawnWidth
            if !isLast {
                let sep = NSAttributedString(string: "  ▸  ", attributes: [
                    .font: OrbitTypography.ui(10, .regular), .foregroundColor: XMColor.text3])
                sep.draw(at: NSPoint(x: x, y: y + 1))
                x += sep.size().width
            }
        }

        // "↑ parent" pill pinned top-right.
        if let parent = node.parent, parent.kind == .element {
            let key = "up"
            let hovered = hoverKey == key
            let labelText = "↑ \(parent.displayLabel)"
            let font = OrbitTypography.ui(11, .semibold)
            let idealWidth = (labelText as NSString).size(withAttributes: [.font: font]).width + 22
            let width = min(min(180, canvasRect.width * 0.29), max(72, idealWidth))
            let rect = NSRect(x: canvasRect.maxX - width - 12, y: y - 6,
                              width: width, height: 24)
            let pill = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            XMColor.accent.withAlphaComponent(hovered ? 0.35 : 0.16).setFill()
            pill.fill()
            XMColor.accent.withAlphaComponent(0.5).setStroke()
            pill.lineWidth = 0.8
            pill.stroke()
            drawSingleLine(labelText,
                           in: NSRect(x: rect.minX + 10, y: rect.midY - 8,
                                      width: rect.width - 20, height: 17),
                           font: font, color: hovered ? XMColor.text : XMColor.accent,
                           lineBreakMode: .byTruncatingMiddle)
            hitRegions.append(HitRegion(rect: rect, node: parent, key: key))
        }
    }

    // Footer: ring status left of center + interaction hints right.
    private func drawFooter(for node: XMLTreeNode) {
        let kids = ringChildren(of: node)
        let capacity = ringCapacity()
        let hidden = hiddenValueCount(of: node)
        let hiddenNote = hidden > 0
            ? "  ·  \(hidden) plain value\(hidden == 1 ? "" : "s") hidden" : ""
        var status = ""
        if kids.count > capacity {
            let shown = min(kids.count, capacity)
            let normalizedStart = ((ringStart % kids.count) + kids.count) % kids.count
            let end = normalizedStart + shown
            let range: String
            if end <= kids.count {
                range = "\(normalizedStart + 1)-\(end)"
            } else {
                range = "\(normalizedStart + 1)-\(kids.count), 1-\(end - kids.count)"
            }
            status = "Children \(range) of \(kids.count)\(hiddenNote)  ·  scroll or drag  ·  ⌥←/→ one slot"
        } else if !kids.isEmpty {
            let allShown = usesDenseRing() ? "  ·  all shown" : ""
            let sameTag = usesDenseRing() && Set(kids.map { $0.name }).count == 1
                ? "  ·  all <\(kids[0].name)>" : ""
            status = "\(kids.count) \(kids.count == 1 ? "child" : "children")\(allShown)\(sameTag)\(hiddenNote)  ·  ←/→ traverses siblings"
        } else {
            status = "Leaf element  ·  ←/→ traverses siblings"
        }
        let trailingReserve: CGFloat = (kids.count > capacity ? 154 : 18) + structureToggle.frame.width + 12
        drawSingleLine(status,
                       in: NSRect(x: canvasRect.minX + 16, y: 12,
                                  width: max(1, canvasRect.width - trailingReserve - 16), height: 16),
                       font: OrbitTypography.caption, color: XMColor.text3,
                       lineBreakMode: .byTruncatingTail, alignment: .left)
    }

    // Bottom-left hover card: full details without navigating.
    private func drawInfoCard() {
        guard let n = hoverNode, hoverKey != "sun" else { return }

        var lines: [(String, NSColor, NSFont)] = []
        lines.append(("<\(n.displayLabel)>", XMColor.syntaxTag, OrbitTypography.mono(12, .semibold)))
        lines.append(("lines \(n.startLine)-\(n.endLine)", XMColor.text3, OrbitTypography.caption))
        for attr in n.attributes.prefix(5) {
            lines.append(("\(attr.name) = \(attr.value.prefix(36))",
                          XMColor.text2, OrbitTypography.mono(10.5, .regular)))
        }
        if n.attributes.count > 5 {
            lines.append(("+\(n.attributes.count - 5) more, click for all in Details", XMColor.accent, OrbitTypography.caption))
        }
        if !n.textValue.isEmpty {
            lines.append(("\"\(n.textValue.prefix(36))\"", XMColor.syntaxText, OrbitTypography.mono(10.5, .regular)))
        }

        let pad: CGFloat = 12
        var w: CGFloat = 160
        let lineH: CGFloat = max(17, 15 * OrbitTypography.scale)
        for (text, _, font) in lines {
            w = max(w, (text as NSString).size(withAttributes: [.font: font]).width + pad * 2)
        }
        w = min(w, min(340, canvasRect.width - 32))
        let h = CGFloat(lines.count) * lineH + pad * 2 - 4
        let rect = NSRect(x: canvasRect.minX + 16, y: 38, width: w, height: h)
        infoCardRect = rect

        let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        XMColor.panel.withAlphaComponent(0.96).setFill()
        card.fill()
        XMColor.hairlineS.setStroke()
        card.lineWidth = 0.8
        card.stroke()

        var y = rect.maxY - pad - 12
        for (text, color, font) in lines {
            drawSingleLine(text,
                           in: NSRect(x: rect.minX + pad, y: y,
                                      width: rect.width - pad * 2, height: lineH),
                           font: font, color: color,
                           lineBreakMode: .byTruncatingMiddle,
                           alignment: .left)
            y -= lineH
        }
    }

    private func drawPlaceholder() {
        let title = NSAttributedString(string: "Nothing in orbit", attributes: [
            .font: OrbitTypography.ui(16, .semibold), .foregroundColor: XMColor.text2])
        let sub = NSAttributedString(string: "Select an element in the tree to map it here",
            attributes: [.font: OrbitTypography.ui(12, .regular), .foregroundColor: XMColor.text3])
        title.draw(at: NSPoint(x: canvasRect.midX - title.size().width / 2, y: canvasRect.midY + 4))
        sub.draw(at: NSPoint(x: canvasRect.midX - sub.size().width / 2, y: canvasRect.midY - 18))
    }

    private func drawSingleLine(_ text: String, in rect: NSRect,
                                font: NSFont, color: NSColor,
                                lineBreakMode: NSLineBreakMode,
                                alignment: NSTextAlignment = .center) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
}
