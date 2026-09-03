import Cocoa
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    private let treeVC = TreeViewController()
    let sourceVC = SourceViewController()
    private let inspectorVC = InspectorViewController()
    let statusLabel = NSTextField(labelWithString: "Open a file (⌘O)")
    private let statusProgressFill = CALayer()   // accent fill for progress
    private var progressTimer: Timer?
    // Excel-style global zoom slider (bottom-right of status bar).
    // Drives XMFont.globalScale; on change we broadcast rebuildFonts()
    // to every VC so text across the whole app rescales uniformly.
    private let zoomSlider = NSSlider()
    private let zoomPercentLabel = NSTextField(labelWithString: "100%")
    private let zoomMinusButton = NSButton()
    private let zoomPlusButton = NSButton()
    private let zoomResetButton = NSButton()
    // Kept so the running parse can be polled for real progress.
    private weak var activeParser: XMLStreamParser?
    // Total line count for the currently-loading file, populated on
    // the bg queue via a newline scan before the parser runs. Progress
    // = activeParser.currentLineNumber / totalLinesForProgress.
    private var totalLinesForProgress: Int = 0
    // Stored layout constraints so the global zoom slider can rescale
    // the window chrome (tab strip, breadcrumb, status bar, minimap
    // width) together with fonts. These all use XMMetric.s() at
    // rebuildAllFonts time.
    private var tabStripHeightCon: NSLayoutConstraint?
    private var breadcrumbHeightCon: NSLayoutConstraint?
    private var statusBarHeightCon: NSLayoutConstraint?
    private var currentFileURL: URL?
    // Chrome-style tabs (v0.35.0): one DocumentSession per open file.
    // The active tab's canonical state lives in the live UI; parked
    // sessions hold their snapshot (see DocumentSession.swift).
    var sessions: [DocumentSession] = []
    var activeSessionIdx: Int = -1
    private struct OpenRequest {
        let url: URL
        let forceReload: Bool
    }
    private struct FileFingerprint: Equatable {
        let byteCount: UInt64
        let modificationDate: Date
        let fileNumber: UInt64?
    }
    // File-open callbacks currently pour their result into one live editor.
    // Serialize requests so Finder multi-open and multi-file drops cannot race
    // and attach one document's text to another document's tab.
    private var openQueue: [OpenRequest] = []
    private var activeOpenRequest: OpenRequest?
    private var loadingSessionID: UUID?
    // Set when Diff was clicked with one tab open: the browsed file
    // loads as a new tab, then the diff opens automatically.
    private var pendingDiffLeft: DocumentSession?
    // Unsaved-changes tracking for the ACTIVE tab + the user's
    // remembered answer to "save before sharing?" (per app run).
    private var docDirty = false
    private var activeEditRevision: UInt64 = 0
    private var savingSessionIDs: Set<UUID> = []
    private var terminationApproved = false
    private var allowNextMainWindowClose = false
    enum ShareUnsavedChoice { case saveFirst, shareDisk }
    private var rememberedShareChoice: ShareUnsavedChoice?
    private var currentTree: XMLTreeNode?
    private var toolbarHelper: XMLMackerToolbar?
    private var mainSplit: NSSplitView!
    private weak var currentSelectedNode: XMLTreeNode?

    // Aurora UI chrome
    private let tabStrip = TabStripView()
    private let breadcrumb = BreadcrumbBar()
    let minimap = MinimapView()
    /// The marker button in the toolbar, tinted with the current colour.
    weak var markerButton: NSButton?
    // Whole-file index of "every element at this depth with this tag",
    // rebuilt with the tree and used to aim the minimap's magnet lane.
    // See LevelIndex for why the lane used to be stuck inside one region.
    private var levelIndex: LevelIndex?
    /// The level the lane is currently aimed at. Kept across a reparse
    /// so a rebuild does not throw the user back to the top of the file.
    private var magnetLevel: XMLLevel?
    private var magnetFollowTimer: Timer?
    /// Set while the app is moving the caret itself, so selecting in the
    /// tree does not bounce straight back into the caret-follow and redo
    /// the aiming that was just done.
    private var suppressMagnetFollow = false
    private let orbitWindow = OrbitWindowController()
    private let subtagsBarVC = SubtagsBarViewController()
    private let hierarchyBarVC = HierarchyBarViewController()
    private let previewPaneVC = PreviewPaneViewController()
    private let errorsPaneVC = ErrorsPaneViewController()
    // Red count bubble on the Details rail's Errors segment.
    private let errorBadge = ErrorBadgeView()
    private var previewPane: PreviewPaneViewController? { previewPaneVC }
    // Standalone Chart pane (v0.23.0), was embedded in the Inspector.
    private let chartPaneVC = ChartPaneViewController()
    private var topHSplit: NSSplitView!  // [source | one detail rail]
    private var rootVSplit: NSSplitView! // [topHSplit / subtags / hierarchy]
    // Kept as a split-view container so the existing View/Layout commands can
    // hide, restore, and reorder the rail. It contains one pane only; the
    // Inspector / Chart / Preview selector swaps content inside that pane.
    private var inspectorColumnSplit: NSSplitView!

    // Pane wrappers, each pane is wrapped in a PaneChrome (title bar
    // with close/minimize/maximize buttons), which itself is wrapped
    // in a GlassPanel for the Aurora blur. The chrome is what we
    // hide/maximize/minimize; the glass stays around it.
    private var treeChrome: PaneChrome?
    private var sourceChrome: PaneChrome?
    private var inspectorChrome: PaneChrome?
    private var subtagsChrome: PaneChrome?
    private var hierarchyChrome: PaneChrome?
    private var previewChrome: PaneChrome?
    private var chartChrome: PaneChrome?
    private var chartGlass: NSView?
    // Title → (chrome, glass) map, filled by bindChrome. Used to
    // restore persisted minimized states at launch.
    private var paneRegistry: [String: (chrome: PaneChrome, glass: NSView)] = [:]
    // Kept for legacy call sites (View menu toggles, minimap width).
    private var treeGlass: NSView?
    // Source pane + minimap wrapper, kept so the Layout menu can
    // reorder it inside topHSplit (it's the only pane whose glass
    // isn't the split's direct arranged subview).
    private var sourceContainerView: NSView?
    private var sourceGlass: NSView?
    private var inspectorGlass: NSView?
    private var subtagsGlass: NSView?
    private var hierarchyGlass: NSView?
    private var previewGlass: NSView?
    private var minimapWidthCon: NSLayoutConstraint?
    private var minimapGapCon: NSLayoutConstraint?
    static let minimapVisibleKey = "xml-macker.minimapVisible"
    static var minimapVisible: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: minimapVisibleKey) == nil ? true : d.bool(forKey: minimapVisibleKey)
    }
    private static let detailSelectionKey = "xml-macker.activeDetailSection"
    private let detailTitles = ["Inspector", "Chart", "Preview", "Errors"]
    private let detailContentHost = NSView()
    private var mountedDetailTitle: String?
    private lazy var detailSelector: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: detailTitles,
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(detailSectionChanged(_:)))
        control.controlSize = .mini
        control.segmentStyle = .rounded
        // The chart (and its builder) is still settling: say so on the
        // tab, the way apps flag features that are not final yet.
        // Only the LABEL changes; "Chart" stays the key everywhere.
        if let i = detailTitles.firstIndex(of: "Chart") { control.setLabel("Chart (beta)", forSegment: i) }
        control.toolTip = "Choose the right-side detail view"
        control.setAccessibilityLabel("Right detail view")
        return control
    }()

    // Popped-out pane tracking. The green □ button now detaches the
    // pane into its own NSWindow instead of hiding siblings, that
    // avoided a split-view layout glitch (stray vertical divider
    // line) and matches user expectation better ("pop it out").
    // Pop-out bookkeeping. Everything about a detached pane lives in
    // one value struct so the dock path can't fall out of sync with
    // the window-close path, that mismatch is what caused the
    // EXC_BAD_ACCESS crash in v0.13.2 (two separate dicts + a
    // re-entrant window.close() inside windowWillClose).
    private struct PopoutEntry {
        let glass: NSView
        let chrome: PaneChrome
        let window: NSWindow
        let originSplit: NSSplitView
        let originIndex: Int
        let originExtent: CGFloat   // width for vertical split, height for horizontal
    }
    private var popouts: [ObjectIdentifier: PopoutEntry] = [:]
    // Guard against re-entering dockPane while we're already in the
    // middle of closing a window (NSWindow.close triggers another
    // windowWillClose synchronously on some AppKit code paths).
    private var docking: Set<ObjectIdentifier> = []
    // Remembered extent before minimize, so we can restore on
    // un-minimize. Keyed by ObjectIdentifier(glass).
    private var minimizeSaved: [ObjectIdentifier: CGFloat] = [:]
    // Currently-minimized panes. Consulted by the NSSplitView min/max
    // delegate to relax the usual min constraint to header-only (≈ 26
    // pt) so the divider can actually move; otherwise the pane
    // refuses to shrink below its normal min.
    private var minimizedPanes: Set<ObjectIdentifier> = []
    private var minimizedExtent: CGFloat { max(14, XMMetric.s(26)) }
    // A side-by-side pane (the Tree) folds to a STRIP, not a header
    // bar: it must stay wide enough for the header's dots, or Auto
    // Layout breaks constraints at random and the window falls apart
    // (v0.44.4: the yellow minimize button on the Tree used to wreck
    // the window). Stacked panes keep the 26 pt title bar.
    private func minimizedExtent(for pane: NSView?) -> CGFloat {
        guard let pane, pane === treeGlass else { return minimizedExtent }
        return max(minimizedExtent, XMMetric.s(108))
    }

    // Separate controller for the trend chart pop-out. Shared across
    // tree-selection changes so we push a fresh series into it each
    // time handleTreeSelection runs (chart stays live, not a snapshot).
    private var chartPopout: ChartPopoutWindowController?
    private var validationWindow: ValidationWindowController?
    // Open Diff windows, so closing the document window closes them too.
    private var diffWindows: [DiffWindowController] = []
    /// Set while a file is loading for a Change ▾ on one side of a diff.
    private var pendingDiffSwap: (diff: DiffWindowController, side: DiffSide, pair: DiffPair)?
    // Last parse's errors, refreshed on every loadFile(url:) and
    // kept around so the validation window can list them on demand.
    private var lastParseErrors: [XMLStreamParser.ParseError] = []
    private var scopedLintErrors: [XMLStreamParser.ParseError] = []
    private var validationRequestID: UInt64 = 0
    private var fullValidationRequestID: UInt64 = 0
    private var treeReparseRequestID: UInt64 = 0
    private var publishedValidationSessionID: UUID?
    private var publishedValidationRevision: UInt64 = 0

    // Hold the root content view's background behind a weak ref so
    // applyTheme() can re-stroke it without re-reaching into the
    // deeply-nested buildLayout locals.
    private weak var rootBackingView: NSView?

    override init(window: NSWindow?) {
        // Chrome-style default: fill the screen's visible area (the
        // space beside the menu bar and Dock). Frame autosave below
        // still wins on later launches, the app reopens exactly as
        // the user last left it; this is only the first impression.
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 820)
        let initW = max(900, visible.width)
        let initH = max(640, visible.height)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initW, height: initH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Let AppKit pick a safe initial position on whichever screen
        // is current, with a sane minimum so the window never shrinks
        // to a sliver if the user drags the resize handle too far.
        win.minSize = NSSize(width: 720, height: 520)
        // Pull the version string from our bundle's CFBundleShortVersionString
        // so title/status always match what the .app reports, no
        // hand-editing two places when bumping. Falls back to "?" if
        // the key is missing (shouldn't happen in a built app).
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        win.title = "xml-macker v\(version)"
        win.center()
        // Remember size + position across launches, reopening the
        // app lands exactly where the user left it instead of the
        // computed default every time. (First launch: the screen-
        // proportional size above.)
        win.setFrameAutosaveName("xml-mackerMainWindow")
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        // Keep the standard titlebar opaque, fullSizeContentView
        // was letting our tab strip draw under the traffic lights.
        super.init(window: win)
        win.delegate = self
        let helper = XMLMackerToolbar(target: self)
        toolbarHelper = helper
        let tb = helper.buildToolbar()
        markerButton = helper.markerButton
        win.toolbar = tb
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unified
        }
        // The app has its own tab strip under the toolbar. Left to
        // itself macOS also shows ITS window tab bar, a second band with
        // the file name in a capsule, which read as a stray empty bar
        // above the real tabs.
        win.tabbingMode = .disallowed
        // The tab strip right under the toolbar already names the file,
        // and the status bar carries the rest. Repeating it in the title
        // bar cost about 200 points, which is what pushed Orbit and the
        // marker into the overflow menu on a smaller window.
        win.titleVisibility = .hidden
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let window else { return }
        // Apply the persisted theme's native appearance FIRST so any
        // NSVisualEffectView built during buildLayout picks the
        // matching vibrancy mode (dark vs light) instead of flashing
        // on next theme change.
        window.appearance = ThemeManager.current.appearance

        let root = XMLFileDropView(frame: window.contentView?.bounds ?? .zero)
        root.onFilesDropped = { [weak self] urls in
            self?.openFiles(urls)
        }
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = XMColor.bg.cgColor
        self.rootBackingView = root

        // --- Status strip (bottom), kept for now, also used as the
        //     centered file info line ---
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = XMColor.text3
        statusLabel.font = XMFont.uiSmall
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        // Progress fill, a CALayer painted accent-blue that slides
        // from width 0 to the bar's full width while a file is
        // parsing. Parses don't expose progress callbacks
        // (XMLParser is opaque), so this is a timed "swipe" that
        // runs during loadFile and ends when parse completes. It gives
        // the visual "something is happening" feedback.
        statusProgressFill.backgroundColor = XMColor.accent.withAlphaComponent(0.28).cgColor
        statusProgressFill.frame = .zero
        statusBar.layer?.addSublayer(statusProgressFill)
        statusBar.addSubview(statusLabel)

        // --- Zoom controls (bottom-right, Excel-style) ---
        // Layout: [−] [───slider───] [+] [100%] [↺]
        // Slider maps 0.5× … 2.0× onto a 0…100 range for precision.
        zoomMinusButton.translatesAutoresizingMaskIntoConstraints = false
        zoomMinusButton.bezelStyle = .recessed
        zoomMinusButton.isBordered = false
        zoomMinusButton.title = "−"
        zoomMinusButton.font = XMFont.ui(13, .semibold)
        zoomMinusButton.contentTintColor = XMColor.text2
        zoomMinusButton.target = self
        zoomMinusButton.action = #selector(zoomSliderMinus(_:))
        statusBar.addSubview(zoomMinusButton)

        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.minValue = 0
        zoomSlider.maxValue = 100
        zoomSlider.doubleValue = sliderValue(for: 1.0)
        zoomSlider.sliderType = .linear
        zoomSlider.controlSize = .small
        zoomSlider.numberOfTickMarks = 7   // 50, 67, 83, 100, 117, 133, 150, …
        zoomSlider.allowsTickMarkValuesOnly = false
        zoomSlider.tickMarkPosition = .below
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomSliderChanged(_:))
        // Live updating while dragging the thumb, not just on release.
        zoomSlider.isContinuous = true
        statusBar.addSubview(zoomSlider)

        zoomPlusButton.translatesAutoresizingMaskIntoConstraints = false
        zoomPlusButton.bezelStyle = .recessed
        zoomPlusButton.isBordered = false
        zoomPlusButton.title = "+"
        zoomPlusButton.font = XMFont.ui(13, .semibold)
        zoomPlusButton.contentTintColor = XMColor.text2
        zoomPlusButton.target = self
        zoomPlusButton.action = #selector(zoomSliderPlus(_:))
        statusBar.addSubview(zoomPlusButton)

        zoomPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomPercentLabel.font = XMFont.ui(11, .semibold)
        zoomPercentLabel.textColor = XMColor.text2
        zoomPercentLabel.alignment = .right
        statusBar.addSubview(zoomPercentLabel)

        zoomResetButton.translatesAutoresizingMaskIntoConstraints = false
        zoomResetButton.bezelStyle = .recessed
        zoomResetButton.isBordered = false
        zoomResetButton.title = "↺"
        zoomResetButton.font = XMFont.ui(11, .regular)
        zoomResetButton.contentTintColor = XMColor.text3
        zoomResetButton.toolTip = "Reset zoom to \(Int(XMFont.defaultScale * 100))%"
        zoomResetButton.target = self
        zoomResetButton.action = #selector(zoomSliderReset(_:))
        statusBar.addSubview(zoomResetButton)

        // --- Tab strip and breadcrumb (top) ---
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onTabCloseRequested = { [weak self] url in
            guard let self, let i = self.sessions.firstIndex(where: { $0.url == url }) else { return }
            self.closeTab(at: i)
        }
        tabStrip.onTabSelected = { [weak self] url in
            guard let self, let i = self.sessions.firstIndex(where: { $0.url == url }) else { return }
            self.switchToTab(i)
        }
        tabStrip.onCloseOtherTabs = { [weak self] url in
            guard let self else { return }
            // Back to front so the indexes stay valid.
            for i in self.sessions.indices.reversed() where self.sessions[i].url != url {
                self.closeTab(at: i)
            }
        }
        tabStrip.onPlusClicked = { [weak self] in
            self?.menuNewDocument(nil)
        }
        root.addSubview(tabStrip)

        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        breadcrumb.onSegmentClicked = { [weak self] node in
            self?.treeVC.select(node: node, expandAncestors: true)
        }
        root.addSubview(breadcrumb)

        // --- Panels wrapped in PaneChrome → GlassPanel ---
        func wrap(_ child: NSView, title: String) -> (GlassPanel, PaneChrome) {
            let chrome = PaneChrome(title: title)
            chrome.setContent(child)
            let g = GlassPanel(config: GlassConfig(radius: XMMetric.radiusCard))
            g.translatesAutoresizingMaskIntoConstraints = false
            chrome.translatesAutoresizingMaskIntoConstraints = false
            g.contentView.addSubview(chrome)
            NSLayoutConstraint.activate([
                chrome.topAnchor.constraint(equalTo: g.contentView.topAnchor),
                chrome.leadingAnchor.constraint(equalTo: g.contentView.leadingAnchor),
                chrome.trailingAnchor.constraint(equalTo: g.contentView.trailingAnchor),
                chrome.bottomAnchor.constraint(equalTo: g.contentView.bottomAnchor),
            ])
            return (g, chrome)
        }

        let (treeGlass, treeChrome)           = wrap(treeVC.view,       title: "Tree")
        let (sourceGlass, sourceChrome)       = wrap(sourceVC.view,     title: "Source")
        let (inspectorGlass, inspectorChrome) = wrap(inspectorVC.view,  title: "Inspector")
        let (subtagsGlass, subtagsChrome)     = wrap(subtagsBarVC.view, title: "Subtags")
        let (hierarchyGlass, hierarchyChrome) = wrap(hierarchyBarVC.view, title: "Hierarchy")
        let (previewGlass, previewChrome)     = wrap(previewPaneVC.view, title: "Preview")
        let (chartGlass, chartChrome)         = wrap(chartPaneVC.view, title: "Chart")
        self.chartGlass = chartGlass
        self.chartChrome = chartChrome
        self.treeGlass = treeGlass
        self.sourceGlass = sourceGlass
        self.inspectorGlass = inspectorGlass
        self.subtagsGlass = subtagsGlass
        self.hierarchyGlass = hierarchyGlass
        self.previewGlass = previewGlass
        self.treeChrome = treeChrome
        self.sourceChrome = sourceChrome
        self.inspectorChrome = inspectorChrome
        self.subtagsChrome = subtagsChrome
        self.hierarchyChrome = hierarchyChrome
        self.previewChrome = previewChrome

        // Wire chrome actions per pane. Close uses the same togglePane
        // path as the View menu so state stays in sync. Maximize and
        // minimize are orchestrated by MainWindowController.
        func bindChrome(_ chrome: PaneChrome, glass: NSView, title: String) {
            chrome.onClose    = { [weak self] in self?.togglePane(view: glass) }
            // Green = EXPAND (macOS meaning), grows the pane inside
            // its column; pop-out moved to the dedicated ↗ button.
            chrome.onMaximize = { [weak self] in self?.toggleExpand(chrome: chrome, glass: glass, title: title) }
            chrome.onPopOut   = { [weak self] in self?.togglePopOut(chrome: chrome, glass: glass, title: title) }
            chrome.onMinimize = { [weak self] in self?.toggleMinimize(chrome: chrome, glass: glass, title: title) }
            paneRegistry[title] = (chrome, glass)
        }
        bindChrome(treeChrome,     glass: treeGlass,     title: "Tree")
        treeChrome.hidesTitleWhenMinimized = true
        bindChrome(sourceChrome,   glass: sourceGlass,   title: "Source")
        bindChrome(inspectorChrome, glass: inspectorGlass, title: "Inspector")
        bindChrome(subtagsChrome,  glass: subtagsGlass,  title: "Subtags")
        bindChrome(hierarchyChrome, glass: hierarchyGlass, title: "Hierarchy")
        bindChrome(previewChrome,  glass: previewGlass,  title: "Preview")
        bindChrome(chartChrome,    glass: chartGlass,    title: "Chart")
        inspectorChrome.setHeaderAccessory(detailSelector)
        inspectorChrome.setHeaderControlsHidden(true)
        // Errors badge rides the top-right corner of the last segment
        // ("Errors"): a red circle above the tab title signals there is
        // something to look at, so the tab is worth clicking.
        inspectorChrome.headerView.addSubview(errorBadge)
        NSLayoutConstraint.activate([
            errorBadge.centerXAnchor.constraint(equalTo: detailSelector.trailingAnchor, constant: -7),
            errorBadge.centerYAnchor.constraint(equalTo: detailSelector.topAnchor, constant: 2),
        ])
        errorsPaneVC.onErrorCountChanged = { [weak self] count in self?.errorBadge.count = count }
        detailContentHost.translatesAutoresizingMaskIntoConstraints = false
        inspectorChrome.setContent(detailContentHost)
        // Chart and Preview are tabs of the one detail rail, not independent
        // split panes. Keeping them out of paneRegistry prevents View-menu or
        // workspace code from accidentally recreating the old three-stack.
        paneRegistry.removeValue(forKey: "Chart")
        paneRegistry.removeValue(forKey: "Preview")

        // Source + minimap container (minimap docked on the right)
        let sourceContainer = NSView()
        self.sourceContainerView = sourceContainer
        sourceContainer.translatesAutoresizingMaskIntoConstraints = false
        minimap.translatesAutoresizingMaskIntoConstraints = false
        sourceContainer.addSubview(sourceGlass)
        sourceContainer.addSubview(minimap)
        NSLayoutConstraint.activate([
            sourceGlass.topAnchor.constraint(equalTo: sourceContainer.topAnchor),
            sourceGlass.leadingAnchor.constraint(equalTo: sourceContainer.leadingAnchor),
            sourceGlass.bottomAnchor.constraint(equalTo: sourceContainer.bottomAnchor),
            minimap.topAnchor.constraint(equalTo: sourceContainer.topAnchor),
            minimap.trailingAnchor.constraint(equalTo: sourceContainer.trailingAnchor),
            minimap.bottomAnchor.constraint(equalTo: sourceContainer.bottomAnchor),
        ])
        let mmWidth = minimap.widthAnchor.constraint(equalToConstant: XMMetric.s(XMMetric.minimapW))
        mmWidth.isActive = true
        self.minimapWidthCon = mmWidth
        let mmGap = sourceGlass.trailingAnchor.constraint(equalTo: minimap.leadingAnchor,
                                                          constant: -XMMetric.paneGap)
        self.minimapGapCon = mmGap
        mmGap.isActive = true
        minimap.onHide = { [weak self] in self?.setMinimapVisible(false) }

        // Source's visible card is nested with the minimap inside this
        // container, so split-view operations must move the container, not the
        // inner glass card. The old callbacks silently did nothing because the
        // card's direct parent was an ordinary NSView.
        sourceChrome.onClose = { [weak self, weak sourceContainer] in
            if let sourceContainer { self?.togglePane(view: sourceContainer) }
        }
        sourceChrome.onMaximize = { [weak self, weak sourceContainer] in
            if let sourceContainer {
                self?.toggleExpand(chrome: sourceChrome, glass: sourceContainer, title: "Source")
            }
        }
        sourceChrome.onPopOut = { [weak self, weak sourceContainer] in
            if let sourceContainer {
                self?.togglePopOut(chrome: sourceChrome, glass: sourceContainer, title: "Source")
            }
        }
        sourceChrome.onMinimize = { [weak self, weak sourceContainer] in
            if let sourceContainer {
                self?.toggleMinimize(chrome: sourceChrome, glass: sourceContainer, title: "Source")
            }
        }
        paneRegistry["Source"] = (sourceChrome, sourceContainer)

        // One conventional detail rail. Inspector, Chart, and Preview swap
        // inside the single content host above; there are no nested dividers
        // or pane-level traffic-light buttons in this column.
        let inspectorColumnSplit = NSSplitView()
        inspectorColumnSplit.isVertical = false
        inspectorColumnSplit.dividerStyle = .thin
        inspectorColumnSplit.translatesAutoresizingMaskIntoConstraints = false
        inspectorColumnSplit.delegate = self
        inspectorColumnSplit.addArrangedSubview(inspectorGlass)
        self.inspectorColumnSplit = inspectorColumnSplit

        // Top horizontal split: [source+minimap | inspectorColumnSplit]
        let topHSplit = NSSplitView()
        topHSplit.isVertical = true
        topHSplit.dividerStyle = .thin
        topHSplit.translatesAutoresizingMaskIntoConstraints = false
        topHSplit.delegate = self
        topHSplit.addArrangedSubview(sourceContainer)
        topHSplit.addArrangedSubview(inspectorColumnSplit)
        self.topHSplit = topHSplit

        // Vertical split: [topHSplit / attributes strip]
        let rightVSplit = NSSplitView()
        rightVSplit.isVertical = false
        rightVSplit.dividerStyle = .thin
        rightVSplit.translatesAutoresizingMaskIntoConstraints = false
        rightVSplit.delegate = self
        rightVSplit.addArrangedSubview(topHSplit)
        rightVSplit.addArrangedSubview(subtagsGlass)
        rightVSplit.addArrangedSubview(hierarchyGlass)
        self.rootVSplit = rightVSplit

        // Outer horizontal split: [tree (full height) | rightVSplit]
        let mainSplit = NSSplitView()
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.delegate = self
        mainSplit.addArrangedSubview(treeGlass)
        mainSplit.addArrangedSubview(rightVSplit)
        self.mainSplit = mainSplit

        root.addSubview(mainSplit)
        root.addSubview(statusBar)

        // Stored so the global-zoom slider can rescale the window
        // chrome together with fonts.
        let tabH = tabStrip.heightAnchor.constraint(equalToConstant: XMMetric.s(XMMetric.tabStripH))
        let crumbH = breadcrumb.heightAnchor.constraint(equalToConstant: XMMetric.s(XMMetric.breadcrumbH))
        let statusH = statusBar.heightAnchor.constraint(equalToConstant: XMMetric.s(26))
        self.tabStripHeightCon = tabH
        self.breadcrumbHeightCon = crumbH
        self.statusBarHeightCon = statusH

        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabH,

            breadcrumb.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            crumbH,

            mainSplit.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor, constant: 4),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusH,

            // Status label is centered but constrained to stop before
            // the zoom controls so long filenames truncate instead of
            // colliding with the slider.
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomMinusButton.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            // Zoom widget, right-aligned.
            zoomResetButton.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            zoomResetButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomResetButton.widthAnchor.constraint(equalToConstant: 20),

            zoomPercentLabel.trailingAnchor.constraint(equalTo: zoomResetButton.leadingAnchor, constant: -6),
            zoomPercentLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomPercentLabel.widthAnchor.constraint(equalToConstant: 38),

            zoomPlusButton.trailingAnchor.constraint(equalTo: zoomPercentLabel.leadingAnchor, constant: -2),
            zoomPlusButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomPlusButton.widthAnchor.constraint(equalToConstant: 20),

            zoomSlider.trailingAnchor.constraint(equalTo: zoomPlusButton.leadingAnchor, constant: -4),
            zoomSlider.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 140),

            zoomMinusButton.trailingAnchor.constraint(equalTo: zoomSlider.leadingAnchor, constant: -4),
            zoomMinusButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomMinusButton.widthAnchor.constraint(equalToConstant: 20),
        ])

        // Initial split proportions (deferred so the views have frames).
        // These split views intentionally do not use NSSplitView.autosaveName:
        // workspace modes, pane close/pop-out and the Layout menu all remove or
        // reorder arranged subviews. AppKit's single frame snapshot cannot
        // describe those different topologies and was overwriting Full's
        // three-pane geometry with Inspect's one-pane geometry. The explicit
        // workspace/layout preferences below are stable across launches and
        // recompute safe proportions for the current window instead.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Re-apply any saved RStudio-style pane arrangement (View
            // > Layout), reorders the splits and repositions their
            // dividers order-aware.
            self.applyPaneLayout(resetPositions: true)
            // …then the saved workspace mode (Edit / Inspect / Full)
            // on top, so the app reopens shaped for the last task.
            let savedMode = UserDefaults.standard.object(forKey: Self.workspaceModeKey) as? Int
            self.applyWorkspace(WorkspaceMode(rawValue: savedMode ?? WorkspaceMode.full.rawValue) ?? .full,
                                save: false, preserveGeometry: false)
            // …and finally the saved minimized set for the remaining panes.
            self.applySavedMinimizedPanes()
            // Restore the zoom level the user last chose.
            let savedZoom = UserDefaults.standard.double(forKey: "xml-macker.globalZoom")
            if savedZoom >= 0.5, savedZoom <= 2.0,
               abs(savedZoom - Double(XMFont.defaultScale)) > 0.001 {
                self.zoomSlider.doubleValue = self.sliderValue(for: CGFloat(savedZoom))
                self.applyGlobalScale(CGFloat(savedZoom))
            }
            // A focused detail rail replaces the impossible equal-third
            // Inspector / Chart / Preview stack. Exactly one view owns the
            // available height and the segmented control switches it.
            self.applyDetailSelection(persist: false)
            // First launch: the tour, once the window has real frames.
            if !UserDefaults.standard.bool(forKey: Self.tourShownKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.tour == nil, self.window?.isVisible == true else { return }
                    self.showTour(nil)
                }
            }
        }

        window.contentView = root

        // Dragging an element out of the tree: into the source, into the
        // Learn chat, or into another application. The item offers text
        // and a file, and whoever receives it picks.
        treeVC.dragPayload = { [weak self] node in
            guard let self, let (text, _) = self.elementText(node, cap: 40_000_000) else { return nil }
            let key = node.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })?.value
            let name = key.map { "\(node.name)_\($0)" } ?? node.name
            return (name: name, xml: text)
        }

        treeVC.onSelectNode = { [weak self] node in
            self?.handleTreeSelection(node)
        }

        // Live source → inspector sync. Fires 200 ms after the user
        // stops typing in the source editor.
        sourceVC.onSourceChanged = { [weak self] in
            self?.handleSourceEdited()
        }
        sourceVC.onDocumentMutated = { [weak self] in
            self?.markActiveDocumentChanged()
        }
        installMarker()
        sourceVC.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.updateLearnChip()
            guard !self.suppressMagnetFollow else {
                self.magnetFollowTimer?.invalidate()
                return
            }
            self.scheduleMagnetFollow()
        }
        sourceVC.onLineStartsChanged = { [weak self] starts in
            self?.minimap.updateLineStarts(starts)
        }

        // Two-way sync: when the user commits an attribute value edit
        // in the inspector, we (1) patch the source editor's text,
        // (2) update the model, (3) refresh the tree row, and
        // (4) refresh the inspector.
        inspectorVC.onAttributeEdit = { [weak self] node, attrName, newValue in
            guard let self else { return }
            let ok = self.sourceVC.applyAttrEdit(node: node, attrName: attrName, newValue: newValue)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.inspectorVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else {
                NSSound.beep()
            }
        }

        // Same flow for text-content edits (leaf <emiss-coef>0.5</emiss-coef>
        // values and the Subtags > Text column).
        inspectorVC.onTextEdit = { [weak self] node, newText in
            guard let self else { return }
            let ok = self.sourceVC.applyTextEdit(node: node, newText: newText)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.inspectorVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else {
                NSSound.beep()
            }
        }

        // Clicking a row in the Subtags table = selecting that child
        // element. Routing through treeVC.select gives us the full
        // sync for free: the outline's selection-change fires
        // onSelectNode, which goes to handleTreeSelection, which
        // updates source editor (scroll + highlight), inspector, and
        // preview.
        inspectorVC.onSubtagSelected = { [weak self] child in
            self?.treeVC.select(node: child, expandAncestors: true)
        }

        // Orbit chip clicks also go through the full tree-select path.
        orbitWindow.onNodeClicked = { [weak self] node in
            self?.treeVC.select(node: node, expandAncestors: true)
        }
        // Right-click in Orbit = quick value edit (leaf text, or the
        // element's key attribute), applied through the same verified
        // source-edit path as the inspector.
        orbitWindow.onNodeEditRequested = { [weak self] node in
            self?.orbitQuickEdit(node)
        }
        // In-place edits from Orbit's Details rail (double-click a value,
        // Apply on the text), same verified pipeline as the Inspector.
        orbitWindow.onAttributeEdit = { [weak self] node, attrName, newValue in
            guard let self else { return false }
            let ok = self.sourceVC.applyAttrEdit(node: node, attrName: attrName, newValue: newValue)
            if ok { self.afterOrbitEdit(node) }
            return ok
        }
        orbitWindow.onTextEdit = { [weak self] node, newText in
            guard let self else { return false }
            let ok = self.sourceVC.applyTextEdit(node: node, newText: newText)
            if ok { self.afterOrbitEdit(node) }
            return ok
        }

        // Attributes panel edits (lives inside the inspector now) route
        // through the same applyAttrEdit / applyTextEdit pipeline.
        inspectorVC.attributesVC.onAttributeEdit = { [weak self] node, attrName, newValue in
            guard let self else { return }
            let ok = self.sourceVC.applyAttrEdit(node: node, attrName: attrName, newValue: newValue)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.inspectorVC.attributesVC.refreshValuesOnly()
                self.subtagsBarVC.refreshValuesOnly()
                self.chartPaneVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else { NSSound.beep() }
        }
        inspectorVC.attributesVC.onTextEdit = { [weak self] node, newText in
            guard let self else { return }
            let ok = self.sourceVC.applyTextEdit(node: node, newText: newText)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.inspectorVC.attributesVC.refreshValuesOnly()
                self.subtagsBarVC.refreshValuesOnly()
                self.chartPaneVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else { NSSound.beep() }
        }

        // Subtags bar: row click = PREVIEW (highlight child in source,
        // don't change tree selection). Go button = NAVIGATE.
        // Cell edits route through the existing edit pipeline.
        subtagsBarVC.onSubtagPreview = { [weak self] child in
            // Just scroll + highlight; do NOT call treeVC.select so the
            // inspector keeps showing the parent element.
            self?.sourceVC.showElement(child)
        }
        subtagsBarVC.onSubtagSelected = { [weak self] child in
            self?.treeVC.select(node: child, expandAncestors: true)
        }
        // ↑ header button in the Subtags table: climb to the parent.
        subtagsBarVC.onGoUp = { [weak self] in
            guard let self, let cur = self.currentSelectedNode,
                  let parent = cur.parent, parent.kind == .element else { return }
            self.treeVC.select(node: parent, expandAncestors: true)
        }
        // Tree right-click context menu (v0.28.0).
        treeVC.onContextAction = { [weak self] node, action in
            self?.handleTreeContext(node: node, action: action)
        }
        // Config-style entries (../input/foo.xml) that name a real file
        // next to the document get an "Open Linked File" menu item.
        treeVC.resolveLinkedFile = { [weak self] node in
            LinkedFile.resolve(node: node, relativeTo: self?.currentFileURL)
        }
        (sourceVC.exposedTextView as? HighlightingTextView)?.linkedFileResolver = { [weak self] text in
            LinkedFile.resolve(text, relativeTo: self?.currentFileURL)
        }
        (sourceVC.exposedTextView as? HighlightingTextView)?.onOpenLinkedFile = { [weak self] url in
            self?.openFiles([url])
        }
        // Underlined, ⌘-clickable links in the source itself.
        sourceVC.linkedFileResolver = { [weak self] text in
            LinkedFile.resolve(text, relativeTo: self?.currentFileURL)
        }
        subtagsBarVC.onAttributeEdit = { [weak self] node, attrName, newValue in
            guard let self else { return }
            let ok = self.sourceVC.applyAttrEdit(node: node, attrName: attrName, newValue: newValue)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.subtagsBarVC.refreshValuesOnly()
                self.inspectorVC.attributesVC.refreshValuesOnly()
                self.chartPaneVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else { NSSound.beep() }
        }
        subtagsBarVC.onTextEdit = { [weak self] node, newText in
            guard let self else { return }
            let ok = self.sourceVC.applyTextEdit(node: node, newText: newText)
            if ok {
                self.treeVC.refreshNode(node)
                self.popTree?.refreshNode(node)
                self.subtagsBarVC.refreshValuesOnly()
                self.inspectorVC.attributesVC.refreshValuesOnly()
                self.chartPaneVC.refreshCurrent()
                self.scheduleAutoValidation()
            } else { NSSound.beep() }
        }
        // Tag rename (double-click the Tag cell in Subtags). The
        // source edit fixes the open AND close tag as one undoable
        // step, then the tree is rebuilt, the label (and every path
        // beneath it) changed, so a full reparse is the honest refresh.
        subtagsBarVC.onTagRename = { [weak self] node, newName in
            guard let self else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != node.name else { return }
            guard self.isValidXMLName(trimmed) else {
                NSSound.beep()
                self.statusLabel.stringValue = "Invalid tag name\(trimmed.isEmpty ? "" : ": \(trimmed)")"
                self.subtagsBarVC.refreshValuesOnly()
                return
            }
            if self.sourceVC.applyTagRename(node: node, newName: trimmed) {
                // pathSignature must capture the NEW name so the
                // selection survives the reparse.
                node.name = trimmed
                self.statusLabel.stringValue = "Renamed to <\(trimmed)>"
                self.reparseFromEditor()
            } else {
                NSSound.beep()
                self.statusLabel.stringValue = "Couldn't rename, close tag not found where expected"
                self.subtagsBarVC.refreshValuesOnly()
            }
        }

        // Hierarchy bar, clicking a child box routes to full navigate.
        hierarchyBarVC.onChildClicked = { [weak self] child in
            self?.treeVC.select(node: child, expandAncestors: true)
        }

        // Chart pop-out: ↗ button on the inline chart opens a
        // standalone window with bigger chart + Labels / Table /
        // Save Image / Copy controls.
        chartPaneVC.exposedTrendView.onPopoutRequested = { [weak self] in
            self?.openChartPopout()
        }
        chartPaneVC.onSeriesChanged = { [weak self] series in
            guard let self, let popout = self.chartPopout else { return }
            let path = self.currentSelectedNode.map { self.treePath(for: $0) } ?? ""
            popout.setMirroredSeries(series, path: path, node: self.currentSelectedNode, documentRoot: self.currentTree)
        }
        // "Build" pill on the inline chart: the pop-out with the Chart
        // Builder strip open for the selected element.
        chartPaneVC.exposedTrendView.onBuildRequested = { [weak self] in
            guard let self else { return }
            self.openChartPopout()
            self.chartPopout?.showBuilder(root: self.currentSelectedNode, documentRoot: self.currentTree)
        }

        // Preview pane's "Errors" tab: clicking (or pressing Return
        // on) an error row scrolls the source editor to the EXACT
        // reported line. Earlier builds routed through tree-select,
        // which landed on the containing element's START line, 
        // close, but not the line the message names. scrollToLine
        // carries the ensureLayout fix, so it's precise on huge files.
        errorsPaneVC.onErrorClicked = { [weak self] line, _ in
            self?.sourceVC.scrollToLine(line)
        }
        errorsPaneVC.onFixClicked = { [weak self] error in
            self?.applyLintFix(error)
        }

        // Magnifier click → find the deepest XML node that contains
        // the clicked line and route through treeVC.select. Using the
        // tree path (not direct scroll) means the full sync pipeline
        // runs, avoiding the half-laid-out source-editor artifacts
        // we hit when we poked at textView directly.
        minimap.onLineClicked = { [weak self] line in
            guard let self, let root = self.currentTree else { return }
            // fastDeepestNode, not findDeepestNode: the #document root
            // carries no real line span (1...1), so the recursive version
            // failed its very first guard and returned nil for every line
            // in the file. That is why clicking the minimap or a line in
            // the magnifier scrolled but never selected anything.
            if let target = self.fastDeepestNode(containing: line, in: root) {
                self.treeVC.select(node: target, expandAncestors: true)
            } else {
                // Nothing covers that line (blank tail, or a line outside
                // every element). Still move the editor there rather than
                // let the click do nothing at all.
                self.sourceVC.scrollToLine(line)
            }
        }
    }

    // Walk the tree for the deepest element whose [startLine, endLine]
    // covers `line`. Since children's ranges are strict subsets of the
    // parent's, we DFS into the first matching child until no child
    // fits, that's our target.
    // Binary-search descent for Find All path lookups, children are
    // in document order, so per level this is O(log n) instead of the
    // linear scan in findDeepestNode (5000 matches × huge regions).
    private func fastDeepestNode(containing line: Int, in node: XMLTreeNode) -> XMLTreeNode? {
        // The #document node carries no real line span (1…1), it was
        // failing this guard and every Find All path came back empty.
        if node.kind == .document {
            for child in node.children where child.kind == .element {
                if let hit = fastDeepestNode(containing: line, in: child) { return hit }
            }
            return nil
        }
        guard line >= node.startLine, line <= max(node.startLine, node.endLine) else { return nil }
        var cur = node
        descend: while true {
            let kids = cur.children
            guard !kids.isEmpty else { return cur }
            // Rightmost child whose startLine ≤ line.
            var lo = 0, hi = kids.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if kids[mid].startLine <= line { found = mid; lo = mid + 1 }
                else { hi = mid - 1 }
            }
            // Walk back over non-elements / closed-before-line kids.
            var probe = found
            while probe >= 0 {
                let k = kids[probe]
                if k.kind == .element {
                    if line >= k.startLine, line <= max(k.startLine, k.endLine) {
                        cur = k
                        continue descend
                    }
                    if max(k.startLine, k.endLine) < line { break }
                }
                probe -= 1
            }
            return cur
        }
    }

    // Collect the start lines of top-3-level elements as magnet-snap
    // targets for the minimap. Kept for the initial post-load state
    // when no node is selected yet.
    private func collectSnapLines(from root: XMLTreeNode) -> [Int] {
        var out: [Int] = []
        func walk(_ n: XMLTreeNode, depth: Int) {
            if n.kind == .element && depth >= 1 && depth <= 3 {
                out.append(n.startLine)
            }
            if depth < 3 {
                for c in n.children where c.kind == .element {
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        // The walk interleaves depths, and MinimapView binary-searches
        // its magnets, so hand them over in order.
        return out.sorted()
    }

    // Aim the minimap's magnet lane at the selection's own LEVEL.
    //
    // This replaced a version built from the selected element's
    // immediate family (parent, siblings, children). Its reach was the
    // parent's span, which on a region covered the whole file because
    // the 32 regions do, but one level down collapsed to a single
    // region: every hover snapped back into the region you were already
    // in. LevelIndex answers "every element in the file at this depth
    // with this tag" instead.
    private func updateMagnets(for node: XMLTreeNode?) {
        guard let node, let index = levelIndex else { return }
        let aimed = index.magnets(for: node)
        magnetLevel = aimed.level
        minimap.snapLines = aimed.lines
    }

    /// Rebuild the index for a freshly parsed tree and re-aim the lane.
    private func rebuildLevelIndex(for root: XMLTreeNode, selected: XMLTreeNode?) {
        let index = LevelIndex(root: root)
        levelIndex = index
        if let selected {
            updateMagnets(for: selected)
            return
        }
        // The element the lane was aimed at is gone. If its LEVEL still
        // exists in the rebuilt file, stay there rather than throwing the
        // user back to the top.
        if let keep = magnetLevel {
            let lines = index.startLines(for: keep)
            if lines.count >= 2 {
                minimap.snapLines = lines
                return
            }
        }
        magnetLevel = nil
        minimap.snapLines = collectSnapLines(from: root)
    }

    // The caret moves far more often than the tree selection does, so
    // the lane follows it on a short debounce. This deliberately never
    // calls treeVC.select: doing that from the caret would move the
    // caret again and the two would chase each other, and on a 600k-line
    // file every keystroke would rebuild the inspector, the chart and
    // the hierarchy. Only snapLines changes, and snapLines cannot move
    // the caret, so there is no path back.
    private func scheduleMagnetFollow() {
        magnetFollowTimer?.invalidate()
        let t = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.followCaretWithMagnets()
        }
        RunLoop.main.add(t, forMode: .common)
        magnetFollowTimer = t
    }

    private func followCaretWithMagnets() {
        guard let root = currentTree, let index = levelIndex else { return }
        let caret = sourceVC.exposedTextView.selectedRange().location
        guard caret >= 0 else { return }
        let line = sourceVC.lineNumber(forOffset: caret)
        guard let node = fastDeepestNode(containing: line, in: root) else { return }
        // Compare the RESOLVED level, not the node's own: on a crowded
        // level the lane climbs, so the node's raw level never equals the
        // one in use and the guard would never hold, repainting the whole
        // minimap on every caret settle.
        let aimed = index.magnets(for: node)
        guard aimed.level != magnetLevel else { return }
        magnetLevel = aimed.level
        minimap.snapLines = aimed.lines
    }

    // MARK: NSSplitViewDelegate, three split views now.
    //   mainSplit   (horizontal): 0 = tree | rightCol
    //   topHSplit   (horizontal): 0 = sourceContainer | inspector
    //   rootVSplit  (vertical):   0 = topHSplit / attributes strip

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Pane to the LEFT of this divider (index == dividerIndex).
        let left = subview(splitView.arrangedSubviews, at: dividerIndex)
        let lMin = effectiveMin(for: left, fallback:
                                splitView === mainSplit  ? XMMetric.treePaneMin :
                                splitView === topHSplit  ? 220 : 160)

        if splitView === mainSplit  { return lMin }
        if splitView === topHSplit  { return lMin }
        if splitView === inspectorColumnSplit {
            // Floors for NORMAL inspector-column panes: 200 for the
            // Inspector (below that its header + table minimums can't
            // fit and the title gets pushed out of view), 110 for the
            // Chart. Hidden (0) / minimized (26) panes keep their
            // special mins, the `< 100` guard passes those through.
            func floored(_ v: CGFloat, _ floor: CGFloat) -> CGFloat {
                v < 100 ? v : max(floor, v)
            }
            if dividerIndex == 0 { return floored(lMin, 200) }
            // Divider 1 sits below Inspector AND Chart, its minimum
            // position must leave room for both.
            let top = subview(splitView.arrangedSubviews, at: 0)
            let tMin = floored(effectiveMin(for: top, fallback: 200), 200)
            return tMin + floored(lMin, 110)
        }
        if splitView === rootVSplit {
            // Count-aware: sum the minimums of every pane at or above
            // this divider. The old fixed-index math assumed all
            // three panes were present, wrong once one is closed.
            let subs = splitView.arrangedSubviews
            var pos: CGFloat = 0
            for i in 0...min(dividerIndex, subs.count - 1) {
                pos += effectiveMin(for: subs[i], fallback: i == 0 ? 160 : 80)
            }
            return pos
        }
        return proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Pane to the RIGHT of this divider has index dividerIndex+1.
        if splitView === mainSplit {
            let right = subview(splitView.arrangedSubviews, at: dividerIndex + 1)
            let rMin = effectiveMin(for: right, fallback: XMMetric.inspectorPaneMin)
            return splitView.bounds.width - 220 - rMin
        }
        if splitView === topHSplit {
            let right = subview(splitView.arrangedSubviews, at: dividerIndex + 1)
            let rMin = effectiveMin(for: right, fallback: XMMetric.inspectorPaneMin)
            return splitView.bounds.width - rMin
        }
        if splitView === inspectorColumnSplit {
            // Divider 0 must leave room for BOTH panes beneath it
            // (chart + preview); divider 1 only for the preview.
            if dividerIndex == 0, splitView.arrangedSubviews.count >= 3 {
                let mid = subview(splitView.arrangedSubviews, at: 1)
                let bot = subview(splitView.arrangedSubviews, at: 2)
                return splitView.bounds.height
                    - effectiveMin(for: mid, fallback: 110)
                    - effectiveMin(for: bot, fallback: 120)
            }
            let right = subview(splitView.arrangedSubviews, at: dividerIndex + 1)
            let rMin = effectiveMin(for: right, fallback: 120)
            return splitView.bounds.height - rMin
        }
        if splitView === rootVSplit {
            // Count-aware: leave room for every pane actually BELOW
            // this divider (fixed indexes broke after a pane closed, 
            // they subtracted minimums for panes that were gone).
            let subs = splitView.arrangedSubviews
            var below: CGFloat = 0
            if dividerIndex + 1 < subs.count {
                for i in (dividerIndex + 1)..<subs.count {
                    below += effectiveMin(for: subs[i], fallback: 80)
                }
            }
            return splitView.bounds.height - below
        }
        return proposedMaximumPosition
    }

    // Every subview is resizable (no fixed panes).
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false
    }

    // MARK: File loading

    /// Central entry point for Open, Finder, Dock/app-icon drops and window
    /// drops. Requests are serialized because the editor is intentionally one
    /// live text view whose storage is swapped when tabs change.
    func openFiles(_ rawURLs: [URL]) {
        let canonical = XMLDocumentSupport.canonicalFileURLs(rawURLs)
        var accepted: [URL] = []
        var rejected: [URL] = []
        for url in canonical {
            if XMLDocumentSupport.isLikelyXML(url) { accepted.append(url) }
            else { rejected.append(url) }
        }

        if !rejected.isEmpty {
            let names = rejected.map(\.lastPathComponent).joined(separator: ", ")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Those files do not look like XML"
            alert.informativeText = names
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }

        for url in accepted {
            // Keep one queued request per canonical path. An already-open file
            // is still queued once so the request focuses its existing tab.
            guard !openQueue.contains(where: { $0.url == url }),
                  activeOpenRequest?.url != url else { continue }
            openQueue.append(OpenRequest(url: url, forceReload: false))
        }
        processNextOpenRequest()
    }

    func loadFile(url: URL) {
        openFiles([url])
    }

    private func reloadFile(_ rawURL: URL) {
        guard let url = XMLDocumentSupport.canonicalFileURLs([rawURL]).first else { return }
        openQueue.removeAll { $0.url == url }
        openQueue.insert(OpenRequest(url: url, forceReload: true), at: 0)
        processNextOpenRequest()
    }

    private func processNextOpenRequest() {
        guard activeOpenRequest == nil, !openQueue.isEmpty else { return }
        let request = openQueue.removeFirst()
        activeOpenRequest = request
        performOpen(request)
    }

    private func finishOpenRequest() {
        activeOpenRequest = nil
        loadingSessionID = nil
        sourceVC.onFileLoaded = nil
        sourceVC.onFileLoadFailed = nil
        DispatchQueue.main.async { [weak self] in self?.processNextOpenRequest() }
    }

    private func performOpen(_ request: OpenRequest) {
        let url = request.url

        if let existing = sessions.firstIndex(where: { $0.url == url }),
           !request.forceReload {
            if existing != activeSessionIdx { switchToTab(existing) }
            window?.makeKeyAndOrderFront(nil)
            finishOpenRequest()
            return
        }

        let session: DocumentSession
        if let existing = sessions.firstIndex(where: { $0.url == url }) {
            if existing != activeSessionIdx { switchToTab(existing) }
            guard sessions.indices.contains(activeSessionIdx) else {
                finishOpenRequest()
                return
            }
            // Keep the previous snapshot intact until both parsing and text
            // decoding succeed; a failed Revert can then restore it.
            snapshotActiveSession()
            sourceVC.detachToFreshStorage()
            session = sessions[activeSessionIdx]
        } else {
            if sessions.indices.contains(activeSessionIdx) {
                snapshotActiveSession()
                sourceVC.detachToFreshStorage()
            }
            session = DocumentSession(url: url, fileSize: 0)
            sessions.append(session)
            activeSessionIdx = sessions.count - 1
        }

        session.isLoading = true
        sourceVC.sessionUndoManager = session.undoManager
        loadingSessionID = session.id
        activeEditRevision = session.editRevision
        validationRequestID &+= 1
        fullValidationRequestID &+= 1
        treeReparseRequestID &+= 1
        docDirty = false
        terminationApproved = false
        currentFileURL = url
        currentSelectedNode = nil
        updateWindowDocumentState()

        guard let openingFingerprint = fileFingerprint(at: url) else {
            handleOpenFailure(sessionID: session.id, url: url,
                              message: "The file's metadata could not be read.")
            return
        }
        let fileSize = openingFingerprint.byteCount > UInt64(Int.max)
            ? Int.max : Int(openingFingerprint.byteCount)
        let sizeMB = Double(fileSize) / 1024 / 1024

        statusLabel.stringValue = "Parsing \(url.lastPathComponent) (\(String(format: "%.1f", sizeMB)) MB)…"
        session.fileSize = fileSize
        refreshTabStrip()
        // Real progress: we pre-scan the file for newlines on the bg
        // queue (mmap, ~1 GB/s on Apple Silicon), then poll
        // parser.currentLineNumber from the main-thread timer and
        // divide by totalLines. Replaces the old timer-based fake
        // animation, which visibly jumped at the end.
        activeParser = nil
        totalLinesForProgress = 0
        startProgressFill(estimatedSeconds: max(1.0, sizeMB * 0.03))

        // Newline scan runs CONCURRENTLY with the parse (it used to run
        // before it, delaying parse start by the full scan time on big
        // files). Both only write their results via the main queue, and
        // the progress timer falls back to the time-based estimate until
        // the scan lands, so there's no ordering requirement between
        // the two.
        let sessionID = session.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let data = try? Data(contentsOf: url, options: [.alwaysMapped, .uncached]) {
                var newlines = 1
                data.withUnsafeBytes { buf in
                    for b in buf.bindMemory(to: UInt8.self) where b == 0x0A { newlines += 1 }
                }
                DispatchQueue.main.async {
                    guard self?.loadingSessionID == sessionID else { return }
                    self?.totalLinesForProgress = newlines
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Build the parser. Publish it on main so the progress
            // timer can poll parser.currentLineNumber.
            let parser = XMLStreamParser()
            DispatchQueue.main.async {
                self?.activeParser = parser
            }
            let t0 = Date()
            let result = parser.parseFile(at: url)
            let elapsed = Date().timeIntervalSince(t0)

            DispatchQueue.main.async {
                guard let self,
                      self.loadingSessionID == sessionID,
                      self.sessions.indices.contains(self.activeSessionIdx),
                      self.sessions[self.activeSessionIdx].id == sessionID else { return }
                guard self.fileFingerprint(at: url) == openingFingerprint else {
                    self.handleOpenFailure(
                        sessionID: sessionID,
                        url: url,
                        message: "The file changed while xml-macker was parsing it. Open it again after the other write finishes."
                    )
                    return
                }
                // The root row reads as the file, not "#document".
                result.root.name = url.lastPathComponent
                self.currentTree = result.root
                self.lastParseErrors = result.errors
                // Standalone Validation window still shows the
                // whole-file parse errors, that's its whole purpose.
                // The inline Preview > Errors tab is now SCOPED to
                // the current selection, so we start it empty on
                // load and let the first-tree-select kick off a
                // scoped revalidate. This eliminates the 450-ms
                // flash of "2 errors from nowhere" on load.
                self.validationWindow?.setErrors(result.errors)
                self.errorsPaneVC.setErrors([])
                self.errorsPaneVC.setValidationScope("")
                let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
                self.window?.title = "\(url.lastPathComponent), xml-macker v\(v)"
                self.treeVC.setRoot(result.root)
                self.popTree?.setRoot(result.root)
                // Wire minimap AFTER sourceVC finishes loading text +
                // lineStarts. sourceVC.loadFile does its file read
                // asynchronously, so we can't attach immediately, 
                // currentLineStarts would still be [0]. The callback
                // fires on the main queue once applyLoadedText runs.
                self.sourceVC.onFileLoaded = { [weak self] in
                    guard let self,
                          self.loadingSessionID == sessionID,
                          let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                    guard self.fileFingerprint(at: url) == openingFingerprint else {
                        self.handleOpenFailure(
                            sessionID: sessionID,
                            url: url,
                            message: "The file changed while xml-macker was loading its source text. Open it again after the other write finishes."
                        )
                        return
                    }
                    let loadedSession = self.sessions[index]
                    loadedSession.storage = self.sourceVC.currentStorage
                    loadedSession.lineStarts = self.sourceVC.currentLineStarts
                    loadedSession.textEncoding = self.sourceVC.currentTextEncoding
                    loadedSession.tree = result.root
                    loadedSession.parseErrors = result.errors
                    loadedSession.fileModificationDate = self.fileModificationDate(at: url)
                    loadedSession.isDirty = false
                    loadedSession.editRevision = self.activeEditRevision
                    loadedSession.isLoading = false
                    self.minimap.attach(scroll: self.sourceVC.exposedScrollView,
                                        textView: self.sourceVC.exposedTextView,
                                        lineStarts: self.sourceVC.currentLineStarts)
                    self.levelIndex = LevelIndex(root: result.root)
                    self.magnetLevel = nil
                    self.minimap.snapLines = self.collectSnapLines(from: result.root)
                    if let first = result.root.children.first(where: { $0.kind == .element }) {
                        self.treeVC.select(node: first, expandAncestors: true)
                        loadedSession.selectedNode = first
                        // Fill the scoped Errors view only after source text
                        // and its line index are ready.
                        self.revalidate()
                    }
                    if let loaded = self.sessions.first(where: { $0.id == sessionID }) {
                        self.loadHighlights(for: loaded, text: self.sourceVC.documentText)
                        self.attachMarkerStrokes()
                    }
                    if let pending = self.pendingUntitledURL, pending == url {
                        self.pendingUntitledURL = nil
                        self.sessions.first(where: { $0.id == sessionID })?.isUntitled = true
                        self.refreshTabStrip()
                    } else {
                        (NSApp.delegate as? AppDelegate)?.addRecent(url)
                    }
                    self.updateWindowDocumentState()
                    if let left = self.pendingDiffLeft,
                       let right = self.sessions.first(where: { $0.id == sessionID }),
                       left !== right {
                        self.pendingDiffLeft = nil
                        self.openDiff(left: left, right: right)
                    }
                    self.tryContinuePendingDiff()
                    // A Change ▾ that had to open the file first.
                    if let swap = self.pendingDiffSwap,
                       let loaded = self.sessions.first(where: { $0.id == sessionID }),
                       let text = self.sessionText(loaded) {
                        self.pendingDiffSwap = nil
                        if swap.side == .left { swap.pair.left = loaded } else { swap.pair.right = loaded }
                        swap.diff.replaceSide(swap.side, name: loaded.url.lastPathComponent, text: text)
                    }
                    self.finishOpenRequest()
                }
                self.sourceVC.onFileLoadFailed = { [weak self] message in
                    self?.handleOpenFailure(sessionID: sessionID, url: url, message: message)
                }
                self.sourceVC.loadFile(url: url, fileSize: fileSize)

                let nodeStr = "\(result.nodeCount) nodes"
                let errStr = result.errors.isEmpty
                    ? "no errors"
                    : "\(result.errors.count) error\(result.errors.count == 1 ? "" : "s")"
                self.statusLabel.stringValue = "\(url.lastPathComponent) · \(String(format: "%.1f", sizeMB)) MB · \(nodeStr) · \(errStr) · parsed in \(String(format: "%.1f", elapsed))s"
                self.finishProgressFill()

            }
        }
    }

    private func handleOpenFailure(sessionID: UUID, url: URL, message: String) {
        guard loadingSessionID == sessionID else { return }
        pendingDiffLeft = nil
        pendingDiff = nil
        finishProgressFill()
        statusLabel.stringValue = "Could not open \(url.lastPathComponent)"

        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].isLoading = false
            if sessions[index].storage == nil || sessions[index].tree == nil {
                sessions.remove(at: index)
                activeSessionIdx = -1
                if sessions.isEmpty { showEmptyState() }
                else { activateSession(at: min(index, sessions.count - 1)) }
            } else {
                // A forced reload failed. Restore the still-intact prior text,
                // tree, dirty flag and encoding snapshot.
                activateSession(at: index)
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Couldn’t open \(url.lastPathComponent)"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                self?.finishOpenRequest()
            }
        } else {
            alert.runModal()
            finishOpenRequest()
        }
    }

    fileprivate func closeCurrentFile() {
        if sessions.indices.contains(activeSessionIdx) {
            closeTab(at: activeSessionIdx)
        } else {
            showEmptyState()
        }
    }

    // ── Tab plumbing (v0.35.0) ────────────────────────────────────

    private func refreshTabStrip() {
        tabStrip.setTabs(sessions.map { $0.url }, activeIndex: activeSessionIdx)
    }

    // Park the live UI state into the active session before leaving it.
    private func snapshotActiveSession() {
        guard sessions.indices.contains(activeSessionIdx) else { return }
        let s = sessions[activeSessionIdx]
        s.storage = sourceVC.currentStorage
        s.lineStarts = sourceVC.currentLineStarts
        s.textEncoding = sourceVC.currentTextEncoding
        s.tree = currentTree
        s.parseErrors = lastParseErrors
        s.selectedNode = currentSelectedNode
        s.scrollOrigin = sourceVC.snapshotScroll()
        s.isDirty = docDirty
        s.editRevision = activeEditRevision
    }

    private func switchToTab(_ i: Int) {
        guard i != activeSessionIdx, sessions.indices.contains(i) else { return }
        if sessions[i].isLoading ||
           (sessions.indices.contains(activeSessionIdx) && sessions[activeSessionIdx].isLoading) {
            NSSound.beep()
            statusLabel.stringValue = "Still loading, try again in a moment"
            return
        }
        snapshotActiveSession()
        activateSession(at: i)
    }

    // Pour a parked session back into the live UI.
    private func activateSession(at i: Int) {
        defer { attachMarkerStrokes() }
        guard sessions.indices.contains(i) else { return }
        let s = sessions[i]
        guard let storage = s.storage, let tree = s.tree else { NSSound.beep(); return }
        activeSessionIdx = i
        sourceVC.sessionUndoManager = s.undoManager
        sourceVC.attachSession(url: s.url, fileSize: s.fileSize, storage: storage,
                               lineStarts: s.lineStarts, scrollOrigin: s.scrollOrigin,
                               textEncoding: s.textEncoding)
        syncSourceMirror()
        currentFileURL = s.url
        currentTree = tree
        lastParseErrors = s.parseErrors
        scopedLintErrors = []
        docDirty = s.isDirty
        activeEditRevision = s.editRevision
        validationRequestID &+= 1
        fullValidationRequestID &+= 1
        treeReparseRequestID &+= 1
        treeVC.setRoot(tree)
        popTree?.setRoot(tree)
        validationWindow?.setErrors(s.parseErrors)
        minimap.attach(scroll: sourceVC.exposedScrollView,
                       textView: sourceVC.exposedTextView,
                       lineStarts: s.lineStarts)
        levelIndex = LevelIndex(root: tree)
        magnetLevel = nil
        minimap.snapLines = collectSnapLines(from: tree)
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        window?.title = "\(s.url.lastPathComponent), xml-macker v\(v)"
        updateWindowDocumentState()
        refreshTabStrip()
        if let sel = s.selectedNode {
            treeVC.select(node: sel, expandAncestors: true)
        } else if let first = tree.children.first(where: { $0.kind == .element }) {
            treeVC.select(node: first, expandAncestors: true)
        }
        // handleTreeSelection scrolled to the element, put the user
        // back exactly where they left the document.
        sourceVC.restoreScroll(s.scrollOrigin)
        statusLabel.stringValue = s.url.lastPathComponent
        // Diff copy-hunks may have edited this document while parked.
        if s.needsReparse {
            s.needsReparse = false
            reparseFromEditor()
        }
    }

    private func isSessionDirty(_ i: Int) -> Bool {
        guard sessions.indices.contains(i) else { return false }
        return i == activeSessionIdx ? docDirty : sessions[i].isDirty
    }

    private func markActiveDocumentChanged() {
        guard sessions.indices.contains(activeSessionIdx),
              !sessions[activeSessionIdx].isLoading else { return }
        docDirty = true
        activeEditRevision &+= 1
        sessions[activeSessionIdx].editRevision = activeEditRevision
        validationRequestID &+= 1
        fullValidationRequestID &+= 1
        treeReparseRequestID &+= 1
        terminationApproved = false
        updateWindowDocumentState()
        refreshTabStrip()
    }

    private func updateWindowDocumentState() {
        window?.representedURL = currentFileURL
        window?.isDocumentEdited = docDirty
    }

    @discardableResult
    private func requireReadyDocument(for action: String) -> Bool {
        guard sessions.indices.contains(activeSessionIdx),
              !sessions[activeSessionIdx].isLoading,
              activeOpenRequest == nil else {
            NSSound.beep()
            statusLabel.stringValue = "Wait for the document to finish loading before \(action)"
            return false
        }
        return true
    }

    private func closeTab(at i: Int) {
        guard sessions.indices.contains(i) else { return }
        let sessionID = sessions[i].id
        if sessions[i].isLoading || savingSessionIDs.contains(sessionID) {
            NSSound.beep()
            statusLabel.stringValue = "Wait for this file operation to finish"
            return
        }
        if i == activeSessionIdx { snapshotActiveSession() }
        // An UNTITLED document always counts as unsaved: it only exists in
        // a scratch folder, so closing it without saving loses it outright,
        // whether or not it was edited. That covers File ▸ New and an
        // element exported into its own tab.
        let untitled = sessions[i].isUntitled
        if isSessionDirty(i) || untitled {
            let sess = sessions[i]
            let alert = NSAlert()
            alert.messageText = untitled
                ? "Save the new document \(sess.url.lastPathComponent)?"
                : "Save changes to \(sess.url.lastPathComponent)?"
            alert.informativeText = untitled
                ? "It has never been saved anywhere. Closing without saving discards it."
                : "The file has unsaved changes, closing without saving loses them."
            alert.addButton(withTitle: untitled ? "Save As… and Close" : "Save and Close")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if untitled {
                    // Ask where it belongs, then close once it is there.
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = sess.url.lastPathComponent
                    panel.allowedContentTypes = []
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    saveSession(sessionID: sessionID, to: dest, updateURL: true) { [weak self] success in
                        guard success else { return }
                        self?.finishCloseTab(sessionID: sessionID)
                    }
                } else {
                    saveSession(sessionID: sessionID, to: sess.url, updateURL: false) { [weak self] success in
                        guard success else { return }
                        self?.finishCloseTab(sessionID: sessionID)
                    }
                }
                return
            case .alertSecondButtonReturn:
                // Discard the scratch copy with the tab.
                if untitled { try? FileManager.default.removeItem(at: sess.url) }
            default:
                return  // cancelled
            }
        }
        finishCloseTab(sessionID: sessionID)
    }

    private func finishCloseTab(sessionID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // The marks belong to the file, so write them out before the tab
        // and its strokes go.
        let closing = sessions[i]
        if !closing.isUntitled, i == activeSessionIdx {
            HighlightStore.save(closing.highlights, for: closing.url, text: sourceVC.documentText)
        }
        if i == activeSessionIdx {
            sessions.remove(at: i)
            activeSessionIdx = -1
            if sessions.isEmpty { showEmptyState(); return }
            activateSession(at: min(i, sessions.count - 1))
        } else {
            sessions.remove(at: i)
            if i < activeSessionIdx { activeSessionIdx -= 1 }
            refreshTabStrip()
        }
    }

    private func showEmptyState() {
        activeSessionIdx = -1
        sourceVC.sessionUndoManager = nil
        currentFileURL = nil
        currentTree = nil
        currentSelectedNode = nil
        // The magnet lane belongs to a document; drop it with the document.
        magnetFollowTimer?.invalidate()
        magnetFollowTimer = nil
        levelIndex = nil
        magnetLevel = nil
        minimap.snapLines = []
        docDirty = false
        activeEditRevision = 0
        scopedLintErrors = []
        validationRequestID &+= 1
        fullValidationRequestID &+= 1
        treeReparseRequestID &+= 1
        refreshTabStrip()
        breadcrumb.setPath([])
        let emptyRoot = XMLTreeNode(id: 0, kind: .document, name: "#document")
        treeVC.setRoot(emptyRoot)
        popTree?.setRoot(emptyRoot)
        inspectorVC.setNode(emptyRoot)
        chartPaneVC.setNode(emptyRoot)
        subtagsBarVC.setNode(emptyRoot)
        hierarchyBarVC.setNode(emptyRoot)
        previewPaneVC.updatePreview(text: "", truncated: false)
        // Fully reset the editor + error surfaces too, leaving the
        // old text in the source pane (still editable) made Close
        // File look like it hadn't worked, and stale scoped errors
        // kept pointing at lines that no longer exist.
        sourceVC.clear()
        errorsPaneVC.setErrors([])
        errorsPaneVC.setValidationScope("")
        validationWindow?.setErrors([])
        lastParseErrors = []
        autoValidateTimer?.cancel()
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        window?.title = "xml-macker v\(v)"
        updateWindowDocumentState()
        statusLabel.stringValue = "Open a file (⌘O)"
    }

    private func handleTreeSelection(_ node: XMLTreeNode) {
        let t0 = Date()
        Diag.log("handleTreeSelection begin name=\(node.name) kind=\(node.kind) line=\(node.startLine)..\(node.endLine) childCount=\(node.children.count)")
        currentSelectedNode = node
        Diag.time("  refreshAttributes(self)") { sourceVC.refreshAttributes(for: node) }
        Diag.time("  refreshTextValue(self)") { sourceVC.refreshTextValue(for: node) }
        Diag.time("  refresh children (\(node.children.count))") {
            for child in node.children where child.kind == .element {
                sourceVC.refreshAttributes(for: child)
                sourceVC.refreshTextValue(for: child)
            }
        }
        Diag.time("  inspectorVC.setNode")    { inspectorVC.setNode(node) }
        Diag.time("  chartPaneVC.setNode")    { chartPaneVC.setNode(node) }
        if let s = chartPaneVC.currentTrendSeries {
            chartPopout?.setMirroredSeries(s, path: treePath(for: node), node: node, documentRoot: currentTree)
        }
        Diag.time("  subtagsBarVC.setNode")   { subtagsBarVC.setNode(node) }
        Diag.time("  hierarchyBarVC.setNode") { hierarchyBarVC.setNode(node) }
        // Floating copies of the panes follow the selection too.
        popSubtags?.setNode(node)
        popHierarchy?.setNode(node)
        syncSourceMirror()
        popSource?.showElement(node)
        if let pt = popTree {
            mirroringSelection = true
            pt.select(node: node, expandAncestors: true)
            mirroringSelection = false
        }

        // Aim the minimap's magnet lane at this element's own level.
        updateMagnets(for: node)
        // showElement moves the caret, and NSTextView posts the selection
        // change synchronously, so hold the caret-follow off across it
        // rather than let it redo the aiming a moment later.
        suppressMagnetFollow = true
        Diag.time("  sourceVC.showElement")   { sourceVC.showElement(node) }
        suppressMagnetFollow = false

        // Breadcrumb: build ancestor path (document → ... → node).
        var path: [XMLTreeNode] = []
        var cur: XMLTreeNode? = node
        while let n = cur {
            path.insert(n, at: 0)
            cur = n.parent
        }
        breadcrumb.setPath(path)

        // Preview: absorbed into the Inspector's preview section.
        Diag.time("  preview.updatePreview") {
            if let range = sourceVC.charRangeForElement(node) {
                let (text, truncated) = sourceVC.substring(in: range, cap: 1_000_000)
                previewPaneVC.updatePreview(text: text, truncated: truncated)
            } else {
                previewPaneVC.updatePreview(text: "", truncated: false)
            }
        }

        // Refresh Orbit popup (only does work when its window exists;
        // rendering is lightweight: a single draw pass).
        if orbitWindow.window?.isVisible == true {
            orbitWindow.present(node: node)
        }

        // Kick a scoped re-validation so the Errors tab reflects the
        // NEW scope (parent of this node) even if the user hasn't
        // typed anything yet. Debounced like the edit path so rapid
        // tree navigation doesn't thrash the parser.
        scheduleAutoValidation()

        Diag.log("handleTreeSelection done in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
    }

    private func handleSourceEdited() {
        guard let node = currentSelectedNode else { return }
        if inspectorVC.isEditingCell { return }
        Diag.log("handleSourceEdited: node=\(node.name) before attrs=\(node.attributes.count)")
        sourceVC.refreshAttributes(for: node)
        sourceVC.refreshTextValue(for: node)
        for child in node.children where child.kind == .element {
            sourceVC.refreshAttributes(for: child)
            sourceVC.refreshTextValue(for: child)
        }
        Diag.log("handleSourceEdited: node=\(node.name) after attrs=\(node.attributes.count)")
        inspectorVC.refreshValuesOnly()
        subtagsBarVC.refreshValuesOnly()
        treeVC.refreshNode(node)
        popTree?.refreshNode(node)
        chartPaneVC.refreshCurrent()

        // Refresh the Inspector's preview section with the current bytes.
        if let range = sourceVC.charRangeForElement(node) {
            let (text, truncated) = sourceVC.substring(in: range, cap: 1_000_000)
            previewPaneVC.updatePreview(text: text, truncated: truncated)
        }
        scheduleAutoValidation()
    }

    // Debounced re-validate so every keystroke doesn't fire a full
    // parse of the whole buffer. Waits ~450 ms of quiet before
    // running.
    private var autoValidateTimer: DispatchWorkItem?
    private func scheduleAutoValidation() {
        autoValidateTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.revalidate()
        }
        autoValidateTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: work)
    }

    // MARK: Toolbar actions

    @objc func tbOpen(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openFile(sender)
    }

    @objc func tbSave(_ sender: Any?) {
        menuSave(sender)
    }

    // MARK: File menu handlers (Save / Save As / Revert / Close / …)
    //
    // All routed through the same save/reload pipeline so toolbar +
    // menu + keyboard shortcut stay consistent.

    // MARK: new, untitled documents

    /// Where an unsaved document lives until the user says where it
    /// belongs. A real file, so every code path that reads a document
    /// from disk keeps working exactly as it does for an opened one.
    static var scratchFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.ahmed.xmleditorx/untitled", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Delete every scratch copy still around. Called at quit.
    static func clearScratch() {
        let fm = FileManager.default
        let dir = scratchFolder
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    private func uniqueScratchURL(named base: String) -> URL {
        let dir = Self.scratchFolder
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let stem = (base as NSString).deletingPathExtension
            name = "\(stem) \(n).xml"
            n += 1
        }
        return dir.appendingPathComponent(name)
    }

    /// File ▸ New, ⌘N, and the + button on the tab strip.
    @objc func menuNewDocument(_ sender: Any?) {
        let skeleton = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n"
        openScratchDocument(text: skeleton, named: "Untitled.xml")
    }

    /// Writes `text` into the scratch folder and opens it as a tab.
    func openScratchDocument(text: String, named: String) {
        let url = uniqueScratchURL(named: named)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
            statusLabel.stringValue = "Could not create the new document"
            return
        }
        pendingUntitledURL = url
        loadFile(url: url)
    }

    /// Set between creating a scratch file and its session appearing.
    private var pendingUntitledURL: URL?

    @objc func menuSave(_ sender: Any?) {
        // An untitled document has nowhere of its own to go yet.
        if sessions.indices.contains(activeSessionIdx), sessions[activeSessionIdx].isUntitled {
            menuSaveAs(sender)
            return
        }
        guard requireReadyDocument(for: "saving") else { return }
        guard currentFileURL != nil else {
            menuSaveAs(sender)   // No current file → act like Save As.
            return
        }
        performSaveToCurrentURL()
    }

    @objc func menuSaveAs(_ sender: Any?) {
        guard requireReadyDocument(for: "saving") else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "untitled.xml"
        if let url = currentFileURL {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        panel.message = "Save a copy of the current XML"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.performSave(to: url, updateCurrent: true)
        }
    }

    @objc func menuRevert(_ sender: Any?) {
        guard requireReadyDocument(for: "reverting") else { return }
        guard let url = currentFileURL else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Revert to saved?"
        alert.informativeText = "This discards any unsaved changes in \(url.lastPathComponent)."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            reloadFile(url)
        }
    }

    @objc func menuCloseFile(_ sender: Any?) {
        closeCurrentFile()
    }

    @objc func menuRevealInFinder(_ sender: Any?) {
        guard let url = currentFileURL else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func menuCopyPath(_ sender: Any?) {
        guard let url = currentFileURL else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    /// Shows or hides the minimap. Hidden, the source editor takes the
    /// whole width; the choice is remembered for the next launch.
    func setMinimapVisible(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.minimapVisibleKey)
        minimap.isHidden = !on
        minimapWidthCon?.constant = on ? XMMetric.s(XMMetric.minimapW) : 0
        minimapGapCon?.constant = on ? -XMMetric.paneGap : 0
        sourceContainerView?.needsLayout = true
        statusLabel.stringValue = on
            ? "Minimap shown"
            : "Minimap hidden, View ▸ Show Minimap brings it back"
    }

    @objc func menuToggleMinimap(_ sender: Any?) {
        setMinimapVisible(!Self.minimapVisible)
    }

    @objc func menuToggleLineNumbers(_ sender: Any?) {
        sourceVC.setLineNumbersVisible(!sourceVC.isLineNumbersVisible)
        popSource?.setLineNumbersVisible(sourceVC.isLineNumbersVisible)
    }

    @objc func menuGoToLine(_ sender: Any?) {
        // Small modal sheet: a text field + OK button. Parses the
        // integer and scrolls the source editor to that line via
        // the existing SourceViewController.scrollToLine path.
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "1"
        alert.accessoryView = input
        if let win = window {
            alert.beginSheetModal(for: win) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                if let line = Int(input.stringValue.trimmingCharacters(in: .whitespaces)),
                   line > 0 {
                    self?.sourceVC.scrollToLine(line)
                }
            }
            // Focus the field so the user can type immediately.
            DispatchQueue.main.async { win.makeFirstResponder(input) }
        }
    }

    // Actual save implementations. Writes are bound to a stable session ID
    // and edit revision, and preserve the XML file's original encoding/BOM.
    // If the user edits while a large atomic write is running, the document
    // correctly remains dirty because those newer edits were not written.
    private func performSaveToCurrentURL() {
        guard let url = currentFileURL else { return }
        performSave(to: url, updateCurrent: false)
    }

    private func performSave(to url: URL, updateCurrent: Bool,
                             completion: ((Bool) -> Void)? = nil) {
        guard requireReadyDocument(for: "saving"),
              sessions.indices.contains(activeSessionIdx) else {
            completion?(false)
            return
        }
        snapshotActiveSession()
        let sessionID = sessions[activeSessionIdx].id
        saveSession(sessionID: sessionID, to: url, updateURL: updateCurrent,
                    completion: completion)
    }

    private func saveSession(sessionID: UUID, to rawURL: URL, updateURL: Bool,
                             completion: ((Bool) -> Void)? = nil) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[index].isLoading,
              !savingSessionIDs.contains(sessionID) else {
            NSSound.beep()
            completion?(false)
            return
        }

        let url = rawURL.standardizedFileURL
        if updateURL,
           sessions.contains(where: { $0.id != sessionID && $0.url.standardizedFileURL == url }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That file is already open"
            alert.informativeText = "Choose a different name or close the existing tab first."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completion?(false)
            return
        }

        let session = sessions[index]
        if session.url.standardizedFileURL == url,
           let recordedDate = session.fileModificationDate,
           let currentDate = fileModificationDate(at: url),
           currentDate != recordedDate {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The file changed on disk"
            alert.informativeText = "Another app modified \(url.lastPathComponent) after it was opened. Overwriting will replace those external changes."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                completion?(false)
                return
            }
        }
        let text: String
        if index == activeSessionIdx {
            text = sourceVC.exposedTextView.string
        } else if let storage = session.storage {
            text = storage.string
        } else {
            completion?(false)
            return
        }
        let encoding: XMLTextEncoding
        do {
            encoding = try session.textEncoding.reconciledForSave(text)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            completion?(false)
            return
        }
        let savedRevision = session.editRevision
        savingSessionIDs.insert(sessionID)
        statusLabel.stringValue = "Saving \(url.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let writeError: Error?
            do {
                let data = try encoding.encode(text)
                try data.write(to: url, options: .atomic)
                writeError = nil
            } catch {
                writeError = error
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.savingSessionIDs.remove(sessionID)
                if let error = writeError {
                    self.statusLabel.stringValue = "Save failed"
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    completion?(false)
                    return
                }
                guard let currentIndex = self.sessions.firstIndex(where: { $0.id == sessionID }) else {
                    completion?(false)
                    return
                }
                let savedSession = self.sessions[currentIndex]
                savedSession.textEncoding = encoding
                savedSession.fileModificationDate = self.fileModificationDate(at: url)
                savedSession.fileSize = (try? FileManager.default.attributesOfItem(
                    atPath: url.path)[.size] as? Int) ?? savedSession.fileSize
                if updateURL {
                    savedSession.url = url
                    if currentIndex == self.activeSessionIdx { self.currentFileURL = url }
                    let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
                    if currentIndex == self.activeSessionIdx {
                        self.window?.title = "\(url.lastPathComponent), xml-macker v\(v)"
                    }
                    self.refreshTabStrip()
                }
                if currentIndex == self.activeSessionIdx {
                    self.sourceVC.adoptSavedDocument(
                        url: savedSession.url,
                        fileSize: savedSession.fileSize,
                        textEncoding: encoding
                    )
                }
                (NSApp.delegate as? AppDelegate)?.addRecent(url)
                // Only the exact buffer revision that reached disk becomes
                // clean. Later edits remain honestly marked as unsaved.
                if savedSession.editRevision == savedRevision {
                    savedSession.isDirty = false
                    if currentIndex == self.activeSessionIdx,
                       self.activeEditRevision == savedRevision {
                        self.docDirty = false
                    }
                }
                self.updateWindowDocumentState()
                self.statusLabel.stringValue = "Saved \(url.lastPathComponent)"
                completion?(true)
                // Brief accent flash on the progress fill as a "saved" cue.
                let barH = self.statusProgressFill.superlayer?.bounds.height ?? 26
                let totalW = self.statusProgressFill.superlayer?.bounds.width ?? 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.statusProgressFill.frame = NSRect(x: 0, y: 0, width: totalW, height: barH)
                self.statusProgressFill.opacity = 1
                CATransaction.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.4)
                    self.statusProgressFill.opacity = 0
                    CATransaction.commit()
                }
            }
        }
    }

    private func fileModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func fileFingerprint(at url: URL) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileFingerprint(byteCount: size.uint64Value,
                               modificationDate: modificationDate,
                               fileNumber: number)
    }

    @objc func tbClose(_ sender: Any?) {
        closeCurrentFile()
    }

    @objc func tbFind(_ sender: Any?) {
        presentFindReplace(scope: nil)
    }

    @objc func tbDrillUp(_ sender: Any?) {
        treeVC.drillUp()
    }

    @objc func tbDrillDown(_ sender: Any?) {
        treeVC.drillDown()
    }

    // ── Diff (v0.39.0), compare two open tabs side by side ──

    @objc func tbDiff(_ sender: Any?) {
        // Works with nothing open: the picker has a Browse button on each
        // side and opens whatever is chosen. Only a load in flight stops it.
        guard !sessions.contains(where: { $0.isLoading }) else {
            NSSound.beep()
            statusLabel.stringValue = "Still loading, try again in a moment"
            return
        }
        // ALWAYS ask which two, even with exactly two tabs open: comparing
        // the wrong pair and having to close the window again is worse
        // than one extra click. Each side can also Browse for a file that
        // is not open yet; it opens as a tab first.
        presentDiffPicker()
    }

    /// Files offered by the picker: the open tabs, plus anything browsed
    /// for during this run of the sheet.
    private func presentDiffPicker() {
        var choices: [(name: String, url: URL, session: DocumentSession?)] =
            sessions.map { ($0.url.lastPathComponent, $0.url, $0) }
        let active = sessions.indices.contains(activeSessionIdx) ? sessions[activeSessionIdx] : nil

        let alert = NSAlert()
        alert.messageText = "Compare which two files?"
        alert.informativeText = choices.isEmpty
            ? "Nothing is open yet. Use Browse on each side to choose the two files; they will be opened as tabs."
            : "Pick a file on each side, or browse for one that is not open yet."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 62))
        let leftPop = NSPopUpButton(frame: NSRect(x: 60, y: 34, width: 270, height: 26))
        let rightPop = NSPopUpButton(frame: NSRect(x: 60, y: 2, width: 270, height: 26))
        let lLabel = NSTextField(labelWithString: "Left:")
        lLabel.frame = NSRect(x: 0, y: 38, width: 55, height: 18)
        let rLabel = NSTextField(labelWithString: "Right:")
        rLabel.frame = NSRect(x: 0, y: 6, width: 55, height: 18)
        let lBrowse = NSButton(frame: NSRect(x: 336, y: 32, width: 92, height: 30))
        let rBrowse = NSButton(frame: NSRect(x: 336, y: 0, width: 92, height: 30))
        for b in [lBrowse, rBrowse] { b.title = "Browse…"; b.bezelStyle = .rounded; b.controlSize = .small }

        func refill() {
            for pop in [leftPop, rightPop] {
                let keep = pop.indexOfSelectedItem
                pop.removeAllItems()
                for c in choices { pop.addItem(withTitle: c.name) }
                if keep >= 0, keep < choices.count { pop.selectItem(at: keep) }
            }
        }
        refill()
        if choices.indices.contains(activeSessionIdx) { leftPop.selectItem(at: activeSessionIdx) }
        if let other = choices.firstIndex(where: { $0.session !== active }) { rightPop.selectItem(at: other) }

        func browse(_ pop: NSPopUpButton) {
            let panel = NSOpenPanel()
            panel.title = "Choose a file to compare"
            panel.allowedContentTypes = [.xml]
            panel.directoryURL = active?.url.deletingLastPathComponent()
                ?? (NSApp.delegate as? AppDelegate)?.mostRecentFolder
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let existing = choices.firstIndex(where: { $0.url == url }) {
                pop.selectItem(at: existing)
                return
            }
            choices.append((url.lastPathComponent + " (will be opened)", url, nil))
            refill()
            pop.selectItem(at: choices.count - 1)
        }
        lBrowse.target = BlockButton.shared
        rBrowse.target = BlockButton.shared
        lBrowse.action = #selector(BlockButton.fire(_:))
        rBrowse.action = #selector(BlockButton.fire(_:))
        BlockButton.shared.handlers[ObjectIdentifier(lBrowse)] = { browse(leftPop) }
        BlockButton.shared.handlers[ObjectIdentifier(rBrowse)] = { browse(rightPop) }

        box.addSubview(lLabel); box.addSubview(rLabel)
        box.addSubview(leftPop); box.addSubview(rightPop)
        box.addSubview(lBrowse); box.addSubview(rBrowse)
        alert.accessoryView = box
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let li = leftPop.indexOfSelectedItem, ri = rightPop.indexOfSelectedItem
        guard li != ri, choices.indices.contains(li), choices.indices.contains(ri) else {
            NSSound.beep()
            statusLabel.stringValue = "Pick two different files"
            return
        }
        // Anything browsed for becomes a tab first; the comparison opens
        // once BOTH sides are loaded, so two new files work as well as one.
        let leftURL = choices[li].url, rightURL = choices[ri].url
        pendingDiff = (left: leftURL, right: rightURL)
        if choices[li].session == nil { loadFile(url: leftURL) }
        if choices[ri].session == nil { loadFile(url: rightURL) }
        tryContinuePendingDiff()
    }

    /// Set while the files a comparison needs are still opening.
    private var pendingDiff: (left: URL, right: URL)?

    /// Opens the comparison as soon as both of its files are tabs.
    private func tryContinuePendingDiff() {
        guard let p = pendingDiff,
              let l = sessions.first(where: { $0.url == p.left && !$0.isLoading }),
              let r = sessions.first(where: { $0.url == p.right && !$0.isLoading }),
              l !== r else { return }
        pendingDiff = nil
        openDiff(left: l, right: r)
    }

    private func sessionText(_ s: DocumentSession) -> String? {
        if sessions.indices.contains(activeSessionIdx), sessions[activeSessionIdx] === s {
            return sourceVC.documentText
        }
        return s.storage?.string
    }

    private func openDiff(left: DocumentSession, right: DocumentSession) {
        guard let lt = sessionText(left), let rt = sessionText(right) else { NSSound.beep(); return }
        guard lt.utf16.count <= 64_000_000, rt.utf16.count <= 64_000_000 else {
            NSSound.beep()
            statusLabel.stringValue = "One of the files is too large to diff (64 MB cap)"
            return
        }
        statusLabel.stringValue = "Comparing…"
        let diff = DiffWindowController(leftName: left.url.lastPathComponent, leftText: lt,
                                        rightName: right.url.lastPathComponent, rightText: rt)
        // The pair is held in a box so a side can be swapped without
        // rebuilding the window: every edit resolves the CURRENT pair.
        let pair = DiffPair(left: left, right: right)
        diff.applyEdit = { [weak self] side, range, replacement in
            guard let self, let target = side == .left ? pair.left : pair.right else { return false }
            return self.applyDiffEdit(to: target, range: range, replacement: replacement)
        }
        diff.openFilesProvider = { [weak self] in
            (self?.sessions ?? []).map { ($0.url.lastPathComponent, $0.url) }
        }
        diff.onChangeSide = { [weak self, weak diff] side, url in
            guard let self, let diff else { return }
            func put(_ session: DocumentSession) {
                guard let text = self.sessionText(session) else { NSSound.beep(); return }
                if side == .left { pair.left = session } else { pair.right = session }
                diff.replaceSide(side, name: session.url.lastPathComponent, text: text)
            }
            if let url {
                if let open = self.sessions.first(where: { $0.url == url }) { put(open) }
                else { self.pendingDiffSwap = (diff, side, pair); self.loadFile(url: url) }
                return
            }
            let panel = NSOpenPanel()
            panel.title = "Compare a different file"
            panel.allowedContentTypes = [.xml]
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            if let open = self.sessions.first(where: { $0.url == picked }) { put(open) }
            else { self.pendingDiffSwap = (diff, side, pair); self.loadFile(url: picked) }
        }
        diff.onClose = { [weak self, weak diff] in
            guard let self, let diff else { return }
            self.diffWindows.removeAll { $0 === diff }
        }
        diffWindows.append(diff)
        diff.present()
        statusLabel.stringValue = "Comparing \(left.url.lastPathComponent) ⟷ \(right.url.lastPathComponent)"
    }

    // A copy-hunk from the diff window, landing in the real document.
    // Active tab → normal undoable edit + tree rebuild. Parked tab →
    // direct storage edit; its snapshot tree rebuilds on activation.
    private func applyDiffEdit(to session: DocumentSession, range: NSRange, replacement: String) -> Bool {
        let tE = Date()
        let isActive = sessions.indices.contains(activeSessionIdx) && sessions[activeSessionIdx] === session
        defer { Diag.log("diff applyEdit(\(isActive ? "active" : "parked")): \(String(format: "%.3f", Date().timeIntervalSince(tE)))s") }
        if isActive {
            let ok = Diag.time("diff applyEdit: performEdit") { sourceVC.performEdit(range: range, replacement: replacement) }
            guard ok else { return false }
            reparseFromEditor()
            return true
        }
        guard let st = session.storage, NSMaxRange(range) <= st.length else { return false }
        st.replaceCharacters(in: range, with: replacement)
        // Marks belong to the text, so a copy into a tab that is not in
        // front has to move them too.
        session.highlights.shiftForEdit(start: range.location, removed: range.length,
                                        inserted: (replacement as NSString).length)
        session.isDirty = true
        session.editRevision &+= 1
        terminationApproved = false
        session.lineStarts = SourceViewController.buildLineStarts(in: st.string)
        session.needsReparse = true
        return true
    }

    private func orbitQuickEdit(_ node: XMLTreeNode) {
        let isLeaf = !node.children.contains(where: { $0.kind == .element })
        let editingText = isLeaf && !node.textValue.isEmpty
        let keyAttr = node.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })
            ?? node.attributes.first
        guard editingText || keyAttr != nil else {
            NSSound.beep()
            statusLabel.stringValue = "<\(node.displayLabel)> has no value or attribute to edit here, use the Inspector"
            return
        }
        let alert = NSAlert()
        alert.messageText = editingText
            ? "Edit value of <\(node.displayLabel)>"
            : "Edit \(keyAttr!.name) of <\(node.displayLabel)>"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = editingText ? node.textValue : (keyAttr?.value ?? "")
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newValue = field.stringValue
        let ok = editingText
            ? sourceVC.applyTextEdit(node: node, newText: newValue)
            : sourceVC.applyAttrEdit(node: node, attrName: keyAttr!.name, newValue: newValue)
        if ok {
            treeVC.refreshNode(node)
            popTree?.refreshNode(node)
            subtagsBarVC.refreshValuesOnly()
            inspectorVC.attributesVC.refreshValuesOnly()
            chartPaneVC.refreshCurrent()
            orbitWindow.present(node: currentSelectedNode)
            scheduleAutoValidation()
            statusLabel.stringValue = "Updated <\(node.displayLabel)>"
        } else { NSSound.beep() }
    }

    // Shared refresh after an edit committed from the Orbit rail: the
    // same fan-out as the Inspector, plus a deferred Orbit re-render
    // (the table cell that started the edit is still ending it).
    private func afterOrbitEdit(_ node: XMLTreeNode) {
        treeVC.refreshNode(node)
        popTree?.refreshNode(node)
        inspectorVC.attributesVC.refreshValuesOnly()
        subtagsBarVC.refreshValuesOnly()
        chartPaneVC.refreshCurrent()
        scheduleAutoValidation()
        statusLabel.stringValue = "Updated <\(node.displayLabel)>"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.orbitWindow.present(node: self.currentSelectedNode)
        }
    }

    @objc func tbOrbit(_ sender: Any?) {
        orbitWindow.present(node: currentSelectedNode)
        orbitWindow.show()
    }

    // Safe array subscript for the split-view delegate's bounds
    // checks (arrangedSubviews[idx+1] etc could be out-of-range on
    // a split that hasn't finished laying out).
    private func subview<T>(_ arr: [T], at index: Int) -> T? {
        return arr.indices.contains(index) ? arr[index] : nil
    }

    // Open (or focus) the Validation window. Lists the current parse
    // errors; clicking a row jumps the source editor to the line.
    @objc func showValidation(_ sender: Any?) {
        if let existing = validationWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.setErrors(lastParseErrors)
            return
        }
        let w = ValidationWindowController()
        w.setErrors(lastParseErrors)
        w.onClose = { [weak self] in self?.validationWindow = nil }
        w.onRevalidateRequested = { [weak self] in self?.revalidateFullDocument() }
        w.onErrorClicked = { [weak self] line, _ in
            // Same as the inline Errors tab: exact line, no tree-select
            // detour to the element's start.
            self?.sourceVC.scrollToLine(line)
        }
        w.onFixClicked = { [weak self] error in
            self?.applyLintFix(error)
        }
        w.showWindow(nil)
        validationWindow = w
    }

    // MARK: Progress fill in status bar

    private func startProgressFill(estimatedSeconds: Double) {
        progressTimer?.invalidate()
        // Reset to 0 width instantly, no animation. Height follows the
        // status bar's CURRENT height (which scales with the global
        // zoom slider) instead of a hard-coded 26 pt.
        let barH = statusProgressFill.superlayer?.bounds.height ?? 26
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusProgressFill.frame = NSRect(x: 0, y: 0,
                                          width: 0,
                                          height: barH)
        CATransaction.commit()

        let start = Date()
        let totalW = statusProgressFill.superlayer?.bounds.width ?? 800
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            // Prefer REAL progress: if the parser is running and we
            // have a newline count for the file, fraction = lines
            // parsed / total lines. Otherwise fall back to the
            // time-based asymptote so the bar still moves during the
            // pre-parse newline scan (and for files we failed to
            // memory-map).
            let fraction: Double
            if self.totalLinesForProgress > 0, let p = self.activeParser {
                let scanned = Double(p.currentLineNumber)
                let total   = Double(self.totalLinesForProgress)
                // Cap at 0.98, finishProgressFill snaps to 1.0 once
                // everything is done so the user sees the click-to-
                // full moment explicitly.
                fraction = min(0.98, scanned / max(1.0, total))
            } else {
                fraction = min(0.92, elapsed / (elapsed + estimatedSeconds))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let currentTotalW = self.statusProgressFill.superlayer?.bounds.width ?? totalW
            let currentH = self.statusProgressFill.superlayer?.bounds.height ?? 26
            self.statusProgressFill.frame = NSRect(
                x: 0, y: 0,
                width: currentTotalW * CGFloat(fraction),
                height: currentH)
            CATransaction.commit()
        }
    }

    private func finishProgressFill() {
        progressTimer?.invalidate()
        progressTimer = nil
        activeParser = nil
        totalLinesForProgress = 0
        let totalW = statusProgressFill.superlayer?.bounds.width ?? 0
        let barH = statusProgressFill.superlayer?.bounds.height ?? 26
        // Snap to full, then fade out.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusProgressFill.frame = NSRect(x: 0, y: 0, width: totalW, height: barH)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            self.statusProgressFill.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.statusProgressFill.frame = .zero
                self.statusProgressFill.opacity = 1
                CATransaction.commit()
            }
        }
    }

    // MARK: Global zoom (status-bar slider)
    //
    // Slider is 0…100; we map that onto a 0.5×…2.0× font-scale range.
    // 0 → 50% (smallest), 50 → 100%, 100 → 200%. Non-linear mapping:
    // each slider unit is a consistent % step on the log scale, so
    // dragging down from 100% feels as responsive as dragging up.
    private func scale(forSliderValue v: Double) -> CGFloat {
        // 0 → 0.5, 50 → 1.0, 100 → 2.0 (powers of two, halfway = 1×).
        let t = max(0.0, min(100.0, v)) / 100.0
        return CGFloat(pow(2.0, (t - 0.5) * 2.0))  // 2^(-1..+1) = 0.5..2.0
    }
    private func sliderValue(for scale: CGFloat) -> Double {
        let s = max(0.5, min(2.0, Double(scale)))
        return (log2(s) + 1.0) / 2.0 * 100.0
    }

    // The slider fires on every pixel of a drag; re-fonting a 39 MB
    // document per pixel is what made it feel heavy (v0.44.3). While
    // dragging, only the percent label follows the thumb live and the
    // real rebuild runs 120 ms after the thumb pauses (timer in .common
    // mode so it fires during the mouse-tracking loop). Clicks and the
    // release apply immediately.
    private var zoomCommitTimer: Timer?
    @objc func zoomSliderChanged(_ sender: NSSlider) {
        let target = scale(forSliderValue: sender.doubleValue)
        zoomCommitTimer?.invalidate()
        zoomCommitTimer = nil
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard dragging else { applyGlobalScale(target); return }
        zoomPercentLabel.stringValue = "\(Int((target * 100).rounded()))%"
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.applyGlobalScale(target)
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomCommitTimer = timer
    }
    @objc func zoomSliderMinus(_ sender: Any?) {
        let cur = Double(XMFont.globalScale)
        let next = max(0.5, cur / 1.1)                   // 10% step down
        zoomSlider.doubleValue = sliderValue(for: CGFloat(next))
        applyGlobalScale(CGFloat(next))
    }
    @objc func zoomSliderPlus(_ sender: Any?) {
        let cur = Double(XMFont.globalScale)
        let next = min(2.0, cur * 1.1)                   // 10% step up
        zoomSlider.doubleValue = sliderValue(for: CGFloat(next))
        applyGlobalScale(CGFloat(next))
    }
    @objc func zoomSliderReset(_ sender: Any?) {
        zoomSlider.doubleValue = sliderValue(for: XMFont.defaultScale)
        applyGlobalScale(XMFont.defaultScale)
    }

    // Single authoritative place that updates XMFont.globalScale +
    // broadcasts refresh to every VC. Called from the slider, the
    // +/− buttons, and the reset button. Also updates the percent
    // label next to the slider.
    func applyGlobalScale(_ scale: CGFloat) {
        let s = max(0.5, min(2.0, scale))
        XMFont.globalScale = s
        zoomPercentLabel.stringValue = "\(Int((s * 100).rounded()))%"
        rebuildAllFonts()
        // Remember the zoom the user likes, restored at next launch.
        UserDefaults.standard.set(Double(s), forKey: "xml-macker.globalZoom")
    }

    private func rebuildAllFonts() {
        // Status + toolbar labels the window itself owns.
        statusLabel.font = XMFont.uiSmall
        zoomPercentLabel.font = XMFont.ui(11, .semibold)
        zoomMinusButton.font = XMFont.ui(13, .semibold)
        zoomPlusButton.font = XMFont.ui(13, .semibold)
        zoomResetButton.font = XMFont.ui(11, .regular)
        detailSelector.font = XMFont.ui(10, .semibold)

        // LAYOUT metrics, the whole point of this broadcast is that
        // one slider now affects BOTH type AND chrome height, so
        // small-display users can make panes visually tighter instead
        // of only shrinking text. Each stored constraint gets its
        // .constant recomputed from XMMetric.s(baseValue).
        tabStripHeightCon?.constant    = XMMetric.s(XMMetric.tabStripH)
        breadcrumbHeightCon?.constant  = XMMetric.s(XMMetric.breadcrumbH)
        statusBarHeightCon?.constant   = XMMetric.s(26)
        if minimap.isHidden == false {
            minimapWidthCon?.constant  = XMMetric.s(XMMetric.minimapW)
        }

        // Per-VC rebuilds, each one re-applies the fonts it owns
        // AND updates any stored constraint .constants so row heights
        // and pane headers rescale together with type.
        treeVC.rebuildFonts()
        popTree?.rebuildFonts()
        popSubtags?.rebuildFonts()
        popHierarchy?.rebuildFonts()
        popSource?.rebuildFonts()
        paneWindows.values.forEach { $0.rebuildFonts() }
        sourceVC.rebuildFonts()
        inspectorVC.rebuildFonts()
        chartPaneVC.rebuildFonts()
        subtagsBarVC.rebuildFonts()
        previewPaneVC.rebuildFonts()
        errorsPaneVC.rebuildFonts()
        orbitWindow.rebuildFonts()
        // Pane chrome titles (PaneChrome.titleLabel) + header height.
        treeChrome?.rebuildFonts()
        sourceChrome?.rebuildFonts()
        inspectorChrome?.rebuildFonts()
        subtagsChrome?.rebuildFonts()
        hierarchyChrome?.rebuildFonts()
        previewChrome?.rebuildFonts()
        chartChrome?.rebuildFonts()
        // Dynamic views that cache fonts when rebuilt from a node, 
        // re-drive them with the current selection/path so the
        // rebuild path runs.
        hierarchyBarVC.rebuildFonts()
        if let node = currentSelectedNode {
            hierarchyBarVC.setNode(node)
        }
        refreshTabStrip()
        // Breadcrumb / minimap / trend views redraw on next cycle.
        breadcrumb.needsDisplay = true
        minimap.needsDisplay = true
        chartPaneVC.exposedTrendView.needsDisplay = true
        // Trigger a window-wide layout pass so every updated
        // constraint actually re-runs auto-layout.
        window?.contentView?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        applyDetailSelection(persist: false)
    }

    // MARK: Theme broadcast
    //
    // Flow for a theme switch:
    //   1. ThemeManager.select(_:), persists the choice + swaps the
    //      palette globally. Every `XMColor.xxx` call now returns the
    //      new theme's color.
    //   2. window.appearance flips (dark vs light) so traffic lights
    //      + native NSVisualEffectView blurs follow.
    //   3. rebuildAllColors() fans out to every VC + helper view that
    //      cached a `cgColor` at init, plus the syntax highlighter
    //      (which stores color attributes in text storage).
    //
    // Called from the View > Theme menu.
    // One action for every theme, driven by Theme.all. The old
    // one-selector-per-theme arrangement had already drifted: the tick in
    // View > Theme was only implemented for three of the five, so Dracula
    // and Hacker never showed as selected.
    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let theme = Theme.byId(id) else { return }
        applyTheme(theme)
    }

    private func applyTheme(_ theme: Theme) {
        ThemeManager.select(theme)
        window?.applyCurrentTheme(background: XMColor.bg)
        // The app-wide appearance is deliberately left alone. Forcing it
        // moved the macOS menu bar's own text away from the system
        // appearance and made it unreadable; every window below sets its
        // own appearance instead.
        // Every secondary window that is already open follows immediately.
        // Setting .appearance alone is not enough: each of these windows
        // caches label and background colours when it is built, so a theme
        // switch left them wearing the old palette (black title text on a
        // dark background). They each re-read their colours now.
        validationWindow?.rebuildColors()
        chartPopout?.rebuildColors()
        orbitWindow.window?.applyCurrentTheme(background: XMColor.bg)
        orbitWindow.rebuildColors()
        findPanel?.rebuildColors()
        for d in diffWindows { d.rebuildColors() }
        for entry in popouts.values {
            entry.window.applyCurrentTheme(background: XMColor.bg)
            (entry.glass as? GlassPanel)?.rebuildColors()
            entry.chrome.rebuildColors()
            entry.window.contentView?.needsDisplayRecursively()
        }
        paneWindows.values.forEach { $0.rebuildColors() }
        rebuildAllColors()
        rebuildAllFonts()   // nudges layout + reload paths so table
                             // cells re-fetch XMColor-based text colors.
    }

    private func rebuildAllColors() {
        // Root content view + status-bar progress fill.
        rootBackingView?.layer?.backgroundColor = XMColor.bg.cgColor
        window?.backgroundColor = XMColor.bg
        statusProgressFill.backgroundColor = XMColor.accent.withAlphaComponent(0.28).cgColor
        statusLabel.textColor = XMColor.text3
        zoomPercentLabel.textColor = XMColor.text2
        zoomMinusButton.contentTintColor = XMColor.text2
        zoomPlusButton.contentTintColor = XMColor.text2
        zoomResetButton.contentTintColor = XMColor.text3

        // Pane chrome cached cgColors (header bg + title color).
        treeChrome?.rebuildColors()
        sourceChrome?.rebuildColors()
        inspectorChrome?.rebuildColors()
        subtagsChrome?.rebuildColors()
        hierarchyChrome?.rebuildColors()
        previewChrome?.rebuildColors()
        chartChrome?.rebuildColors()

        // GlassPanel: border color + NSVisualEffectView material
        // swap (dark .hudWindow → light .contentBackground etc).
        (treeGlass as? GlassPanel)?.rebuildColors()
        (sourceGlass as? GlassPanel)?.rebuildColors()
        (inspectorGlass as? GlassPanel)?.rebuildColors()
        (subtagsGlass as? GlassPanel)?.rebuildColors()
        (hierarchyGlass as? GlassPanel)?.rebuildColors()
        (previewGlass as? GlassPanel)?.rebuildColors()
        (chartGlass as? GlassPanel)?.rebuildColors()

        // Child VC NSColor backgrounds (textViews, scroll views,
        // tables) + dependent reloadData passes.
        treeVC.rebuildColors()
        sourceVC.rebuildColors()
        inspectorVC.rebuildColors()
        chartPaneVC.rebuildColors()
        subtagsBarVC.rebuildColors()
        previewPaneVC.rebuildColors()
        errorsPaneVC.rebuildColors()

        // Tab chips, breadcrumbs and the Learn pane all cache colours too.
        tabStrip.rebuildColors()
        breadcrumb.rebuildColors()
        learnVC?.rebuildColors()
        learnGlass?.rebuildColors()

        // Minimap + hierarchy mini view cache their bg/border cgColor.
        minimap.rebuildColors()
        hierarchyBarVC.hierarchy.rebuildColors()
        popTree?.rebuildColors()
        popSubtags?.rebuildColors()
        popHierarchy?.hierarchy.rebuildColors()
        popSource?.rebuildColors()
        paneWindows.values.forEach { $0.rebuildColors() }

        // Every view that uses XMColor inside draw(_:) picks up the
        // new palette on its next redraw, trigger it now.
        window?.contentView?.needsDisplayRecursively()
    }

    /// Explicit whole-document validation for the standalone window. Live
    /// typing continues to use the bounded scoped linter below; parsing a
    /// 37-655 MB GCAM document on every keystroke would be wasteful.
    private func revalidateFullDocument() {
        guard requireReadyDocument(for: "validating"),
              sessions.indices.contains(activeSessionIdx),
              let url = currentFileURL else { return }
        let sessionID = sessions[activeSessionIdx].id
        let revision = activeEditRevision
        let dirtySnapshot = docDirty
        let textSnapshot = dirtySnapshot ? sourceVC.documentText : nil
        fullValidationRequestID &+= 1
        let requestID = fullValidationRequestID
        statusLabel.stringValue = "Validating the full document…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let errors = textSnapshot.map(XMLStreamParser.validateText)
                ?? XMLStreamParser.validateFile(at: url)
            DispatchQueue.main.async {
                guard let self,
                      requestID == self.fullValidationRequestID,
                      self.sessions.indices.contains(self.activeSessionIdx),
                      self.sessions[self.activeSessionIdx].id == sessionID,
                      self.activeEditRevision == revision else { return }
                self.lastParseErrors = errors
                self.sessions[self.activeSessionIdx].parseErrors = errors
                self.validationWindow?.setErrors(errors)
                self.statusLabel.stringValue = errors.isEmpty
                    ? "Full document is well-formed"
                    : "Full validation found \(errors.count) error\(errors.count == 1 ? "" : "s")"
            }
        }
    }

    // Scoped live validation, replaces the old "parse-the-whole-
    // 655-MB-buffer-on-every-keystroke" path. Problems with the
    // earlier attempts:
    //   • full-file parse on every edit was slow and unstable
    //   • errors from unrelated parts of the file were noise
    //   • the file itself felt destroyed after edits
    //
    // The fix: validate only the region the user is actually looking
    // at. We walk up from the currently-selected tree node to its
    // parent (for context), extract that element's bytes, and parse
    // just that fragment. `XMLStreamParser.parseFragment(text:,
    // baseLine:)` shifts error line numbers by the fragment's start
    // line so they still line up with the absolute source editor, 
    // clicking an error in the Errors tab scrolls to the right line.
    private func revalidate() {
        // Figure out the scope. Prefer the PARENT of the currently-
        // selected element so the user gets edits + siblings + the
        // surrounding open/close tags in context, that's what
        // catches <region> ↔ </regioddn> mismatches.
        //
        // v0.18.0 rework: extraction now starts at the scope element's
        // OPENING TAG and simply extends to the cap. The old code
        // computed the element's END from the tree's load-time endLine
        //, stale as soon as the user's typing added or removed a
        // line, which cut the fragment mid-element and produced bogus
        // "premature end" errors (or masked real ones). The
        // XMLFragmentLinter stops on its own once the scope's root
        // element closes, so over-extraction costs nothing.
        guard sessions.indices.contains(activeSessionIdx),
              !sessions[activeSessionIdx].isLoading,
              let scope = pickValidationScope(),
              let startOffset = sourceVC.elementStartOffset(scope) else {
            // No meaningful selection (e.g. file just opened and
            // nothing clicked yet). Clear the Errors tab quietly.
            errorsPaneVC.setErrors([])
            scopedLintErrors = []
            publishedValidationSessionID = nil
            return
        }

        validationRequestID &+= 1
        let requestID = validationRequestID
        let sessionID = sessions[activeSessionIdx].id
        let revision = activeEditRevision
        let (text, reachedDocEnd) = sourceVC.substring(from: startOffset, cap: 5_000_000)
        let baseLine = scope.startLine
        let scopeLabel = "<\(scope.displayLabel)>"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let errors = XMLFragmentLinter.lint(text,
                                                baseLine: baseLine,
                                                reachedDocEnd: reachedDocEnd,
                                                baseOffset: startOffset)
            DispatchQueue.main.async {
                guard let self,
                      requestID == self.validationRequestID,
                      self.sessions.indices.contains(self.activeSessionIdx),
                      self.sessions[self.activeSessionIdx].id == sessionID,
                      self.activeEditRevision == revision else { return }
                self.scopedLintErrors = errors
                self.publishedValidationSessionID = sessionID
                self.publishedValidationRevision = revision
                self.errorsPaneVC.setErrors(errors)
                self.errorsPaneVC.setValidationScope(scopeLabel)
            }
        }
    }

    // Apply a one-click repair from an error row's Fix button. The
    // source editor verifies the document still matches what the
    // linter saw before touching anything; if the user typed in the
    // meantime we just re-lint (fresh errors carry fresh fixes) and
    // beep so the click doesn't feel ignored.
    private func applyLintFix(_ error: XMLStreamParser.ParseError) {
        guard let fix = error.fix else { return }
        guard sessions.indices.contains(activeSessionIdx),
              publishedValidationSessionID == sessions[activeSessionIdx].id,
              publishedValidationRevision == activeEditRevision else {
            NSSound.beep()
            statusLabel.stringValue = "The document changed, validation was refreshed before applying a fix"
            revalidate()
            return
        }
        let applied = sourceVC.applyFix(range: fix.range,
                                        original: fix.original,
                                        replacement: fix.replacement)
        if !applied { NSSound.beep() }
        // Re-lint right away either way, on success the fixed error
        // disappears immediately instead of waiting out the debounce.
        revalidate()
        if applied { reparseFromEditor() }
    }

    // Picks which element to validate. Priority:
    //   1. Parent of current selection (context: catches open/close
    //      mismatches between the edited element and its siblings).
    //   2. Current selection itself when the parent is the document
    //      root. Size no longer matters, the linter caps its own
    //      window and never trusts the stale element end.
    //   3. Nil if nothing is selected.
    private func pickValidationScope() -> XMLTreeNode? {
        guard let selected = currentSelectedNode,
              selected.kind == .element else { return nil }
        if let parent = selected.parent, parent.kind == .element {
            return parent
        }
        return selected
    }

    // MARK: Per-pane zoom dispatch
    //
    // Identifies which pane owns the keyboard first responder and
    // routes the zoom action there. If nothing matches (e.g. no
    // focus yet after a file opens) we default to the source editor
    //, that's the most common zoom target and matches VS Code.

    private enum ZoomTarget {
        case source, tree, subtags, attributes, preview
    }

    private func zoomTarget() -> ZoomTarget {
        guard let first = window?.firstResponder as? NSView else { return .source }
        if first.isDescendant(of: treeVC.exposedOutline)         { return .tree }
        if first.isDescendant(of: sourceVC.exposedTextView)      { return .source }
        if first.isDescendant(of: subtagsBarVC.exposedTable)     { return .subtags }
        if first.isDescendant(of: inspectorVC.attributesVC.exposedAttrTable) { return .attributes }
        if first === inspectorVC.attributesVC.exposedTextField ||
           first.isDescendant(of: inspectorVC.attributesVC.exposedTextField) { return .attributes }
        // Preview pane now has its own VC; route via its exposed text view.
        if first.isDescendant(of: previewPaneVC.exposedPreviewView) { return .preview }
        return .source
    }

    // Command + wheel zooms the pane the pointer is over, which is how
    // it works on Windows. The keys keep using the focused pane.
    private let wheelZoom = WheelZoom()

    func installWheelZoom() {
        wheelZoom.install(in: window, passThrough: { [weak self] event in
            // The Learn chat is a web view: a pinch there belongs to the
            // page, not to the app's own text sizes.
            guard let self, let learn = self.learnVC?.webView,
                  let hit = self.window?.contentView?.hitTest(event.locationInWindow) else { return false }
            return hit === learn || hit.isDescendant(of: learn)
        }) { [weak self] zoomIn, event in
            guard let self else { return }
            let target = self.zoomTargetUnderPointer(event) ?? self.zoomTarget()
            self.zoomPane(target, in: zoomIn)
        }
    }

    private func zoomTargetUnderPointer(_ event: NSEvent) -> ZoomTarget? {
        guard let content = window?.contentView,
              let hit = content.hitTest(event.locationInWindow) else { return nil }
        if hit.isDescendant(of: treeVC.exposedOutline)     { return .tree }
        if hit.isDescendant(of: sourceVC.exposedTextView)  { return .source }
        if hit.isDescendant(of: subtagsBarVC.exposedTable) { return .subtags }
        if hit.isDescendant(of: inspectorVC.attributesVC.exposedAttrTable) { return .attributes }
        if hit.isDescendant(of: previewPaneVC.exposedPreviewView) { return .preview }
        return nil
    }

    private func zoomPane(_ target: ZoomTarget, in zoomIn: Bool) {
        switch target {
        case .source:     zoomIn ? sourceVC.zoomIn() : sourceVC.zoomOut()
        case .tree:       zoomIn ? treeVC.zoomIn() : treeVC.zoomOut()
        case .subtags:    zoomIn ? subtagsBarVC.zoomIn() : subtagsBarVC.zoomOut()
        case .attributes: zoomIn ? inspectorVC.attributesVC.zoomIn() : inspectorVC.attributesVC.zoomOut()
        case .preview:    zoomIn ? previewPaneVC.zoomIn() : previewPaneVC.zoomOut()
        }
    }

    @objc func xmZoomIn(_ sender: Any?) {
        switch zoomTarget() {
        case .source:     sourceVC.zoomIn()
        case .tree:       treeVC.zoomIn()
        case .subtags:    subtagsBarVC.zoomIn()
        case .attributes: inspectorVC.attributesVC.zoomIn()
        case .preview:    previewPaneVC.zoomIn()
        }
    }
    @objc func xmZoomOut(_ sender: Any?) {
        switch zoomTarget() {
        case .source:     sourceVC.zoomOut()
        case .tree:       treeVC.zoomOut()
        case .subtags:    subtagsBarVC.zoomOut()
        case .attributes: inspectorVC.attributesVC.zoomOut()
        case .preview:    previewPaneVC.zoomOut()
        }
    }
    @objc func xmZoomReset(_ sender: Any?) {
        switch zoomTarget() {
        case .source:     sourceVC.zoomReset()
        case .tree:       treeVC.zoomReset()
        case .subtags:    subtagsBarVC.zoomReset()
        case .attributes: inspectorVC.attributesVC.zoomReset()
        case .preview:    previewPaneVC.zoomReset()
        }
    }

    // MARK: Pane visibility, v0.24.0 rebuild
    //
    // Closing a pane now REMOVES it from its split view entirely
    // instead of setting isHidden. The old hide-in-place left a
    // ghost: the hidden pane's divider stayed draggable and its
    // frame could be re-inflated by any divider drag or setPosition
    // near it: closing Subtags and then resizing Hierarchy brought
    // the Subtags pane back. With removal there is nothing left in
    // the layout to resurrect; Show re-inserts at the remembered
    // index with the remembered size.

    private struct ClosedPane {
        let split: NSSplitView
        let index: Int
        let extent: CGFloat
    }
    private var closedPanes: [ObjectIdentifier: ClosedPane] = [:]

    private func isPaneClosed(_ v: NSView?) -> Bool {
        guard let v else { return false }
        return closedPanes[ObjectIdentifier(v)] != nil
    }

    private func hidePane(_ v: NSView) {
        let key = ObjectIdentifier(v)
        guard closedPanes[key] == nil,
              let split = v.superview as? NSSplitView,
              let idx = split.arrangedSubviews.firstIndex(of: v) else { return }
        let extent = split.isVertical ? v.frame.width : v.frame.height
        closedPanes[key] = ClosedPane(split: split, index: idx, extent: extent)
        v.removeFromSuperview()
        // Re-tile FIRST: without adjustSubviews the remaining panes
        // keep their old frames and the removed pane's strip stays
        // as dead grey background, which is what showed up after
        // closing Hierarchy. Then apply our proportional pass on top.
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        layoutSplit(split)
    }

    private func showPane(_ v: NSView) {
        let key = ObjectIdentifier(v)
        guard let entry = closedPanes[key] else { return }
        closedPanes.removeValue(forKey: key)
        let split = entry.split
        let clamped = min(entry.index, split.arrangedSubviews.count)
        split.insertArrangedSubview(v, at: clamped)
        v.isHidden = false
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        layoutSplit(split, overrides: [key: max(entry.extent, 80)])
        // layoutSplit shares space proportionally, which returned the
        // pane a few points narrower every time (7 px per dock in Edit
        // and Inspect, measured). Pin the exact remembered extent last.
        restorePaneExtent(split: split, at: clamped, extent: max(entry.extent, 80))
        split.layoutSubtreeIfNeeded()
    }

    private func togglePane(view: NSView?) {
        guard let v = view else { return }
        if isPaneClosed(v) { showPane(v) } else { hidePane(v) }
    }

    // Single-pass deterministic layout for one split: minimized panes
    // get exactly the header height, everything else shares the rest
    // proportionally (or per `overrides`). Replaces the pane-by-pane
    // setPosition calls whose divider arithmetic broke whenever the
    // LAST pane was minimized (its space silently re-expanded the
    // neighbor, leaving a big empty area).
    private func layoutSplit(_ split: NSSplitView, overrides: [ObjectIdentifier: CGFloat] = [:]) {
        let subs = split.arrangedSubviews
        guard subs.count > 1 else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let dividers = CGFloat(subs.count - 1) * split.dividerThickness
        let avail = total - dividers
        guard avail > 40 else { return }

        var desired = [CGFloat](repeating: 0, count: subs.count)
        var flexIdx: [Int] = []
        var flexTotal: CGFloat = 0
        var fixedSum: CGFloat = 0
        for (i, v) in subs.enumerated() {
            let key = ObjectIdentifier(v)
            if minimizedPanes.contains(key) {
                desired[i] = minimizedExtent(for: v)
                fixedSum += minimizedExtent(for: v)
            } else {
                let want = overrides[key] ?? max(split.isVertical ? v.frame.width : v.frame.height, 1)
                desired[i] = want
                flexIdx.append(i)
                flexTotal += want
            }
        }
        let flexAvail = max(0, avail - fixedSum)
        if !flexIdx.isEmpty, flexTotal > 0 {
            for i in flexIdx { desired[i] = desired[i] / flexTotal * flexAvail }
            // Usability floor: one pane expanding (huge override) must
            // not crush its open siblings to slivers, and inspector-
            // column panes keep their real minimums so their internal
            // layout never breaks (headers piling into each other).
            if flexIdx.count > 1 {
                for i in flexIdx {
                    let floorH = viewFloor(subs[i])
                    if desired[i] < floorH,
                       let maxI = flexIdx.max(by: { desired[$0] < desired[$1] }),
                       maxI != i, desired[maxI] - (floorH - desired[i]) > viewFloor(subs[maxI]) {
                        desired[maxI] -= (floorH - desired[i])
                        desired[i] = floorH
                    }
                }
            }
        } else if let last = desired.indices.last {
            // Every pane minimized, park the leftover on the bottom
            // pane; its content is hidden so it reads as clean glass.
            desired[last] += flexAvail
        }
        var pos: CGFloat = 0
        for i in 0..<(subs.count - 1) {
            pos += desired[i]
            split.setPosition(pos, ofDividerAt: i)
            pos += split.dividerThickness
        }
    }

    // MARK: View menu, Show ▸ / Hide ▸ submenus

    @objc func togglePaneTree(_ sender: Any?)       { togglePane(view: treeGlass) }
    @objc func togglePaneSource(_ sender: Any?)     { togglePane(view: sourceContainerView) }
    @objc func togglePaneInspector(_ sender: Any?)  { togglePane(view: inspectorColumnSplit) }
    @objc func togglePaneSubtags(_ sender: Any?)    { togglePane(view: subtagsGlass) }
    @objc func togglePaneHierarchy(_ sender: Any?)  { togglePane(view: hierarchyGlass) }
    @objc func togglePaneChart(_ sender: Any?) {
        UserDefaults.standard.set("Chart", forKey: Self.detailSelectionKey)
        applyDetailSelection(persist: true)
    }

    @objc func togglePaneMinimap(_ sender: Any?) {
        let willHide = !minimap.isHidden
        minimap.isHidden = willHide
        minimapWidthCon?.constant = willHide ? 0 : XMMetric.s(XMMetric.minimapW)
    }

    // Show ▸ / Hide ▸ menu items carry the pane title in
    // representedObject; only applicable items stay enabled.
    @objc func menuShowPane(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        if title == "Minimap" {
            if minimap.isHidden { togglePaneMinimap(nil) }
            return
        }
        if title == "Details" {
            if let column = inspectorColumnSplit, isPaneClosed(column) { showPane(column) }
            applyDetailSelection(persist: false)
            return
        }
        guard let (chrome, glass) = paneRegistry[title] else { return }
        if isPaneClosed(glass) { showPane(glass) }
        // "Show" also expands a minimized pane, that's what a user
        // asking to SEE the pane means.
        if chrome.isMinimized { toggleMinimize(chrome: chrome, glass: glass, title: title) }
    }

    @objc func menuHidePane(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        if title == "Minimap" {
            if !minimap.isHidden { togglePaneMinimap(nil) }
            return
        }
        if title == "Details" {
            if let column = inspectorColumnSplit, !isPaneClosed(column) { hidePane(column) }
            return
        }
        guard let (_, glass) = paneRegistry[title] else { return }
        if !isPaneClosed(glass) { hidePane(glass) }
    }

    // Pop a pane out into its own floating NSWindow, or re-dock it
    // if it's already detached. Avoids the split-view layout glitch
    // the old hide-siblings "maximize" caused, and matches the
    // simpler mental model of popping a pane out.
    private func togglePopOut(chrome: PaneChrome, glass: NSView, title: String) {
        if ["Tree", "Source", "Subtags", "Hierarchy"].contains(title) {
            togglePaneWindow(title: title, glass: glass)
            return
        }
        let key = ObjectIdentifier(glass)
        if let entry = popouts[key] {
            dockPane(entry: entry, closeWindow: true)
            relayoutAfterDock()
            return
        }
        guard let parent = glass.superview as? NSSplitView,
              let idx = parent.arrangedSubviews.firstIndex(of: glass) else { return }

        autoCollapsing = true
        parent.removeArrangedSubview(glass)
        glass.removeFromSuperview()
        parent.adjustSubviews()
        autoCollapsing = false

        // Default size proportional to the screen (a fixed 720×520
        // looked either huge on the MacBook panel or tiny on an
        // external monitor); each pane also remembers its own frame
        // across pop-outs via the per-title autosave name below.
        let vis = window?.screen?.visibleFrame.size
            ?? NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1280, height: 800)
        let initialFrame = NSRect(x: 0, y: 0,
                                  width: max(480, min(860, vis.width * 0.45)),
                                  height: max(380, min(640, vis.height * 0.55)))
        let win = NSWindow(contentRect: initialFrame,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = title
        // Hard floor: below this the pane's own minimum content
        // (headers + a few table rows) can't lay out meaningfully.
        win.minSize = NSSize(width: 380, height: 300)
        // Follow the active theme, hardcoded .darkAqua left popped-out
        // panes dark while the rest of the app ran the Light theme.
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        // Critical for the re-dock crash fix:
        //   animationBehavior = .none → suppresses the open/close
        //     transform animation that AppKit otherwise retains on
        //     the window's content view tree. The v0.13.2 crash was
        //     in _NSWindowTransformAnimation.dealloc over-releasing
        //     a child that we'd re-parented out of the window.
        //   isReleasedWhenClosed = false → we own the window's
        //     lifetime via `popouts`; AppKit must NOT auto-release
        //     it on close() or we double-free.
        win.animationBehavior = .none
        win.isReleasedWhenClosed = false
        let host = NSView(frame: initialFrame)
        host.wantsLayer = true
        host.layer?.backgroundColor = XMColor.bg.cgColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            glass.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            glass.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            glass.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
        win.contentView = host
        win.center()
        win.level = Self.popoutsFloat ? .floating : .normal
        win.setFrameAutosaveName("xml-mackerPopout-\(title)")
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        if !Self.popoutsFloat, let main = window, win.parent == nil, win != main {
            main.addChildWindow(win, ordered: .above)
        }

        let extent = parent.isVertical ? glass.frame.width : glass.frame.height
        popouts[key] = PopoutEntry(glass: glass, chrome: chrome, window: win,
                                   originSplit: parent, originIndex: idx,
                                   originExtent: extent)
        chrome.isPoppedOut = true
        // The window's own title bar carries the name; the pane keeps a
        // slim header with just the grey ↙ so it can dock back from the
        // same spot. Closing the window docks it too (windowWillClose).
        chrome.showDockOnlyHeader(true)
    }

    @objc private func detailSectionChanged(_ sender: NSSegmentedControl) {
        guard detailTitles.indices.contains(sender.selectedSegment) else { return }
        let title = detailTitles[sender.selectedSegment]
        UserDefaults.standard.set(title, forKey: Self.detailSelectionKey)
        applyDetailSelection(persist: true)
        statusLabel.stringValue = "Showing \(title)"
    }

    private func selectedDetailTitle() -> String {
        let saved = UserDefaults.standard.string(forKey: Self.detailSelectionKey) ?? "Inspector"
        return detailTitles.contains(saved) ? saved : "Inspector"
    }

    private func detailView(for title: String) -> NSView {
        switch title {
        case "Chart": return chartPaneVC.view
        case "Preview": return previewPaneVC.view
        case "Errors": return errorsPaneVC.view
        default: return inspectorVC.view
        }
    }

    /// Mounts exactly one view inside a conventional inspector rail. There
    /// are no nested dividers and no pane-level traffic-light controls: the
    /// segmented control is the sole navigation model.
    private func applyDetailSelection(persist: Bool) {
        guard let column = inspectorColumnSplit else { return }
        let activeTitle = selectedDetailTitle()
        if persist { UserDefaults.standard.set(activeTitle, forKey: Self.detailSelectionKey) }
        detailSelector.selectedSegment = detailTitles.firstIndex(of: activeTitle) ?? 0

        isApplyingDetailSelection = true
        autoCollapsing = true
        defer {
            autoCollapsing = false
            isApplyingDetailSelection = false
        }

        let selectedView = detailView(for: activeTitle)
        if mountedDetailTitle != activeTitle || selectedView.superview !== detailContentHost {
            detailContentHost.subviews.forEach { $0.removeFromSuperview() }
            selectedView.removeFromSuperview()
            selectedView.translatesAutoresizingMaskIntoConstraints = false
            detailContentHost.addSubview(selectedView)
            NSLayoutConstraint.activate([
                selectedView.topAnchor.constraint(equalTo: detailContentHost.topAnchor),
                selectedView.leadingAnchor.constraint(equalTo: detailContentHost.leadingAnchor),
                selectedView.trailingAnchor.constraint(equalTo: detailContentHost.trailingAnchor),
                selectedView.bottomAnchor.constraint(equalTo: detailContentHost.bottomAnchor),
            ])
            mountedDetailTitle = activeTitle
        }
        // Clear any legacy accordion state left in UserDefaults/runtime.
        for glass in [inspectorGlass, chartGlass, previewGlass].compactMap({ $0 }) {
            minimizedPanes.remove(ObjectIdentifier(glass))
        }
        inspectorChrome?.isMinimized = false
        chartChrome?.isMinimized = false
        previewChrome?.isMinimized = false
        column.adjustSubviews()
        column.layoutSubtreeIfNeeded()
    }

    // Minimize a pane: shrink it along its split-axis to just the
    // PaneChrome header height (≈ 26 pt). The freed space is taken
    // by the adjacent panes since NSSplitView redistributes on
    // setPosition. Un-minimize restores the saved extent.
    // Minimized-pane titles persisted across launches. First launch
    // defaults the right-column panes (Inspector, Chart, Preview) to
    // minimized, so the app opens uncluttered and a pane only takes
    // space once it is clicked open.
    static let minimizedPanesKey = "xml-macker.minimizedPaneTitles"

    private func persistMinimized(title: String, minimized: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.minimizedPanesKey) ?? [])
        if minimized { set.insert(title) } else { set.remove(title) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.minimizedPanesKey)
    }

    // Applies the saved (or first-run default) minimized set once the
    // initial layout has real frames. Called from the deferred layout
    // block after applyPaneLayout()/applyWorkspace().
    func applySavedMinimizedPanes() {
        // Fallback is EMPTY now, the three right panes open with
        // equal space instead of minimized; minimizing them on first
        // launch turned out not to be worth it.
        let titles = Set(UserDefaults.standard.stringArray(forKey: Self.minimizedPanesKey) ?? [])
        // Flip all the flags first, then lay out each affected split
        // ONCE, applying pane-by-pane made later panes' divider moves
        // undo earlier ones (the "default is not as intended" bug).
        var splits: Set<ObjectIdentifier> = []
        var splitViews: [NSSplitView] = []
        for title in titles {
            // The focused right rail owns these three states; old saved
            // minimize flags must not resurrect the unusable equal stack.
            if detailTitles.contains(title) { continue }
            guard let (chrome, glass) = paneRegistry[title],
                  !chrome.isMinimized, !isPaneClosed(glass),
                  let split = glass.superview as? NSSplitView else { continue }
            let key = ObjectIdentifier(glass)
            minimizeSaved[key] = split.isVertical ? glass.frame.width : glass.frame.height
            minimizedPanes.insert(key)
            chrome.isMinimized = true
            if splits.insert(ObjectIdentifier(split)).inserted { splitViews.append(split) }
        }
        for split in splitViews { layoutSplit(split) }
    }

    // Green button: expand the pane IN PLACE. A minimized pane
    // expands back down to its saved size; a normal pane grows to
    // take its column's spare space; clicking again restores.
    // The restore snapshot covers the WHOLE column, not just the
    // expanded pane, restoring one pane's extent and letting the
    // siblings re-share proportionally drifted a little every
    // click: repeated clicks kept moving the panes below.
    private var expandSaved: [ObjectIdentifier: [ObjectIdentifier: CGFloat]] = [:]
    private var expandedPanes: Set<ObjectIdentifier> = []

    private func toggleExpand(chrome: PaneChrome, glass: NSView, title: String) {
        // Minimized? Green means "show it": the pane expands back
        // down, nothing else.
        if chrome.isMinimized {
            toggleMinimize(chrome: chrome, glass: glass, title: title)
            return
        }
        let key = ObjectIdentifier(glass)
        guard let split = glass.superview as? NSSplitView else { return }
        if expandedPanes.contains(key) {
            expandedPanes.remove(key)
            chrome.isMaximized = false
            let snapshot = expandSaved.removeValue(forKey: key) ?? [:]
            layoutSplit(split, overrides: snapshot)
        } else {
            var snapshot: [ObjectIdentifier: CGFloat] = [:]
            for v in split.arrangedSubviews {
                snapshot[ObjectIdentifier(v)] = split.isVertical ? v.frame.width : v.frame.height
            }
            expandSaved[key] = snapshot
            expandedPanes.insert(key)
            chrome.isMaximized = true
            // A huge override → the proportional pass gives this pane
            // essentially everything the minimized siblings leave.
            layoutSplit(split, overrides: [key: 100_000])
        }
    }

    // Content minimum per pane, below these the pane's internal
    // Auto Layout breaks and headers overlap.
    private func paneFloor(_ title: String) -> CGFloat {
        switch title {
        case "Inspector": return 210
        case "Chart":     return 110
        case "Preview":   return 120
        default:          return 90
        }
    }
    private func viewFloor(_ v: NSView) -> CGFloat {
        if let entry = paneRegistry.first(where: { $0.value.glass === v }) {
            return paneFloor(entry.key)
        }
        return 90
    }

    // MARK: Auto-collapse under pressure (v0.27.2)
    //
    // When the right column is squeezed (dragging the Subtags strip
    // up, shrinking the window), panes auto-minimize from the BOTTOM
    // to just their title bar instead of crushing into each other, 
    // and auto-restore, most recent first, when space returns. Panes
    // the USER minimized stay minimized (we track our own separately
    // and never persist auto state).
    private var autoMinimized: [ObjectIdentifier] = []   // stack, most recent last
    private var autoCollapsing = false
    private var isApplyingDetailSelection = false

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !autoCollapsing,
              let sv = notification.object as? NSSplitView,
              sv === inspectorColumnSplit || sv === rootVSplit || sv === topHSplit else { return }
        if sv === inspectorColumnSplit { return }
        autoCollapseRightColumn()
    }

    private func autoCollapseRightColumn() {
        guard let col = inspectorColumnSplit else { return }
        var panes: [(title: String, chrome: PaneChrome, glass: NSView)] = []
        for v in col.arrangedSubviews {
            if let entry = paneRegistry.first(where: { $0.value.glass === v }) {
                panes.append((entry.key, entry.value.chrome, entry.value.glass))
            }
        }
        guard panes.count > 1 else { return }
        let H = col.bounds.height
        guard H > 50 else { return }
        let dividers = CGFloat(max(0, col.arrangedSubviews.count - 1)) * col.dividerThickness
        func needed() -> CGFloat {
            dividers + panes.reduce(0) { acc, p in
                acc + (p.chrome.isMinimized ? minimizedExtent : paneFloor(p.title))
            }
        }
        autoCollapsing = true
        defer { autoCollapsing = false }
        var changed = false
        // Squeeze: minimize bottom-up until the floors fit.
        var i = panes.count - 1
        while needed() > H, i >= 0 {
            let p = panes[i]; i -= 1
            guard !p.chrome.isMinimized else { continue }
            p.chrome.isMinimized = true
            minimizedPanes.insert(ObjectIdentifier(p.glass))
            autoMinimized.append(ObjectIdentifier(p.glass))
            changed = true
        }
        // Relax: restore what WE minimized, most recent first.
        while let key = autoMinimized.last {
            guard let p = panes.first(where: { ObjectIdentifier($0.glass) == key }) else {
                autoMinimized.removeLast(); continue
            }
            guard needed() - minimizedExtent + paneFloor(p.title) <= H else { break }
            p.chrome.isMinimized = false
            minimizedPanes.remove(key)
            autoMinimized.removeLast()
            changed = true
        }
        // Even when no fold/unfold happened, the outer squeeze may
        // have left frames violating the floors (adjustSubviews
        // scales proportionally without consulting them), that's
        // how the Inspector's title bar ended up sliding under the
        // pane above. Normalize whenever any open pane is short.
        if !changed {
            changed = panes.contains { p in
                !p.chrome.isMinimized &&
                (col.isVertical ? p.glass.frame.width : p.glass.frame.height) + 0.5 < paneFloor(p.title)
            }
        }
        if changed { layoutSplit(col) }
    }

    private func toggleMinimize(chrome: PaneChrome, glass: NSView, title: String) {
        let key = ObjectIdentifier(glass)
        guard let split = glass.superview as? NSSplitView else { return }
        if split === inspectorColumnSplit, detailTitles.contains(title) {
            // The compact headers double as an accordion. Restoring one pane
            // automatically folds the previous pane instead of recreating the
            // three-panel squeeze. The active pane remains open.
            if chrome.isMinimized {
                UserDefaults.standard.set(title, forKey: Self.detailSelectionKey)
                applyDetailSelection(persist: true)
            } else {
                NSSound.beep()
            }
            return
        }
        if chrome.isMinimized {
            // Un-minimize: restore prior extent via the single-pass
            // column layout (per-divider setPosition was what broke
            // last-pane minimize).
            chrome.isMinimized = false
            minimizedPanes.remove(key)
            let prior = minimizeSaved.removeValue(forKey: key) ?? 200
            layoutSplit(split, overrides: [key: max(prior, 80)])
            persistMinimized(title: title, minimized: false)
        } else {
            let current = split.isVertical ? glass.frame.width : glass.frame.height
            minimizeSaved[key] = current
            minimizedPanes.insert(key)
            chrome.isMinimized = true
            layoutSplit(split)
            persistMinimized(title: title, minimized: true)
        }
    }

    // Returns how much MIN the pane at `paneIdx` in `split` should
    // contribute right now. Normal value from our delegate, 26pt if
    // the pane is minimized, and ZERO when it's closed (hidden), 
    // counting a closed pane's min let a divider drag re-inflate it
    // ("the subtag came back!"): the drag was being clamped as though
    // the hidden pane still needed its 80 pt.
    private func effectiveMin(for pane: NSView?, fallback: CGFloat) -> CGFloat {
        guard let pane else { return fallback }
        if pane.isHidden { return 0 }
        return minimizedPanes.contains(ObjectIdentifier(pane)) ? minimizedExtent(for: pane) : fallback
    }

    // Hide the divider that belongs to a closed pane, its grab area
    // was still draggable, and dragging it resurrected the pane.
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        let subs = splitView.arrangedSubviews
        if dividerIndex < subs.count, subs[dividerIndex].isHidden { return true }
        if dividerIndex + 1 < subs.count, subs[dividerIndex + 1].isHidden { return true }
        return false
    }

    // Restore the pane to its prior extent (width for side-by-side
    // splits, height for stacked splits). Without this, re-docking
    // shows the pane at its minimum size and the user has to drag
    // the divider back by hand.
    private func restorePaneExtent(split: NSSplitView, at paneIdx: Int, extent: CGFloat) {
        let subs = split.arrangedSubviews
        guard paneIdx < subs.count else { return }
        let pane = subs[paneIdx]
        if split.isVertical {
            // Side-by-side. Divider positions are X from left.
            if paneIdx < subs.count - 1 {
                split.setPosition(pane.frame.minX + extent, ofDividerAt: paneIdx)
            } else if paneIdx > 0 {
                split.setPosition(split.bounds.width - extent, ofDividerAt: paneIdx - 1)
            }
        } else {
            // Stacked. Divider positions are Y from top.
            if paneIdx < subs.count - 1 {
                split.setPosition(pane.frame.minY + extent, ofDividerAt: paneIdx)
            } else if paneIdx > 0 {
                split.setPosition(split.bounds.height - extent, ofDividerAt: paneIdx - 1)
            }
        }
    }

    // Where a docking pane belongs: Inspector above Chart above
    // Preview in the right column; other splits use the remembered
    // index.
    private func canonicalDockIndex(title: String, in split: NSSplitView, fallback: Int) -> Int {
        guard split === inspectorColumnSplit else {
            return min(fallback, split.arrangedSubviews.count)
        }
        let rank: [String: Int] = ["INSPECTOR": 0, "CHART": 1, "PREVIEW": 2]
        let my = rank[title.uppercased()] ?? 3
        var idx = 0
        for v in split.arrangedSubviews {
            if let entry = paneRegistry.first(where: { $0.value.glass === v }),
               let r = rank[entry.key.uppercased()], r < my {
                idx += 1
            }
        }
        return idx
    }

    // The live content view for a pane title, used to re-mount the
    // pane's content with fresh constraints after a window migration.
    private func paneContentView(for title: String) -> NSView? {
        switch title.uppercased() {
        case "INSPECTOR": return inspectorVC.view
        case "CHART":     return chartPaneVC.view
        case "PREVIEW":   return previewPaneVC.view
        case "ERRORS":    return errorsPaneVC.view
        case "TREE":      return treeVC.view
        case "SOURCE":    return sourceVC.view
        case "SUBTAGS":   return subtagsBarVC.view
        case "HIERARCHY": return hierarchyBarVC.view
        default:          return nil
        }
    }

    private func horizontalKick() {
        guard let top = topHSplit, top.arrangedSubviews.count > 1 else { return }
        autoCollapsing = true
        defer { autoCollapsing = false }
        let pos = top.arrangedSubviews[0].frame.width
        top.setPosition(pos - 3, ofDividerAt: 0)
        top.layoutSubtreeIfNeeded()
        top.setPosition(pos + 3, ofDividerAt: 0)
        top.layoutSubtreeIfNeeded()
        top.setPosition(pos, ofDividerAt: 0)
        top.layoutSubtreeIfNeeded()
    }

    // Equal share for every OPEN pane in the right column; minimized
    // ones keep their 26-pt bar.
    private func resetInspectorColumn() {
        guard let col = inspectorColumnSplit else { return }
        // NOTE: no reordering here, order is guaranteed at insert
        // time (canonicalDockIndex); a reorder would reparent every
        // pane a second time and re-break their rendering.
        let open = col.arrangedSubviews.filter { !minimizedPanes.contains(ObjectIdentifier($0)) }
        guard !open.isEmpty else { return }
        let share = max(120, col.bounds.height / CGFloat(open.count))
        var overrides: [ObjectIdentifier: CGFloat] = [:]
        for v in open { overrides[ObjectIdentifier(v)] = share }
        layoutSplit(col, overrides: overrides)
        col.layoutSubtreeIfNeeded()
        // NOTE: the render heal after docking is horizontalKick()
        // (dockPane), the width change of the tall divider, the same
        // gesture that fixes it by hand. Earlier vertical shakes
        // (window nudge, warmup passes, hide/show cycles) never
        // healed and were removed.
    }

    // The automated version of the manual fix (drag a divider a
    // little and the view adjusts): grow the WINDOW one point and
    // shrink it back. Divider-level nudges were clamped to a net-zero
    // move by the layout floors, a window resize can't be clamped, so
    // every pane's frame genuinely changes and re-renders.
    private func nudge(_ split: NSSplitView) {
        guard let win = window else { return }
        autoCollapsing = true
        defer { autoCollapsing = false }
        var f = win.frame
        f.size.height += 1
        win.setFrame(f, display: true)
        f.size.height -= 1
        win.setFrame(f, display: true)
        func repaint(_ v: NSView) {
            v.needsDisplay = true
            v.subviews.forEach(repaint)
        }
        repaint(split)
    }

    // Re-entrant-safe re-dock. The crash in v0.13.2 was
    // EXC_BAD_ACCESS when closing a popped-out pane's window because
    // the old dockPane called window.close() which synchronously
    // triggered windowWillClose → which tried to look the entry up
    // again in a second dict that had already been cleared. This
    // version uses a single struct + a re-entry guard.
    // A pane coming home re-applies the current workspace mode from
    // scratch, exactly as if its toolbar button were clicked again:
    // that is the one layout path known to be right, and it beats
    // trusting the re-inserted pane's old geometry.
    private func relayoutAfterDock() {
        let mode = currentWorkspaceMode
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyWorkspace(mode, save: false, preserveGeometry: false)
            self.window?.contentView?.needsLayout = true
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Floating pane windows (no view reparenting, v1.0.7)

    private var paneWindows: [String: PanePopoutWindowController] = [:]
    private var popTree: TreeViewController?
    private var popSubtags: SubtagsBarViewController?
    private var popHierarchy: HierarchyBarViewController?
    var popSource: SourceViewController?
    private var mirroringSelection = false

    /// The floating Source shows the SAME document: both editors share
    /// one NSTextStorage (TextKit runs any number of layout managers on
    /// one storage), so text, colors and undo are a single thing.
    /// Re-attached lazily whenever the docked editor points at another
    /// storage (tab switch, new file).
    private func syncSourceMirror() {
        guard let mirror = popSource, let storage = sourceVC.currentStorage else { return }
        _ = mirror.view
        guard mirror.currentStorage !== storage else { return }
        let s = sessions.indices.contains(activeSessionIdx) ? sessions[activeSessionIdx] : nil
        mirror.sessionUndoManager = sourceVC.sessionUndoManager
        mirror.attachSession(url: s?.url ?? currentFileURL ?? URL(fileURLWithPath: "/untitled.xml"),
                             fileSize: s?.fileSize ?? 0, storage: storage,
                             lineStarts: sourceVC.currentLineStarts,
                             scrollOrigin: sourceVC.snapshotScroll(),
                             textEncoding: s?.textEncoding ?? .utf8)
        mirror.setLineNumbersVisible(sourceVC.isLineNumbersVisible)
    }

    private func isInPaneWindow(_ v: NSView) -> Bool {
        paneRegistry.contains { $0.value.glass === v && paneWindows[$0.key] != nil }
    }

    /// Open a fresh copy of the pane in its own window (and hide the
    /// docked one), or close that window, which docks it back.
    private func togglePaneWindow(title: String, glass: NSView) {
        if let existing = paneWindows[title] { existing.close(); return }
        let vc: NSViewController
        switch title {
        case "Tree":
            let t = TreeViewController()
            t.onSelectNode = { [weak self] node in
                guard let self, !self.mirroringSelection else { return }
                self.treeVC.select(node: node, expandAncestors: true)
            }
            t.onContextAction = { [weak self] node, action in
                self?.handleTreeContext(node: node, action: action)
            }
            t.resolveLinkedFile = { [weak self] node in
                LinkedFile.resolve(node: node, relativeTo: self?.currentFileURL)
            }
            if let root = currentTree { t.setRoot(root) }
            popTree = t
            vc = t
        case "Subtags":
            let s = SubtagsBarViewController()
            s.onAttributeEdit = { [weak self] node, attr, value in
                self?.subtagsBarVC.onAttributeEdit?(node, attr, value)
                self?.popSubtags?.refreshValuesOnly()
            }
            s.onTextEdit = { [weak self] node, text in
                self?.subtagsBarVC.onTextEdit?(node, text)
                self?.popSubtags?.refreshValuesOnly()
            }
            s.onTagRename = { [weak self] node, name in self?.subtagsBarVC.onTagRename?(node, name) }
            s.onSubtagSelected = { [weak self] child in self?.subtagsBarVC.onSubtagSelected?(child) }
            s.onSubtagPreview = { [weak self] child in self?.subtagsBarVC.onSubtagPreview?(child) }
            if let node = currentSelectedNode { s.setNode(node) }
            popSubtags = s
            vc = s
        case "Hierarchy":
            let h = HierarchyBarViewController()
            h.onChildClicked = { [weak self] child in
                self?.treeVC.select(node: child, expandAncestors: true)
            }
            if let node = currentSelectedNode { h.setNode(node) }
            popHierarchy = h
            vc = h
        case "Source":
            let sv = SourceViewController()
            _ = sv.view
            sv.linkedFileResolver = { [weak self] text in
                LinkedFile.resolve(text, relativeTo: self?.currentFileURL)
            }
            (sv.exposedTextView as? HighlightingTextView)?.linkedFileResolver = { [weak self] text in
                LinkedFile.resolve(text, relativeTo: self?.currentFileURL)
            }
            (sv.exposedTextView as? HighlightingTextView)?.onOpenLinkedFile = { [weak self] url in
                self?.openFiles([url])
            }
            popSource = sv
            syncSourceMirror()
            if let node = currentSelectedNode { sv.showElement(node) }
            vc = sv
        default:
            return
        }
        // The Source pane's slot in the split is its container (glass +
        // minimap), the same view the View menu hides and shows.
        let hideTarget: NSView = (title == "Source" ? sourceContainerView : nil) ?? glass
        if !isPaneClosed(hideTarget) { hidePane(hideTarget) }
        let wc = PanePopoutWindowController(title: title, content: vc)
        wc.onDock = { [weak self] in
            guard let self else { return }
            self.paneWindows.removeValue(forKey: title)
            switch title {
            case "Tree":      self.popTree = nil
            case "Subtags":   self.popSubtags = nil
            case "Hierarchy": self.popHierarchy = nil
            case "Source":
                // Unhook the mirror's layout manager from the shared
                // storage BEFORE it dies (replaceTextStorage would drag
                // the docked editor along; removeLayoutManager does not).
                if let mirror = self.popSource {
                    NotificationCenter.default.removeObserver(mirror)
                    if let lm = mirror.exposedTextView.layoutManager,
                       let shared = mirror.currentStorage, shared === self.sourceVC.currentStorage {
                        shared.removeLayoutManager(lm)
                    }
                }
                self.popSource = nil
            default: break
            }
            if self.isPaneClosed(hideTarget) { self.showPane(hideTarget) }
            self.relayoutAfterDock()
        }
        paneWindows[title] = wc
        wc.show(attachedTo: window)
        if let root = currentTree, let pt = popTree, let node = currentSelectedNode {
            _ = root
            mirroringSelection = true
            pt.select(node: node, expandAncestors: true)
            mirroringSelection = false
        }
    }

    private func dockPane(entry: PopoutEntry, closeWindow: Bool) {
        let key = ObjectIdentifier(entry.glass)
        if docking.contains(key) { return }
        docking.insert(key)
        defer { docking.remove(key) }

        // Break the parent link before the window is torn down; a parent
        // keeps a strong reference to its children.
        if let p = entry.window.parent { p.removeChildWindow(entry.window) }

        // Re-parent FIRST, while the window still exists and is a
        // valid parent. Doing the reparent after close() was racing
        // AppKit's close-animation teardown and corrupting the
        // autorelease pool (EXC_BAD_ACCESS in
        // _NSWindowTransformAnimation.dealloc).
        // Suppress the auto-collapse watcher while frames are in
        // flux, it was catching the transiently-tiny re-inserted
        // pane and folding it to a 26-pt bar, which read as "the
        // pane never came back" when un-popping.
        autoCollapsing = true
        entry.glass.removeFromSuperview()
        // Insert straight into the pane's canonical slot. The old
        // insert-then-reorder approach reparented EVERY pane a second
        // time, which is what kept re-breaking their rendering, 
        // Preview only ever worked because its slot is last, so the
        // reorder skipped itself.
        let clamped = canonicalDockIndex(title: entry.chrome.title, in: entry.originSplit,
                                         fallback: entry.originIndex)
        entry.originSplit.insertArrangedSubview(entry.glass, at: clamped)
        entry.originSplit.adjustSubviews()
        // Force a synchronous layout pass so the newly-inserted
        // arranged subview has a real frame; otherwise setPosition
        // in restorePaneExtent reads minX/minY = 0 and the pane
        // snaps to minimum. Then restore and layout again so the
        // divider move actually paints.
        entry.originSplit.layoutSubtreeIfNeeded()
        restorePaneExtent(split: entry.originSplit, at: clamped, extent: entry.originExtent)
        entry.originSplit.layoutSubtreeIfNeeded()
        // Second pass on the next runloop, NSSplitView sometimes
        // reacts to the first setPosition by re-normalizing through
        // the delegate and clamps our target. A second pass lands.
        let split = entry.originSplit
        let paneIdx = clamped
        let extent = entry.originExtent
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autoCollapsing = true
            self.restorePaneExtent(split: split, at: paneIdx, extent: extent)
            self.autoCollapsing = false
            self.autoCollapseRightColumn()
        }
        autoCollapsing = false
        entry.chrome.isPoppedOut = false
        entry.chrome.showDockOnlyHeader(false)
        entry.glass.isHidden = false
        entry.glass.needsDisplay = true
        // Docking into the right column? Reset it to the clean equal
        // arrangement so the three panes share it evenly again.
        if entry.originSplit === inspectorColumnSplit {
            resetInspectorColumn()
        }
        // A pane coming home always arrives fully OPEN: stale
        // minimize flags (from an auto-collapse before the pop-out)
        // left the pane tall but with its content hidden, the
        // "grey with nothing in it" state.
        minimizedPanes.remove(key)
        minimizeSaved.removeValue(forKey: key)
        autoMinimized.removeAll { $0 == key }
        entry.chrome.isMinimized = false
        // Full re-mount: fresh glass binding to the new window +
        // freshly re-pinned content constraints. Surgical repairs
        // (repaint, nudge) kept leaving stale render state behind.
        (entry.glass as? GlassPanel)?.refreshAfterWindowMove()
        if let content = paneContentView(for: entry.chrome.title) {
            entry.chrome.setContent(content)
        }
        if entry.originSplit !== inspectorColumnSplit {
            let split = entry.originSplit
            DispatchQueue.main.async { [weak self] in self?.nudge(split) }
        }
        // The manual heal that works is always a HORIZONTAL drag of
        // the tall divider, while every previous nudge here was
        // vertical. Kick the source/column divider a few pixels and
        // back on the next runloop.
        DispatchQueue.main.async { [weak self] in self?.horizontalKick() }
        Diag.log("dockPane: \(entry.window.title) back at index \(clamped), extent \(entry.originExtent)")
        window?.makeKeyAndOrderFront(nil)

        popouts.removeValue(forKey: key)

        if closeWindow {
            entry.window.delegate = nil
            // orderOut() skips the close-animation path entirely, 
            // combined with animationBehavior = .none this means no
            // _NSWindowTransformAnimation is ever constructed, so
            // there's nothing that can over-release.
            entry.window.orderOut(nil)
        }
        // Retire the husk: the hidden window stayed listed in the
        // Window menu, and "Bring All to Front" resurrected EMPTY
        // windows over the right column, which looked very messy.
        // Exclude it and strip its content so nothing can bring it
        // back.
        entry.window.isExcludedFromWindowsMenu = true
        entry.window.title = ""
        entry.window.contentView = NSView()
    }

    // MARK: Tree context actions + Find & Replace (v0.28.0)

    private func handleTreeContext(node: XMLTreeNode, action: TreeViewController.ContextAction) {
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(treePath(for: node), forType: .string)
            statusLabel.stringValue = "Path copied"
        case .copyXML:
            guard let (text, _) = elementText(node) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusLabel.stringValue = "Copied <\(node.displayLabel)> (\(text.count) characters)"
        case .cut:
            guard let (text, range) = elementText(node) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if sourceVC.performEdit(range: rangeWithTrailingNewline(range), replacement: "") {
                statusLabel.stringValue = "Cut <\(node.displayLabel)>"
                reparseFromEditor()
            }
        case .delete:
            guard let (_, range) = elementText(node) else { return }
            if sourceVC.performEdit(range: rangeWithTrailingNewline(range), replacement: "") {
                statusLabel.stringValue = "Deleted <\(node.displayLabel)>"
                reparseFromEditor()
            }
        case .deleteOthers:
            deleteSiblings(keeping: node)
        case .shareToLLM(let target):
            guard let (text, _) = elementText(node) else { return }
            let fileName = currentFileURL?.lastPathComponent ?? "document.xml"
            shareXMLText(
                text,
                promptIntroduction: "Here is the <\(node.displayLabel)> element (path: \(treePath(for: node))) from \(fileName):",
                to: target
            )
        case .printElement:
            guard let (text, _) = elementText(node, cap: 2_000_000) else { return }
            runPrint(text, jobTitle: "<\(node.displayLabel)>, \(currentFileURL?.lastPathComponent ?? "")")
        case .exportElement:
            exportElementToFile(node)
        case .openLinkedFile(let url):
            openFiles([url])
        case .defineInLearn:
            if currentWorkspaceMode != .learn { applyWorkspace(.learn, save: true) }
            guard let (text, _) = elementText(node, cap: 200_000) else {
                statusLabel.stringValue = "Element too large for chat (200 k character cap)"
                return
            }
            learnVC?.insertPrompt(learnPrompt(xml: text, what: "element <\(node.displayLabel)>"))
        case .duplicateAbove, .duplicateBelow:
            guard let (text, range) = elementText(node) else { return }
            let insertAt = action == .duplicateAbove ? range.location : NSMaxRange(range)
            let payload = action == .duplicateAbove ? text + "\n" : "\n" + text
            if sourceVC.performEdit(range: NSRange(location: insertAt, length: 0), replacement: payload) {
                statusLabel.stringValue = "Duplicated <\(node.displayLabel)>"
                reparseFromEditor()
            }
        case .findReplace:
            presentFindReplace(scope: node)
        }
    }

    // Element text + range, capped so a click on <world> in a 655 MB
    // file can't balloon memory. Beeps + explains when over the cap.
    private func elementText(_ node: XMLTreeNode, cap: Int = 100_000_000) -> (String, NSRange)? {
        guard let r = sourceVC.charRangeForElement(node), r.length > 0 else { return nil }
        guard r.length <= cap else {
            NSSound.beep()
            statusLabel.stringValue = "Element too large for this operation (over 100 M characters)"
            return nil
        }
        let (text, _) = sourceVC.substring(in: r, cap: r.length)
        return (text, r)
    }

    // When removing an element, also consume the newline that follows
    // so no blank line is left behind.
    private func rangeWithTrailingNewline(_ r: NSRange) -> NSRange {
        let full = sourceVC.fullDocumentRange
        if NSMaxRange(r) < full.length,
           (sourceVC.documentText as NSString).character(at: NSMaxRange(r)) == 0x0A {
            return NSRange(location: r.location, length: r.length + 1)
        }
        return r
    }

    // Structural edits (cut/duplicate/delete, tag-touching replaces)
    // invalidate the tree, rebuild it from the editor's live text.
    private func reparseFromEditor() {
        guard sessions.indices.contains(activeSessionIdx),
              !sessions[activeSessionIdx].isLoading else { return }
        let text = sourceVC.documentText
        let name = currentFileURL?.lastPathComponent ?? "document"
        let sessionID = sessions[activeSessionIdx].id
        let revision = activeEditRevision
        treeReparseRequestID &+= 1
        let requestID = treeReparseRequestID
        // Remember WHERE the user was (by name+key signature) so the
        // rebuilt tree re-selects and re-expands to the same spot, 
        // the reset-to-top after cut/duplicate was disorienting.
        let sig = currentSelectedNode.map { pathSignature($0) }
        statusLabel.stringValue = "Rebuilding tree…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = XMLStreamParser().parseText(text)
            DispatchQueue.main.async {
                guard let self,
                      requestID == self.treeReparseRequestID,
                      self.sessions.indices.contains(self.activeSessionIdx),
                      self.sessions[self.activeSessionIdx].id == sessionID,
                      self.activeEditRevision == revision else { return }
                result.root.name = name
                self.currentTree = result.root
                self.sessions[self.activeSessionIdx].tree = result.root
                self.sessions[self.activeSessionIdx].parseErrors = result.errors
                self.treeVC.setRoot(result.root)
                self.popTree?.setRoot(result.root)
                self.sourceVC.refreshLineStarts()
                self.popSource?.refreshLineStarts()
                self.lastParseErrors = result.errors
                self.validationWindow?.setErrors(result.errors)
                self.statusLabel.stringValue = "Tree rebuilt · \(result.nodeCount) nodes"
                let back = sig.flatMap { self.nodeMatching($0, in: result.root) }
                self.rebuildLevelIndex(for: result.root, selected: back)
                if let back {
                    self.treeVC.select(node: back, expandAncestors: true)
                }
            }
        }
    }

    // Simplified (ASCII) XML Name production: letter or "_" first,
    // then letters, digits, "-", "_", ".", ":". Guards tag renames.
    private func isValidXMLName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // (name, key-attribute value) chain from the root element down, 
    // survives a re-parse, unlike object identity.
    private func pathSignature(_ node: XMLTreeNode) -> [(String, String?)] {
        var parts: [(String, String?)] = []
        var cur: XMLTreeNode? = node
        while let n = cur, n.kind == .element {
            let key = n.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })?.value
            parts.insert((n.name, key), at: 0)
            cur = n.parent
        }
        return parts
    }

    // Deepest node matching the signature; stops early if a segment
    // vanished (e.g. the element was just deleted → its parent wins).
    private func nodeMatching(_ sig: [(String, String?)], in root: XMLTreeNode) -> XMLTreeNode? {
        var cur = root
        var best: XMLTreeNode? = nil
        for (name, key) in sig {
            let next = cur.children.first(where: { c in
                guard c.kind == .element, c.name == name else { return false }
                guard let key else { return true }
                return c.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })?.value == key
            })
            guard let n = next else { break }
            best = n
            cur = n
        }
        return best
    }

    @objc func menuFindReplace(_ sender: Any?) { presentFindReplace(scope: nil, focusReplace: true) }

    // Find & Replace pop-up panel, one instance, re-presented with
    // the requested scope (nil = whole file). The always-visible
    // toolbar search field is the quick-find; this is the full tool.
    private var findPanel: FindPanelController?

    private func presentFindReplace(scope: XMLTreeNode?, focusReplace: Bool = false) {
        let panel = findPanel ?? FindPanelController()
        findPanel = panel
        panel.source = sourceVC
        panel.pathForLine = { [weak self] line in
            guard let self, let root = self.currentTree,
                  let node = self.fastDeepestNode(containing: line, in: root) else { return "" }
            return self.treePath(for: node)
        }
        panel.onReplaced = { [weak self] find, repl in
            guard let self else { return }
            let touchy = find.contains("<") || find.contains(">")
                || repl.contains("<") || repl.contains(">")
            if touchy {
                self.reparseFromEditor()
            } else {
                self.inspectorVC.refreshValuesOnly()
                self.subtagsBarVC.refreshValuesOnly()
            }
        }
        var title: String? = nil
        var range: NSRange? = nil
        if let scope, let r = sourceVC.charRangeForElement(scope) {
            title = "<\(scope.displayLabel)>"
            range = r
        }
        panel.present(scopeTitle: title, scopeRange: range, focusReplace: focusReplace)
    }

    // Toolbar quick-search field: Return = jump to next occurrence
    // in the whole file (wraps). No buttons, no clutter.
    private var quickSearchLast: NSRange?
    @objc func quickSearchAction(_ sender: NSSearchField) {
        let needle = sender.stringValue
        guard !needle.isEmpty else { quickSearchLast = nil; return }
        let scope = sourceVC.fullDocumentRange
        let from = quickSearchLast.map { NSMaxRange($0) } ?? 0
        guard let hit = sourceVC.matchRange(of: needle, from: from, forward: true,
                                            caseSensitive: false, in: scope) else {
            NSSound.beep()
            statusLabel.stringValue = "\"\(needle)\" not found"
            quickSearchLast = nil
            return
        }
        quickSearchLast = hit
        sourceVC.revealMatch(hit)
        statusLabel.stringValue = "Line \(sourceVC.lineNumber(forOffset: hit.location))"
    }

    // Human-readable ancestor path for the chart pop-out title, e.g.
    // "scenario › region[USA] › supplysector[trn_pass] › logit-exponent"
    // so a popped-out chart says where in the tree it came from.
    // "Delete Others", remove every element sibling, keep this one.
    // Bulk destructive → confirm; ranges collected against the
    // CURRENT text, deleted back-to-front in one undo group.
    private func deleteSiblings(keeping node: XMLTreeNode) {
        guard let parent = node.parent else { NSSound.beep(); return }
        let victims = parent.children.filter { $0.kind == .element && $0 !== node }
        guard !victims.isEmpty else {
            statusLabel.stringValue = "No sibling elements to delete"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(victims.count) sibling element\(victims.count == 1 ? "" : "s")?"
        alert.informativeText = "Everything else inside <\(parent.displayLabel)> will be removed, only <\(node.displayLabel)> stays. One ⌘Z brings them all back."
        alert.addButton(withTitle: "Delete Others")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var ranges: [NSRange] = []
        for v in victims {
            if let r = sourceVC.charRangeForElement(v), r.length > 0 {
                ranges.append(rangeWithTrailingNewline(r))
            }
        }
        ranges.sort { $0.location > $1.location }
        let undo = sourceVC.exposedTextView.undoManager
        undo?.beginUndoGrouping()
        var deleted = 0
        for r in ranges where sourceVC.performEdit(range: r, replacement: "") { deleted += 1 }
        undo?.endUndoGrouping()
        statusLabel.stringValue = "Deleted \(deleted) element\(deleted == 1 ? "" : "s"), only <\(node.displayLabel)> remains"
        reparseFromEditor()
    }

    /// The element opens ALONE as a new document in a new tab, rather
    /// than asking where to save it. You can look at it, edit it and
    /// compare it straight away, and Save then asks where it belongs.
    fileprivate func exportElementToFile(_ node: XMLTreeNode) {
        guard let (text, _) = elementText(node) else { return }
        var out = text
        if !out.hasPrefix("<?xml") {
            out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + out
        }
        let key = node.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })?.value
        let safeKey = key?.replacingOccurrences(of: "/", with: "-")
        let name = safeKey.map { "\(node.displayLabel)_\($0).xml" } ?? "\(node.displayLabel).xml"
        openScratchDocument(text: out, named: name)
        statusLabel.stringValue = "Opened <\(node.displayLabel)> as a new document"
    }

    private func treePath(for node: XMLTreeNode) -> String {
        var parts: [String] = []
        var cur: XMLTreeNode? = node
        while let n = cur, n.kind == .element {
            // Each segment carries its key attribute value so the
            // chart is unambiguous about WHICH region/sector it
            // shows: region[USA] › supplysector[trn_pass] › …
            var seg = n.name
            if let a = n.attributes.first(where: { ["name", "year", "type", "id", "key"].contains($0.name) })
                       ?? n.attributes.first {
                seg += "[\(a.value)]"
            }
            parts.insert(seg, at: 0)
            cur = n.parent
        }
        return parts.joined(separator: " › ")
    }

    private func openChartPopout() {
        let path = currentSelectedNode.map { treePath(for: $0) } ?? ""
        if let existing = chartPopout {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.setMirroredSeries(chartPaneVC.currentTrendSeries, path: path, node: currentSelectedNode, documentRoot: currentTree)
            return
        }
        let w = ChartPopoutWindowController()
        w.onClose = { [weak self] in self?.chartPopout = nil }
        w.onRevealNode = { [weak self] node in self?.treeVC.select(node: node, expandAncestors: true) }
        w.setMirroredSeries(chartPaneVC.currentTrendSeries, path: path, node: currentSelectedNode, documentRoot: currentTree)
        w.placeNearMainWindow(window)
        w.installZoomMonitor()
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
        // Child of the main window: always visible with the app, never
        // over another application.
        if !Self.popoutsFloat, let cw = w.window, let main = window, cw.parent == nil, cw != main {
            main.addChildWindow(cw, ordered: .above)
        }
        chartPopout = w
    }

    // MARK: Tour (first launch, and Help ▸ Show Tour)

    static let tourShownKey = "xml-macker.tourShown"
    private var tour: TourWindowController?

    private func screenRect(of view: NSView?) -> NSRect? {
        guard let v = view, let w = v.window, !v.isHiddenOrHasHiddenAncestor else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }

    private func tourAnchor(_ name: String) -> NSRect? {
        switch name {
        case "workspace": return screenRect(of: toolbarHelper?.workspaceSegment)
        case "diff":      return screenRect(of: toolbarHelper?.diffButton)
        case "search":    return screenRect(of: toolbarHelper?.searchField)
        case "find":      return screenRect(of: toolbarHelper?.findButton)
        case "orbit":     return screenRect(of: toolbarHelper?.orbitButton)
        case "marker":    return screenRect(of: markerButton)
        case "details":   return screenRect(of: detailSelector)
        case "minimap":   return screenRect(of: minimap)
        case "zoom":
            let parts: [NSView] = [zoomMinusButton, zoomSlider, zoomPlusButton, zoomPercentLabel, zoomResetButton]
            let rects = parts.compactMap { screenRect(of: $0) }
            guard let first = rects.first else { return nil }
            return rects.dropFirst().reduce(first) { $0.union($1) }
        default:          return nil
        }
    }

    @objc func showTour(_ sender: Any?) {
        guard let window else { return }
        // Every page assumes the panes are on screen; from Simple the
        // details-rail page would have nothing to point at.
        applyWorkspace(.full, save: false, preserveGeometry: false)
        tour?.finish()
        let t = TourWindowController(host: window, pages: TourPages.all) { [weak self] name in
            self?.tourAnchor(name)
        }
        t.onClose = { [weak self] in
            self?.tour = nil
            UserDefaults.standard.set(true, forKey: Self.tourShownKey)
        }
        tour = t
        t.present()
    }

    // "Open Linked File" from the source editor's context menu.
    @objc func openLinkedFileFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openFiles([url])
    }

    // MARK: Session memory (File ▸ Reopen Files at Launch)

    /// Whether closing a window with files open asks first.
    static let askOnCloseKey = "xml-macker.askOnClose"
    static var askOnCloseEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: askOnCloseKey) == nil ? true : d.bool(forKey: askOnCloseKey)
    }

    /// Read by the Settings window, which shows the same state the View
    /// menu does.
    var sourceLineNumbersVisible: Bool { sourceVC.isLineNumbersVisible }
    var hasOpenFiles: Bool { !sessions.isEmpty }

    static let lastOpenFilesKey = "xml-macker.lastOpenFiles"
    static let reopenLastFilesKey = "xml-macker.reopenLastFiles"
    static var reopenLastFilesEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: reopenLastFilesKey) == nil ? true : d.bool(forKey: reopenLastFilesKey)
    }

    /// Snapshot of the open tabs, taken when the window closes or the
    /// app quits, so a plain launch (no file handed in) can pick up
    /// where the user left off.
    /// Called at quit: every open file's marks written where they belong.
    func saveAllHighlights() {
        for (i, s) in sessions.enumerated() where !s.isUntitled {
            let text = i == activeSessionIdx ? sourceVC.documentText : (s.storage?.string ?? "")
            guard !text.isEmpty else { continue }
            HighlightStore.save(s.highlights, for: s.url, text: text)
        }
    }

    func rememberOpenFiles() {
        // An untitled document has no home to come back to.
        UserDefaults.standard.set(sessions.filter { !$0.isUntitled }.map { $0.url.path },
                                  forKey: Self.lastOpenFilesKey)
    }

    // MARK: Window / application close safety

    var canTerminateImmediately: Bool {
        if terminationApproved { return true }
        let hasDirty = sessions.indices.contains { isSessionDirty($0) }
        return !hasDirty && activeOpenRequest == nil && savingSessionIDs.isEmpty
    }

    func approveImmediateTermination() {
        terminationApproved = true
    }

    /// Asynchronous contract used by AppDelegate's terminate-later reply and
    /// by main-window close. Every dirty tab is reviewed together; Save All
    /// proceeds serially and aborts on the first write failure.
    func prepareForApplicationTermination(completion: @escaping (Bool) -> Void) {
        if terminationApproved {
            completion(true)
            return
        }
        if activeOpenRequest != nil || !savingSessionIDs.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A file operation is still in progress"
            alert.informativeText = "Wait for loading or saving to finish, then close xml-macker again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completion(false)
            return
        }

        snapshotActiveSession()
        let dirtyIDs = sessions.indices
            .filter { isSessionDirty($0) }
            .map { sessions[$0].id }
        guard !dirtyIDs.isEmpty else {
            terminationApproved = true
            completion(true)
            return
        }

        let names = dirtyIDs.compactMap { id in
            sessions.first(where: { $0.id == id })?.url.lastPathComponent
        }.joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirtyIDs.count == 1
            ? "Save changes before closing?"
            : "Save changes in \(dirtyIDs.count) files before closing?"
        alert.informativeText = names
        alert.addButton(withTitle: dirtyIDs.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDirtySessions(dirtyIDs, at: 0, completion: completion)
        case .alertSecondButtonReturn:
            terminationApproved = true
            completion(true)
        default:
            completion(false)
        }
    }

    private func saveDirtySessions(_ ids: [UUID], at position: Int,
                                   completion: @escaping (Bool) -> Void) {
        guard position < ids.count else {
            terminationApproved = true
            completion(true)
            return
        }
        let id = ids[position]
        guard let session = sessions.first(where: { $0.id == id }) else {
            saveDirtySessions(ids, at: position + 1, completion: completion)
            return
        }
        saveSession(sessionID: id, to: session.url, updateURL: false) { [weak self] success in
            guard let self, success else {
                completion(false)
                return
            }
            self.saveDirtySessions(ids, at: position + 1, completion: completion)
        }
    }

    // Closing the MAIN window with several files open: confirm whether that
    // means the current tab or the whole window, preserving the prior app UX.
    static let closeChoiceKey = "xml-macker.closeWindowChoice"   // "tab" | "all"
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if allowNextMainWindowClose {
            allowNextMainWindowClose = false
            return true
        }

        if sessions.count <= 1 {
            if canTerminateImmediately { return true }
            closeMainWindowAfterReview()
            return false
        }

        switch UserDefaults.standard.string(forKey: Self.closeChoiceKey) {
        case "all": closeMainWindowAfterReview(); return false
        case "tab": closeCurrentFile(); return false
        default: break
        }
        let alert = NSAlert()
        alert.messageText = "You have \(sessions.count) files open"
        alert.informativeText = "Close only the current tab, or close all files and quit?"
        alert.addButton(withTitle: "Close Current Tab")
        alert.addButton(withTitle: "Close All Files")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"
        let resp = alert.runModal()
        let remember = alert.suppressionButton?.state == .on
        switch resp {
        case .alertFirstButtonReturn:
            if remember { UserDefaults.standard.set("tab", forKey: Self.closeChoiceKey) }
            closeCurrentFile()
            return false
        case .alertSecondButtonReturn:
            if remember { UserDefaults.standard.set("all", forKey: Self.closeChoiceKey) }
            closeMainWindowAfterReview()
            return false
        default:
            return false
        }
    }

    private func closeMainWindowAfterReview() {
        prepareForApplicationTermination { [weak self] approved in
            guard approved, let self else { return }
            DispatchQueue.main.async {
                self.allowNextMainWindowClose = true
                self.window?.performClose(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win === window {
            // Main window going away, take every satellite with it
            // (popped-out panes, chart, validation, find panel).
            for (_, e) in popouts {
                e.window.delegate = nil
                e.window.orderOut(nil)
            }
            popouts.removeAll()
            rememberOpenFiles()
            for (_, w) in paneWindows { w.window?.delegate = nil; w.close() }
            paneWindows.removeAll()
            // CLOSE (not just hide) so nothing lingers after the
            // document window; hiding left the chart window open
            // after the app was closed. With no windows left the app
            // quits (applicationShouldTerminateAfterLastWindowClosed).
            chartPopout?.close()
            validationWindow?.close()
            findPanel?.close()
            orbitWindow.close()
            for d in diffWindows { d.close() }
            diffWindows.removeAll()
            return
        }
        if let (_, entry) = popouts.first(where: { $0.value.window === win }) {
            dockPane(entry: entry, closeWindow: false)
            relayoutAfterDock()
        }
    }

    // Update menu item titles, "Hide Tree" vs "Show Tree" etc.
    // (NSUserInterfaceValidations; NSWindowController doesn't mark
    // this as @objc-override-able so we define it directly.)
    // MARK: Workspace modes (toolbar Edit / Inspect / Full switcher)
    //
    // The out-of-the-box fix for "I have to resize everything": the
    // window re-arranges ITSELF for the task. Edit gives the source
    // editor almost the whole window; Inspect brings the inspector
    // column back; Full shows every pane (the classic layout). One
    // click or ⌥⌘1/2/3, no divider dragging. Persisted so the app
    // reopens in the mode the user last worked in.

    enum WorkspaceMode: Int { case edit = 0, inspect = 1, full = 2, learn = 3 }
    static let workspaceModeKey = "xml-macker.workspaceMode"
    private var currentWorkspaceMode: WorkspaceMode = .full
    // LEARN mode: embedded chat browser on the right (LearnPane.swift).
    // Created lazily, KEPT alive across mode switches so the login
    // session and the ongoing chat survive.
    private var learnVC: LearnPaneViewController?

    /// Settings changed the default chat site: show it at once when the
    /// Learn pane is already open.
    func applyDefaultChatSite() {
        learnVC?.showChat(LearnPaneViewController.defaultChat)
    }
    private var learnGlass: GlassPanel?
    private lazy var learnChipButton: NSButton = {
        let b = NSButton(title: "✨ Define", target: self, action: #selector(learnChipClicked(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = XMFont.ui(11, .semibold)
        return b
    }()

    @objc func workspaceSegmentChanged(_ sender: NSSegmentedControl) {
        applyWorkspace(WorkspaceMode(rawValue: sender.selectedSegment) ?? .full, save: true)
    }
    @objc func workspaceEditMode(_ sender: Any?)    { applyWorkspace(.edit,   save: true) }
    @objc func workspaceInspectMode(_ sender: Any?) { applyWorkspace(.inspect, save: true) }
    @objc func workspaceFullMode(_ sender: Any?)    { applyWorkspace(.full,   save: true) }
    @objc func workspaceLearnMode(_ sender: Any?)   { applyWorkspace(.learn,  save: true) }

    func applyWorkspace(_ mode: WorkspaceMode, save: Bool,
                        preserveGeometry: Bool = false) {
        guard let insp = inspectorColumnSplit, let sub = subtagsGlass,
              let hier = hierarchyGlass, let tree = treeGlass else { return }
        // Same removal-based visibility as the pane × buttons, no
        // hidden ghosts left in the splits.
        func setVisible(_ v: NSView, _ visible: Bool) {
            if visible { if isPaneClosed(v), !isInPaneWindow(v) { showPane(v) } }
            else       { if !isPaneClosed(v) { hidePane(v) } }
        }
        // Leaving Learn: the browser pane comes out of the split but
        // the view controller stays alive (login + chat preserved).
        if mode != .learn, let lg = learnGlass, lg.superview != nil {
            lg.removeFromSuperview()
            learnChipButton.removeFromSuperview()
        }
        switch mode {
        case .edit:
            // Tree + source + the Subtags strip: editing wants the
            // Subtags pane alongside the source, so only the
            // inspector column and hierarchy go.
            setVisible(tree, true)
            setVisible(insp, false)
            setVisible(sub, true)
            setVisible(hier, false)
        case .inspect:
            setVisible(tree, true)
            setVisible(insp, true)
            setVisible(sub, false)
            setVisible(hier, false)
            // Inspector gets a generous column, the freed bottom-
            // strip space is exactly why this mode exists.
            if !preserveGeometry {
                let inspLeft = UserDefaults.standard.bool(forKey: Self.inspectorOnLeftKey)
                let rightW = topHSplit.bounds.width
                let inspW = max(XMMetric.inspectorPaneMin,
                                min(XMMetric.inspectorPaneDefault + 80, rightW * 0.34))
                topHSplit.setPosition(inspLeft ? inspW : rightW - inspW - 16, ofDividerAt: 0)
            }
            applyDetailSelection(persist: false)
        case .full:
            // FULL = reset to the fresh-open view:
            // every floating pane comes home first…
            for (_, e) in Array(popouts) { dockPane(entry: e, closeWindow: true) }
            setVisible(tree, true)
            setVisible(insp, true)
            setVisible(sub, true)
            setVisible(hier, true)
            // …nothing stays minimized…
            for (title, pc) in paneRegistry
                where pc.chrome.isMinimized && !detailTitles.contains(title) {
                toggleMinimize(chrome: pc.chrome, glass: pc.glass, title: title)
            }
            autoMinimized.removeAll()
            // …and the classic outer proportions. The detail rail itself
            // deliberately keeps one selected section instead of equal thirds.
            applyPaneLayout(resetPositions: !preserveGeometry)
            applyDetailSelection(persist: false)
        case .learn:
            // Tree + source + a tall browser where the right column
            // was. The inspector column, subtags and hierarchy leave.
            for (_, e) in Array(popouts) { dockPane(entry: e, closeWindow: true) }
            setVisible(tree, true)
            setVisible(insp, false)
            setVisible(sub, false)
            setVisible(hier, false)
            ensureLearnPane()
            if let lg = learnGlass, lg.superview !== topHSplit {
                topHSplit.addArrangedSubview(lg)
            }
            topHSplit.layoutSubtreeIfNeeded()
            topHSplit.setPosition(topHSplit.bounds.width * 0.56, ofDividerAt: 0)
        }
        currentWorkspaceMode = mode
        toolbarHelper?.workspaceSegment?.selectedSegment = mode.rawValue
        if save { UserDefaults.standard.set(mode.rawValue, forKey: Self.workspaceModeKey) }
    }

    // Pop-out windows are ordinary windows: click another app and they
    // go behind it like every other window on the Mac. As floating
    // windows the chart pop-out kept covering other apps, which is why
    // they no longer stay on top. View > "Pop-outs Stay on Top" turns
    // the old floating behaviour back on for anyone who wants it, and
    // the choice is remembered.
    static let popoutsFloatKey = "xml-macker.popoutsFloat"
    static var popoutsFloat: Bool {
        UserDefaults.standard.object(forKey: popoutsFloatKey) as? Bool ?? false
    }

    @objc func togglePopoutsFloat(_ sender: Any?) {
        let newValue = !Self.popoutsFloat
        UserDefaults.standard.set(newValue, forKey: Self.popoutsFloatKey)
        let level: NSWindow.Level = newValue ? .floating : .normal
        // Three separate collections hold pop-out windows; the old code
        // only reached two of them, so the Tree and Source windows stayed
        // pinned no matter what the menu said.
        var affected: [NSWindow] = popouts.values.map(\.window)
        affected.append(contentsOf: paneWindows.values.compactMap(\.window))
        if let cw = chartPopout?.window { affected.append(cw) }
        for win in affected {
            win.level = level
            if newValue {
                // Floating is a system-wide level; a parent link would
                // fight it, so drop the link while it is on.
                win.parent?.removeChildWindow(win)
            } else if win.parent == nil, let main = window, win != main {
                main.addChildWindow(win, ordered: .above)
            }
        }
    }

    // MARK: Pane layout (View > Layout, RStudio-style arrangement)
    //
    // The goal is an RStudio-style arrangement: one pane moved to the
    // right, another laid out horizontally below. Rather than
    // free-form drag-docking (fragile with six panes), the Layout
    // submenu offers per-region placement choices; the combination
    // covers those arrangements. Persisted in UserDefaults so the app
    // reopens the way it was left.

    static let treeOnRightKey     = "xml-macker.layout.treeOnRight"
    static let inspectorOnLeftKey = "xml-macker.layout.inspectorOnLeft"
    static let hierarchyOnTopKey  = "xml-macker.layout.hierarchyOnTop"

    @objc func layoutTreeLeft(_ sender: Any?)       { UserDefaults.standard.set(false, forKey: Self.treeOnRightKey);     applyPaneLayout() }
    @objc func layoutTreeRight(_ sender: Any?)      { UserDefaults.standard.set(true, forKey: Self.treeOnRightKey);     applyPaneLayout() }
    @objc func layoutInspectorRight(_ sender: Any?) { UserDefaults.standard.set(false, forKey: Self.inspectorOnLeftKey); applyPaneLayout() }
    @objc func layoutInspectorLeft(_ sender: Any?)  { UserDefaults.standard.set(true, forKey: Self.inspectorOnLeftKey); applyPaneLayout() }
    @objc func layoutHierarchyBottom(_ sender: Any?){ UserDefaults.standard.set(false, forKey: Self.hierarchyOnTopKey);  applyPaneLayout() }
    @objc func layoutHierarchyTop(_ sender: Any?)   { UserDefaults.standard.set(true, forKey: Self.hierarchyOnTopKey);  applyPaneLayout() }
    @objc func layoutReset(_ sender: Any?) {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.treeOnRightKey)
        d.removeObject(forKey: Self.inspectorOnLeftKey)
        d.removeObject(forKey: Self.hierarchyOnTopKey)
        applyPaneLayout()
    }

    // Reorder a split's panes without recreating them, the views and
    // everything inside (scroll positions, selections) survive; only
    // their order changes. No-op when the order already matches.
    // Closed (removed) panes are skipped so a reorder never
    // resurrects a pane the user ×-ed away.
    private func setArrangedOrder(_ split: NSSplitView, _ order: [NSView]) {
        // Skip closed panes AND popped-out panes, including a pane
        // that currently lives in its own window yanked it back into
        // the column mid-flight: closing Preview took the Inspector
        // with it and left the still-detached windows grey.
        let present = order.filter {
            !isPaneClosed($0) && popouts[ObjectIdentifier($0)] == nil
        }
        let current = split.arrangedSubviews.map { ObjectIdentifier($0) }
        guard current != present.map({ ObjectIdentifier($0) }) else { return }
        for v in present { v.removeFromSuperview() }
        for v in present { split.addArrangedSubview(v) }
        split.adjustSubviews()
    }

    private func applyPaneLayout(resetPositions: Bool = true) {
        guard let tree = treeGlass, let src = sourceContainerView,
              let sub = subtagsGlass, let hier = hierarchyGlass,
              let main = mainSplit, let top = topHSplit,
              let rootV = rootVSplit, let inspCol = inspectorColumnSplit else { return }
        let d = UserDefaults.standard
        let treeRight = d.bool(forKey: Self.treeOnRightKey)
        let inspLeft  = d.bool(forKey: Self.inspectorOnLeftKey)
        let hierTop   = d.bool(forKey: Self.hierarchyOnTopKey)

        setArrangedOrder(main, treeRight ? [rootV, tree]        : [tree, rootV])
        setArrangedOrder(top,  inspLeft  ? [inspCol, src]       : [src, inspCol])
        setArrangedOrder(rootV, hierTop   ? [hier, top, sub]     : [top, sub, hier])

        guard resetPositions else { return }

        // Divider positions appropriate to the new order (same
        // proportions as the initial layout, mirrored when a pane
        // moved to the other side).
        let w = main.bounds.width
        let treeW = max(XMMetric.treePaneMin, min(XMMetric.treePaneDefault, w * 0.22))
        main.setPosition(treeRight ? w - treeW : treeW, ofDividerAt: 0)

        let rightW = top.bounds.width
        let inspW = max(XMMetric.inspectorPaneMin, min(XMMetric.inspectorPaneDefault, rightW * 0.30))
        top.setPosition(inspLeft ? inspW : rightW - inspW - 16, ofDividerAt: 0)

        let vH = rootV.bounds.height
        let botH = max(120, vH * 0.18)
        if hierTop {
            rootV.setPosition(botH,       ofDividerAt: 0)   // hierarchy strip up top
            rootV.setPosition(vH - botH,  ofDividerAt: 1)   // subtags stays at bottom
        } else {
            rootV.setPosition(vH - botH * 2, ofDividerAt: 0)
            rootV.setPosition(vH - botH,    ofDividerAt: 1)
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // File menu, everything that operates on the current doc
        // must gray out when no file is open.
        switch item.action {
        case #selector(menuSave(_:)),
             #selector(menuSaveAs(_:)),
             #selector(menuRevert(_:)),
             #selector(menuCloseFile(_:)),
             #selector(menuRevealInFinder(_:)),
             #selector(menuCopyPath(_:)),
             #selector(menuGoToLine(_:)):
            return currentFileURL != nil
        default:
            break
        }

        // Share commands should reflect the active source selection instead
        // of looking available and then only beeping when invoked.
        switch item.action {
        case #selector(shareCopySelectionInFull(_:)),
             #selector(sharePrintSelection(_:)):
            return currentFileURL != nil && sourceVC.exposedTextView.selectedRange().length > 0
        case #selector(sharePrintCurrentElement(_:)),
             #selector(shareExportElement(_:)):
            return currentSelectedNode != nil
        case #selector(sharePrintPickElement(_:)):
            return currentTree != nil
        case #selector(shareFileSystem(_:)):
            return currentFileURL != nil
        case #selector(shareToLLM(_:)):
            guard currentFileURL != nil,
                  let spec = item.representedObject as? [String], spec.count == 2 else {
                return false
            }
            return spec[1] == "selection"
                ? sourceVC.exposedTextView.selectedRange().length > 0
                : currentSelectedNode != nil
        default:
            break
        }

        // Show ▸ / Hide ▸ submenu items: enable only the applicable
        // direction (a visible pane can be hidden, a closed or
        // minimized one shown).
        if item.action == #selector(menuShowPane(_:)) {
            guard let t = item.representedObject as? String else { return false }
            if t == "Minimap" { return minimap.isHidden }
            if t == "Details" { return inspectorColumnSplit.map { isPaneClosed($0) } ?? false }
            guard let (chrome, glass) = paneRegistry[t] else { return false }
            return isPaneClosed(glass) || chrome.isMinimized
        }
        if item.action == #selector(menuHidePane(_:)) {
            guard let t = item.representedObject as? String else { return false }
            if t == "Minimap" { return !minimap.isHidden }
            if t == "Details" { return inspectorColumnSplit.map { !isPaneClosed($0) } ?? false }
            guard let (_, glass) = paneRegistry[t] else { return false }
            return !isPaneClosed(glass)
        }
        // Theme menu: tick the currently-active theme, whichever it is.
        if item.action == #selector(selectTheme(_:)) {
            item.state = (item.representedObject as? String) == ThemeManager.current.id ? .on : .off
            return true
        }
        switch item.action {
        case #selector(menuToggleLineNumbers(_:)):
            item.state = sourceVC.isLineNumbersVisible ? .on : .off
        case #selector(menuToggleMinimap(_:)):
            item.state = Self.minimapVisible ? .on : .off
        case #selector(togglePopoutsFloat(_:)):
            item.state = Self.popoutsFloat ? .on : .off
        default: break
        }
        // Workspace menu: tick the active mode.
        switch item.action {
        case #selector(workspaceEditMode(_:)):    item.state = currentWorkspaceMode == .edit    ? .on : .off
        case #selector(workspaceInspectMode(_:)): item.state = currentWorkspaceMode == .inspect ? .on : .off
        case #selector(workspaceFullMode(_:)):    item.state = currentWorkspaceMode == .full    ? .on : .off
        default: break
        }
        // Layout menu: tick the active placement in each group.
        let d = UserDefaults.standard
        switch item.action {
        case #selector(layoutTreeLeft(_:)):        item.state = d.bool(forKey: Self.treeOnRightKey)     ? .off : .on
        case #selector(layoutTreeRight(_:)):       item.state = d.bool(forKey: Self.treeOnRightKey)     ? .on  : .off
        case #selector(layoutInspectorRight(_:)):  item.state = d.bool(forKey: Self.inspectorOnLeftKey) ? .off : .on
        case #selector(layoutInspectorLeft(_:)):   item.state = d.bool(forKey: Self.inspectorOnLeftKey) ? .on  : .off
        case #selector(layoutHierarchyBottom(_:)): item.state = d.bool(forKey: Self.hierarchyOnTopKey)  ? .off : .on
        case #selector(layoutHierarchyTop(_:)):    item.state = d.bool(forKey: Self.hierarchyOnTopKey)  ? .on  : .off
        default: break
        }
        return true
    }
}


