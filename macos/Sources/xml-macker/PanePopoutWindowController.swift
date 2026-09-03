import Cocoa

// Floating pane windows, v1.0.7. The old pop-out MOVED the live pane
// view between windows, and every dock-back left something broken
// (grey panes, a Tree with zero height). This is the pattern Apple
// and the Mac developer community recommend instead: the floating
// window hosts a FRESH copy of the pane, the docked pane is hidden
// meanwhile, and nothing is ever reparented. MainWindowController
// keeps both copies in step (selection, edits, fonts, colors).
final class PanePopoutWindowController: NSWindowController, NSWindowDelegate {
    var onDock: (() -> Void)?
    let content: NSViewController
    private let chrome: PaneChrome
    private let host = NSView()
    private let wheelZoom = WheelZoom()

    init(title: String, content: NSViewController) {
        self.content = content
        chrome = PaneChrome(title: title)
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0,
                           width: max(480, min(860, vis.width * 0.45)),
                           height: max(380, min(640, vis.height * 0.55)))
        // No miniaturize button: this window is a child of the main
        // window, and a minimized child ends up with a Dock tile its
        // parent still owns and can come back ordered behind everything.
        // Closing the window docks the pane, which is the real "put it
        // away" gesture here.
        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = title
        win.minSize = NSSize(width: 380, height: 300)
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.level = MainWindowController.popoutsFloat ? .floating : .normal
        super.init(window: win)

        host.wantsLayer = true
        host.layer?.backgroundColor = XMColor.bg.cgColor
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.setContent(content.view)
        // Same grey button, same spot: ↙ docks the pane back.
        chrome.isPoppedOut = true
        chrome.showDockOnlyHeader(true)
        chrome.onPopOut = { [weak self] in self?.close() }
        host.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            chrome.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            chrome.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            chrome.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
        win.contentView = host
        if !win.setFrameAutosaveName("xml-mackerPane-\(title)") { win.center() }
        win.delegate = self
        // Command + wheel and Command with +, - or 0 zoom this pane
        // alone, exactly as they do while it is docked.
        wheelZoom.install(in: win) { [weak self] zoomIn, _ in
            guard let z = self?.content as? PaneZoomable else { return }
            zoomIn ? z.zoomIn() : z.zoomOut()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the window. When `parent` is given (and the user has not
    /// asked for floating pop-outs), the window becomes a child of the
    /// main window: it stays above XMLMacker but never above another
    /// application. A plain .normal window would instead disappear
    /// behind the full-screen main window as soon as it was clicked.
    func show(attachedTo parent: NSWindow? = nil) {
        showWindow(nil)
        if !MainWindowController.popoutsFloat,
           let parent, let win = window, win.parent == nil, win != parent {
            parent.addChildWindow(win, ordered: .above)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // A parent holds a strong reference to its children, so the link
        // has to be broken before the window goes away.
        wheelZoom.stop()
        if let win = window, let p = win.parent { p.removeChildWindow(win) }
        onDock?()
    }

    @objc func xmZoomIn(_ sender: Any?)    { (content as? PaneZoomable)?.zoomIn() }
    @objc func xmZoomOut(_ sender: Any?)   { (content as? PaneZoomable)?.zoomOut() }
    @objc func xmZoomReset(_ sender: Any?) { (content as? PaneZoomable)?.zoomReset() }

    func rebuildFonts() { chrome.rebuildFonts() }

    func rebuildColors() {
        chrome.rebuildColors()
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        host.layer?.backgroundColor = XMColor.bg.cgColor
    }
}
