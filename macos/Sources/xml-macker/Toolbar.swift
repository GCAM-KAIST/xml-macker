import Cocoa

// Native NSToolbar with SF Symbol icons, matching the action set users
// had in the Electron version: Open, Save, Close, Recent, Undo/Redo,
// Copy/Paste, Find, Drill Up/Down, Bookmark.
//
// The toolbar is attached to the window in MainWindowController.
final class XMLMackerToolbar: NSObject, NSToolbarDelegate {
    private static let ids: [NSToolbarItem.Identifier] = [
        // Packed to the left with small fixed gaps, so the layouts sit
        // near the undo pair instead of drifting into the middle, and
        // everything still fits on one bar at 1000 points wide. Orbit
        // stands on its own before the search; the marker, a tool you
        // switch on rather than a command, sits at the far right.
        .open, .save, .close,
        .space,
        .undo, .redo,
        .space,
        .workspace, .diff,
        .space,
        .orbit,
        .space,
        .find, .quickSearch,
        .flexibleSpace,
        .marker,
    ]

    weak var target: AnyObject?
    // The Edit / Inspect / Full workspace switcher, kept so
    // MainWindowController can sync the selected segment when a mode
    // is applied from the menu or restored at launch.
    private(set) weak var workspaceSegment: NSSegmentedControl?
    // Tour anchors: the controls the first-launch tour points at.
    private(set) weak var diffButton: NSButton?
    private(set) weak var searchField: NSSearchField?
    private(set) weak var findButton: NSButton?
    private(set) weak var orbitButton: NSButton?
    private(set) weak var markerButton: NSButton?

    init(target: AnyObject) {
        self.target = target
        super.init()
    }