// MARK: - Share menu actions (v0.36.0)
//
// Lives in this file (not ShareSupport.swift) so the actions can use
// the controller's private helpers (elementText, statusLabel, …).
extension MainWindowController {

    // ── Print ─────────────────────────────────────────────────────

    @objc func sharePrintSelection(_ sender: Any?) {
        guard let text = shareSelectionText(cap: 2_000_000) else {
            NSSound.beep()
            statusLabel.stringValue = sourceVC.exposedTextView.selectedRange().length > 2_000_000
                ? "Selection is over the 2 M character print limit"
                : "Select some text in the source first"
            return
        }
        runPrint(text, jobTitle: "Selection, \(currentFileURL?.lastPathComponent ?? "XMLMacker")")
    }

    @objc func sharePrintCurrentElement(_ sender: Any?) {
        guard let node = currentSelectedNode,
              let (text, _) = elementText(node, cap: 2_000_000) else {
            NSSound.beep()
            statusLabel.stringValue = "Select an element in the tree first (2 M character print cap)"
            return
        }
        runPrint(text, jobTitle: "<\(node.displayLabel)>, \(currentFileURL?.lastPathComponent ?? "")")
    }

    @objc func sharePrintPickElement(_ sender: Any?) {
        guard let root = currentTree else { NSSound.beep(); return }
        let picker = ElementPickerWindowController(root: root, title: "Choose an element to print") { [weak self] node in
            guard let self else { return }
            guard let (text, _) = self.elementText(node, cap: 2_000_000) else { return }
            self.runPrint(text, jobTitle: "<\(node.displayLabel)>, \(self.currentFileURL?.lastPathComponent ?? "")")
        }
        picker.present(over: window)
    }

    // ── Send to LLM ───────────────────────────────────────────────
    // representedObject = [target.rawValue, "selection"|"element"|"file"]

    @objc func shareToLLM(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? [String], spec.count == 2,
              let target = LLMTarget(rawValue: spec[0]) else { return }
        let fileName = currentFileURL?.lastPathComponent ?? "document.xml"

        switch spec[1] {
        case "selection":
            guard let text = shareSelectionText(cap: nil) else {
                NSSound.beep()
                statusLabel.stringValue = "Select some text in the source first"
                return
            }
            shareXMLText(
                text,
                promptIntroduction: "Here is an XML excerpt from \(fileName):",
                to: target
            )
        case "element":
            guard let node = currentSelectedNode,
                  let (text, _) = elementText(node) else {
                NSSound.beep()
                statusLabel.stringValue = "Select an element in the tree first"
                return
            }
            shareXMLText(
                text,
                promptIntroduction: "Here is the <\(node.displayLabel)> element (path: \(treePath(for: node))) from \(fileName):",
                to: target
            )
        default:
            return
        }
    }

    // Route a prompt to an LLM. Four of the five chats live in the
    // Learn pane's embedded browser, where we can TYPE the text into
    // the box without sending, what "share" should feel like
    // (v0.37.0's external open-with-clipboard read as broken: the
    // site came up empty). Gemini can't log in embedded, so it keeps
    // the external copy-and-paste path.
    // Share = the user's OWN browser; only Define stays inside the
    // app. Small payloads are pre-filled into the chat via ?q= where
    // the site supports it; everything is always on the clipboard as
    // backup.
    private func sendPrompt(_ prompt: String, to target: LLMTarget) {
        deliverPrompt(prompt, to: target)
    }