    func buildToolbar() -> NSToolbar {
        // .v2, bumping the identifier discards stale autosaved item
        // sets so the new Workspace switcher shows up for existing
        // installs too.
        let tb = NSToolbar(identifier: "xml-macker.MainToolbar.v5")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        tb.sizeMode = .regular
        return tb
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .open:     return item(id: .open,    symbol: "doc",               label: "Open",  sel: #selector(MainWindowController.tbOpen(_:)))
        case .save:     return item(id: .save,    symbol: "square.and.arrow.down", label: "Save", sel: #selector(MainWindowController.tbSave(_:)))
        case .close:    return item(id: .close,   symbol: "xmark.square",      label: "Close", sel: #selector(MainWindowController.tbClose(_:)))
        case .undo:     return item(id: .undo,    symbol: "arrow.uturn.backward", label: "Undo", sel: Selector(("undo:")))
        case .redo:     return item(id: .redo,    symbol: "arrow.uturn.forward", label: "Redo", sel: Selector(("redo:")))
        case .find:
            let b = NSButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find") ?? NSImage(),
                             target: target, action: #selector(MainWindowController.tbFind(_:)))
            b.bezelStyle = .texturedRounded
            b.imagePosition = .imageOnly
            b.toolTip = "Find & Replace"
            let it = NSToolbarItem(itemIdentifier: .find)
            it.label = "Find"
            it.paletteLabel = "Find"
            it.view = b
            findButton = b
            return it
        case .marker:
            // Pen, colours, jump: one toolbar item, because three separate
            // ones cost enough padding to push Orbit into the overflow on
            // a 13-inch screen.
            //
            // The pen takes the marker out or puts it away, the ⌄ opens the
            // colours, the eraser and Remove All Marks (a right-click on the
            // pen does the same, but nobody can see a right-click), and the
            // ⌄ in a circle walks the marks, shift-click for the one before.
            func markerButtonView(_ symbol: String, _ tip: String, _ sel: Selector, width: CGFloat) -> NSButton {
                let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                                 target: target, action: sel)
                b.bezelStyle = .texturedRounded
                b.imagePosition = .imageOnly
                b.toolTip = tip
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: width).isActive = true
                return b
            }
            let pen = markerButtonView("highlighter",
                                       "Marker pen: drag over words to mark them",
                                       #selector(MainWindowController.tbMarker(_:)), width: 34)
            pen.setButtonType(.pushOnPushOff)
            let colours = markerButtonView("chevron.down",
                                           "Marker colours, the eraser, and Remove All Marks",
                                           #selector(MainWindowController.tbMarkerMenu(_:)), width: 24)
            let jump = markerButtonView("chevron.down.circle",
                                        "Go to the next marked text. Shift-click for the previous one.",
                                        #selector(MainWindowController.tbMarkerJump(_:)), width: 30)
            let row = NSStackView(views: [pen, colours, jump])
            row.orientation = .horizontal
            row.spacing = 0
            let it = NSToolbarItem(itemIdentifier: .marker)
            it.label = "Marker"
            it.paletteLabel = "Marker"
            it.view = row
            markerButton = pen
            return it
        case .orbit:
            // The app's own mark (Icon Set, variant C: two levels of nesting),
            // drawn in code so it stays crisp at every size and theme.
            let b = NSButton(image: OrbitIcon.image(pointSize: 18), target: target,
                             action: #selector(MainWindowController.tbOrbit(_:)))
            b.bezelStyle = .texturedRounded
            b.imagePosition = .imageOnly
            b.toolTip = "Orbit"
            let it = NSToolbarItem(itemIdentifier: .orbit)
            it.label = "Orbit"
            it.paletteLabel = "Orbit"
            it.view = b
            orbitButton = b
            return it
        case .diff:
            // Text button: DIFF reads better than an arrow glyph.
            let b = NSButton(title: "DIFF", target: target,
                             action: #selector(MainWindowController.tbDiff(_:)))
            b.bezelStyle = .texturedRounded
            b.font = XMFont.ui(11, .bold)
            b.toolTip = "Compare two files side by side (git-style diff)"
            diffButton = b
            let it = NSToolbarItem(itemIdentifier: .diff)
            it.label = "Diff"
            it.paletteLabel = "Diff"
            it.view = b
            return it
        case .drillUp:  return item(id: .drillUp, symbol: "chevron.up",        label: "Up",    sel: #selector(MainWindowController.tbDrillUp(_:)))
        case .drillDown:return item(id: .drillDown,symbol: "chevron.down",      label: "Down",  sel: #selector(MainWindowController.tbDrillDown(_:)))
        case .quickSearch:
            // Always-visible simple search field (no arrows/Done/
            // Replace clutter), Return jumps to the next occurrence.
            let field = NSSearchField()
            field.placeholderString = "Search file…"
            field.target = target
            field.action = #selector(MainWindowController.quickSearchAction(_:))
            field.sendsWholeSearchString = true
            field.controlSize = .regular
            field.translatesAutoresizingMaskIntoConstraints = false
            // Wide enough to read a search term, narrow enough that the
            // whole bar still fits on a 13-inch screen without pushing
            // Orbit into the overflow menu.
            let w = field.widthAnchor.constraint(equalToConstant: 150)
            w.priority = .defaultHigh
            w.isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            searchField = field
            let it = NSToolbarItem(itemIdentifier: .quickSearch)
            it.label = "Search"
            it.paletteLabel = "Search"
            it.toolTip = "Quick find, press Return to jump to the next match"
            it.view = field
            return it
        case .workspace:
            // Workspace switcher: one click re-arranges the WHOLE
            // window for the task at hand instead of leaving six pane
            // dividers to drag by hand every time the task changes.
            // Edit = tree + big source; Inspect = adds
            // the inspector column; Full = every pane.
            // "Simple", not "Edit": every layout lets you edit, so the old
            // name suggested the others were read-only. The internal mode,
            // the saved setting and the shortcuts are untouched.
            let seg = NSSegmentedControl(labels: ["Simple", "Inspect", "Full", "Learn"],
                                         trackingMode: .selectOne,
                                         target: target,
                                         action: #selector(MainWindowController.workspaceSegmentChanged(_:)))
            seg.segmentStyle = .capsule
            seg.selectedSegment = 2
            seg.setToolTip("Simple: the tree, a wide source editor and the subtags strip", forSegment: 0)
            seg.setToolTip("Inspect: adds the details rail, inspector, chart, preview and errors", forSegment: 1)
            seg.setToolTip("Full: every pane on screen at once", forSegment: 2)
            seg.setToolTip("Learn: the tree, the source and an AI chat beside them", forSegment: 3)
            workspaceSegment = seg
            let it = NSToolbarItem(itemIdentifier: .workspace)
            it.label = "Layout"
            it.paletteLabel = "Layout"
            it.toolTip = "Layout: how many panes are on screen"
            it.view = seg
            return it
        default: return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.ids + [.space, .flexibleSpace]
    }

    // MARK: helpers

    private func item(id: NSToolbarItem.Identifier,
                      symbol: String,
                      label: String,
                      sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        it.isBordered = true
        it.action = sel
        it.target = target
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            it.image = img
        }
        return it
    }
}

extension NSToolbarItem.Identifier {
    static let open      = NSToolbarItem.Identifier("xml-macker.open")
    static let save      = NSToolbarItem.Identifier("xml-macker.save")
    static let close     = NSToolbarItem.Identifier("xml-macker.close")
    static let undo      = NSToolbarItem.Identifier("xml-macker.undo")
    static let redo      = NSToolbarItem.Identifier("xml-macker.redo")
    static let find      = NSToolbarItem.Identifier("xml-macker.find")
    static let drillUp   = NSToolbarItem.Identifier("xml-macker.drillUp")
    static let drillDown = NSToolbarItem.Identifier("xml-macker.drillDown")
    static let orbit     = NSToolbarItem.Identifier("xml-macker.orbit")
    static let diff      = NSToolbarItem.Identifier("xml-macker.diff")
    static let workspace = NSToolbarItem.Identifier("xml-macker.workspace")
    static let quickSearch = NSToolbarItem.Identifier("xml-macker.quickSearch")
    static let marker      = NSToolbarItem.Identifier("xml-macker.marker")
    static let markerJump  = NSToolbarItem.Identifier("xml-macker.markerJump")
}