    private func deliverPrompt(
        _ prompt: String,
        to target: LLMTarget,
        successStatus: String? = nil
    ) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(prompt, forType: .string) else {
            reportClipboardFailure()
            return
        }
        let url = target.url(prefill: prompt)
        let opened = NSWorkspace.shared.open(url)
        if let successStatus {
            statusLabel.stringValue = opened
                ? (url.query == nil
                    ? "\(successStatus), click the message box and press ⌘V"
                    : successStatus)
                : "Copied successfully, but \(target.displayName) could not be opened"
        } else {
            statusLabel.stringValue = opened
                ? (url.query == nil
                    ? "Copied, click the message box in \(target.displayName) and press ⌘V"
                    : "Prepared for \(target.displayName) (full text is also on the clipboard)")
                : "Copied successfully, but \(target.displayName) could not be opened"
        }
    }

    /// Chat providers have independent, changing input limits. For a large
    /// selection we make both choices honest: a bounded compatibility excerpt,
    /// or the entire uncapped selection with a warning that the destination may
    /// reject it. XMLMacker never truncates without the user's confirmation.
    private func shareXMLText(
        _ xml: String,
        promptIntroduction: String,
        to target: LLMTarget
    ) {
        let plan = ShareTextPolicy.excerpt(from: xml)
        guard plan.isTruncated else {
            sendPrompt(xmlSharePrompt(introduction: promptIntroduction, xml: xml), to: target)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "This selection may be too large for a chat window"
        alert.informativeText = """
        The selected XML is \(formattedByteCount(plan.totalUTF8Bytes)). Chat services set their own limits, and those limits can change.

        xml-macker's 128 KiB compatibility excerpt is not a macOS maximum. It will include \(formattedExactBytes(plan.includedUTF8Bytes)) and omit \(formattedExactBytes(plan.omittedUTF8Bytes)), ending at a complete Unicode character.

        You can instead copy all \(formattedExactBytes(plan.totalUTF8Bytes)) and open \(target.displayName), but that site may reject the paste. No message is submitted automatically.
        """
        alert.addButton(withTitle: "Share 128 KiB Excerpt")
        alert.addButton(withTitle: "Copy All & Open \(target.displayName)")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let prompt = xmlSharePrompt(
                introduction: promptIntroduction,
                xml: plan.text,
                excerpt: plan
            )
            deliverPrompt(
                prompt,
                to: target,
                successStatus: "Copied excerpt for \(target.displayName): \(formattedExactBytes(plan.includedUTF8Bytes)) included, \(formattedExactBytes(plan.omittedUTF8Bytes)) omitted"
            )
        case .alertSecondButtonReturn:
            let prompt = xmlSharePrompt(introduction: promptIntroduction, xml: xml)
            deliverPrompt(
                prompt,
                to: target,
                successStatus: "Copied the full \(formattedExactBytes(plan.totalUTF8Bytes)) selection; \(target.displayName) may still limit the paste"
            )
        default:
            statusLabel.stringValue = "Share cancelled, the selection was not copied or truncated"
        }
    }

    private func xmlSharePrompt(
        introduction: String,
        xml: String,
        excerpt: ShareTextExcerpt? = nil
    ) -> String {
        let disclosure: String
        if let excerpt, excerpt.isTruncated {
            disclosure = "\n\nxml-macker compatibility excerpt: first \(formattedExactBytes(excerpt.includedUTF8Bytes)) of \(formattedExactBytes(excerpt.totalUTF8Bytes)); \(formattedExactBytes(excerpt.omittedUTF8Bytes)) omitted. The XML may end before its closing tags."
        } else {
            disclosure = ""
        }
        return "\(introduction)\(disclosure)\n\n```xml\n\(xml)\n```\n\n"
    }

    @objc func shareCopySelectionInFull(_ sender: Any?) {
        guard let text = shareSelectionText(cap: nil) else {
            NSSound.beep()
            statusLabel.stringValue = "Select some text in the source first"
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            reportClipboardFailure()
            return
        }
        statusLabel.stringValue = "Copied the complete selection (\(formattedExactBytes(text.utf8.count))); xml-macker applied no limit"
    }

    private func reportClipboardFailure() {
        NSSound.beep()
        statusLabel.stringValue = "The selection could not be copied to the clipboard"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t copy the selection"
        alert.informativeText = "macOS did not accept the text on the clipboard. Nothing was opened or shared. Try copying a smaller selection."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func formattedExactBytes(_ count: Int) -> String {
        "\(count.formatted()) UTF-8 bytes"
    }

    private func formattedByteCount(_ count: Int) -> String {
        let approximate = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        return "\(approximate) (\(formattedExactBytes(count)))"
    }

    // Ask once (or apply the remembered answer) when sharing a file
    // that has unsaved edits: the share reads the DISK version.
    private func ensureFileCurrentForShare(then proceed: @escaping () -> Void) {
        guard docDirty, let url = currentFileURL else { proceed(); return }
        switch rememberedShareChoice {
        case .saveFirst:
            performSave(to: url, updateCurrent: false) { success in
                if success { proceed() }
            }
            return
        case .shareDisk:
            proceed()
            return
        case nil:
            break
        }
        let alert = NSAlert()
        alert.messageText = "This file has unsaved changes"
        alert.informativeText = "Sharing sends the file as it is on disk. Save first so your latest edits are included, or share the last saved version."
        alert.addButton(withTitle: "Save and Share")
        alert.addButton(withTitle: "Share Saved Version")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice for this session"
        let resp = alert.runModal()
        let remember = alert.suppressionButton?.state == .on
        switch resp {
        case .alertFirstButtonReturn:
            if remember { rememberedShareChoice = .saveFirst }
            performSave(to: url, updateCurrent: false) { success in
                if success { proceed() }
            }
        case .alertSecondButtonReturn:
            if remember { rememberedShareChoice = .shareDisk }
            proceed()
        default:
            break
        }
    }

    // ── System share + element export ─────────────────────────────

    @objc func shareFileSystem(_ sender: Any?) {
        guard let url = currentFileURL, window?.contentView != nil else {
            NSSound.beep()
            statusLabel.stringValue = "Open a file first"
            return
        }
        ensureFileCurrentForShare { [weak self] in
            guard let self, let cv = self.window?.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            let anchor = NSRect(x: cv.bounds.midX - 1, y: cv.bounds.maxY - 60, width: 2, height: 2)
            picker.show(relativeTo: anchor, of: cv, preferredEdge: .minY)
        }
    }

    @objc func shareExportElement(_ sender: Any?) {
        guard let node = currentSelectedNode else {
            NSSound.beep()
            statusLabel.stringValue = "Select an element in the tree first"
            return
        }
        exportElementToFile(node)
    }

    // ── Helpers ───────────────────────────────────────────────────

    private func shareSelectionText(cap: Int? = 2_000_000) -> String? {
        let tv = sourceVC.exposedTextView
        let r = tv.selectedRange()
        guard r.length > 0 else { return nil }
        if let cap, r.length > cap { return nil }
        let (text, _) = sourceVC.substring(in: r, cap: r.length)
        return text
    }

    // ── Learn mode (v0.37.0) ─────────────────────────────────────

    private func ensureLearnPane() {
        guard learnVC == nil else { return }
        let vc = LearnPaneViewController()
        vc.onStatus = { [weak self] msg in self?.statusLabel.stringValue = msg }
        vc.requestSelectionPrompt = { [weak self] in self?.learnSelectionPrompt() }
        vc.requestElementPrompt = { [weak self] in self?.learnElementPrompt() }
        vc.requestFileURL = { [weak self] in self?.currentFileURL }
        vc.requestWholeFile = { [weak self] in
            guard let self, let storage = self.sourceVC.currentStorage else { return nil }
            return storage.string
        }
        let glass = GlassPanel()
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        glass.setFrameSize(NSSize(width: 480, height: 400))
        learnVC = vc
        learnGlass = glass
    }

    // "Define everything": asks for every tag, attribute and value
    // to be explained in simple terms.
    private func learnPrompt(xml: String, what: String) -> String {
        let name = currentFileURL?.lastPathComponent ?? "an XML file"
        return "Define everything in this XML \(what) from the GCAM model file \(name), explain what every tag means, what every attribute does, and what each value represents, in simple terms:\n\n```xml\n\(xml)\n```\n"
    }

    private func learnSelectionPrompt() -> String? {
        guard let text = shareSelectionText(cap: 200_000) else {
            NSSound.beep()
            statusLabel.stringValue = "Select some source text first (200 k character cap for chat)"
            return nil
        }
        return learnPrompt(xml: text, what: "selection")
    }

    private func learnElementPrompt() -> String? {
        guard let node = currentSelectedNode,
              let (text, _) = elementText(node, cap: 200_000) else {
            NSSound.beep()
            statusLabel.stringValue = "Select an element in the tree first (200 k character cap for chat)"
            return nil
        }
        return learnPrompt(xml: text, what: "element <\(node.displayLabel)>")
    }

    // Floating "✨ Define" chip beside the source selection (Learn
    // mode only): selecting text pops it up so the selection can be
    // copied and sent. Added as a subview of the text view so it
    // scrolls with the text.
    func updateLearnChip() {
        guard currentWorkspaceMode == .learn else {
            learnChipButton.removeFromSuperview()
            return
        }
        let tv = sourceVC.exposedTextView
        let r = tv.selectedRange()
        guard r.length > 0, r.length <= 2_000_000,
              let lm = tv.layoutManager, let tc = tv.textContainer else {
            learnChipButton.removeFromSuperview()
            return
        }
        let endG = lm.glyphRange(forCharacterRange: NSRange(location: max(r.location, NSMaxRange(r) - 1), length: 1),
                                 actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: endG, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        learnChipButton.sizeToFit()
        let size = learnChipButton.frame.size
        let x = min(rect.maxX + 10, tv.bounds.width - size.width - 8)
        learnChipButton.frame = NSRect(x: max(8, x), y: rect.minY - 1,
                                       width: size.width, height: size.height)
        if learnChipButton.superview !== tv { tv.addSubview(learnChipButton) }
    }

    @objc func learnChipClicked(_ sender: Any?) {
        guard let prompt = learnSelectionPrompt() else { return }
        // From the source context menu the user is usually in Edit or
        // Full mode, where the Learn browser does not exist yet: switch
        // first, exactly like the tree's Define path (v1.0.1 fix).
        if currentWorkspaceMode != .learn { applyWorkspace(.learn, save: true) }
        learnVC?.insertPrompt(prompt)
    }

    // Paginated print of monospaced text via a throwaway NSTextView
    // sized to the printable page width. Black-on-white regardless of
    // the app theme, paper is paper.
    private func runPrint(_ text: String, jobTitle: String) {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.leftMargin = 32; info.rightMargin = 32
        info.topMargin = 36;  info.bottomMargin = 36
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        let full = NSRange(location: 0, length: (text as NSString).length)
        tv.textStorage?.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.black
        ], range: full)
        tv.backgroundColor = .white
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            tv.frame = NSRect(x: 0, y: 0, width: width, height: max(100, used.height + 16))
        }

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.jobTitle = jobTitle
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}


/// A target that outlives a locally built button.
final class BlockButton: NSObject {
    static let shared = BlockButton()
    var handlers: [ObjectIdentifier: () -> Void] = [:]
    @objc func fire(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?() }
}


/// The two documents a Diff window is showing. Held in a class so a side
/// can be swapped while the window's edit closure keeps working.
final class DiffPair {
    weak var left: DocumentSession?
    weak var right: DocumentSession?
    init(left: DocumentSession, right: DocumentSession) { self.left = left; self.right = right }
}
