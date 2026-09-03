import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?
    // Open-URL events can fire BEFORE applicationDidFinishLaunching on
    // macOS (the file passed via `open` arrives on the event queue
    // before the app's main init). Buffer them until the window is up.
    private var pendingURLs: [URL] = []
    private var terminationReplyPending = false

    // Self-managed Open Recent list (see buildMenuBar for why the
    // system recents mechanism doesn't work for this app). Paths,
    // most recent first, capped at 10, persisted across launches.
    private static let recentFilesKey = "xml-macker.recentFiles"
    private weak var recentMenu: NSMenu?

    private var recentPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentFilesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentFilesKey) }
    }

    /// The folder of the most recently opened file, for a Browse panel
    /// that has no open file to start from.
    var mostRecentFolder: URL? {
        recentPaths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    // Record a successfully-opened (or saved) file. Called from every
    // open path: menu Open, Finder/CLI open events, loadFile itself.
    func addRecent(_ url: URL) {
        var list = recentPaths
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        if list.count > 10 { list.removeLast(list.count - 10) }
        recentPaths = list
        rebuildRecentMenu()
    }

    fileprivate func rebuildRecentMenu() {
        guard let menu = recentMenu else { return }
        menu.removeAllItems()
        let list = recentPaths
        if list.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for path in list {
                let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                      action: #selector(openRecentItem(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path     // full path on hover, disambiguates same-named files
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clear = NSMenuItem(title: "Clear Menu",
                                   action: #selector(clearRecentFiles(_:)),
                                   keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            // File moved/deleted since, drop it from the list.
            NSSound.beep()
            recentPaths.removeAll { $0 == path }
            rebuildRecentMenu()
            return
        }
        mainWindowController?.loadFile(url: URL(fileURLWithPath: path))
    }

    @objc private func clearRecentFiles(_ sender: Any?) {
        recentPaths = []
        rebuildRecentMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyDefaults.migrateIfNeeded()
        Diag.log("app launched, args=\(CommandLine.arguments)")
        // Application-wide appearance follows the saved theme so that
        // even Open/Save panels pick the matching light/dark chrome.
        // Deliberately NOT set: NSApp.appearance drags the macOS menu bar
        // and every panel away from the system appearance, which is how the
        // menu titles ended up dark on a dark bar. Each window sets its own.
        buildMenuBar()
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.installWheelZoom()
        // The minimap comes back hidden if that is how it was left.
        if !MainWindowController.minimapVisible { controller.setMinimapVisible(false) }
        mainWindowController = controller

        // Flush URLs that arrived via application(_:open:) during
        // launch before we built the window controller.
        let cliURLs = CommandLine.arguments.dropFirst().compactMap { arg -> URL? in
            guard FileManager.default.fileExists(atPath: arg) else { return nil }
            return URL(fileURLWithPath: arg)
        }
        let launchURLs = XMLDocumentSupport.canonicalFileURLs(pendingURLs + cliURLs)
        pendingURLs.removeAll()
        if !launchURLs.isEmpty {
            Diag.log("flushing launch URLs: \(launchURLs.map(\.path))")
            DispatchQueue.main.async { [weak self] in
                self?.mainWindowController?.openFiles(launchURLs)
            }
        } else if MainWindowController.reopenLastFilesEnabled {
            // Plain launch (Dock / Applications): pick up the files that
            // were open last time, skipping any that moved or vanished.
            let paths = UserDefaults.standard.stringArray(forKey: MainWindowController.lastOpenFilesKey) ?? []
            let urls = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                Diag.log("reopening last session: \(urls.map(\.path))")
                DispatchQueue.main.async { [weak self] in
                    self?.mainWindowController?.openFiles(urls)
                }
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Diag.log("application(openFile:) filename=\(filename)")
        let url = URL(fileURLWithPath: filename)
        if let mwc = mainWindowController {
            mwc.openFiles([url])
        } else {
            pendingURLs.append(url)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Diag.log("application(open:urls:) \(urls.map { $0.path })")
        if let mwc = mainWindowController {
            mwc.openFiles(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// Asked once, the first time the user quits with files open and no
    /// remembered answer. Never during a logout or a restart, where a
    /// modal question would hold up the whole machine.
    private func askAboutReopeningIfNeeded() {
        guard UserDefaults.standard.object(forKey: MainWindowController.reopenLastFilesKey) == nil,
              let c = mainWindowController, c.hasOpenFiles else { return }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let why = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        if why == kAELogOut || why == kAEReallyLogOut || why == kAEShowRestartDialog
            || why == kAERestart || why == kAEShowShutdownDialog || why == kAEShutDown { return }

        let a = NSAlert()
        a.messageText = "Reopen these files next time?"
        a.informativeText = "You have files open. xml-macker can bring them back the next time you start it."
        a.addButton(withTitle: "Reopen Them")
        a.addButton(withTitle: "Start Empty")
        a.addButton(withTitle: "Decide Later")
        let remember = NSButton(checkboxWithTitle: "Remember my choice", target: nil, action: nil)
        remember.state = .on
        a.accessoryView = remember
        let answer = a.runModal()
        if answer == .alertThirdButtonReturn { return }              // ask again next time
        guard remember.state == .on else { return }
        UserDefaults.standard.set(answer == .alertFirstButtonReturn,
                                  forKey: MainWindowController.reopenLastFilesKey)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        askAboutReopeningIfNeeded()
        mainWindowController?.saveAllHighlights()
        // Any untitled document still sitting in the scratch folder is
        // gone for good; it was never saved anywhere the user chose.
        MainWindowController.clearScratch()
        mainWindowController?.rememberOpenFiles()
        guard let controller = mainWindowController else { return .terminateNow }
        if controller.canTerminateImmediately { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        controller.prepareForApplicationTermination { [weak self] shouldTerminate in
            DispatchQueue.main.async {
                self?.terminationReplyPending = false
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func menuToggleReopenLastFiles(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        UserDefaults.standard.set(enabled, forKey: MainWindowController.reopenLastFilesKey)
        sender.state = enabled ? .on : .off
    }

    @objc func showAbout(_ sender: Any?) { AboutWindowController.shared.present() }
    @objc func openGitHub(_ sender: Any?) { NSWorkspace.shared.open(AboutWindowController.githubURL) }

    // MARK: Menu bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About xml-macker", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide xml-macker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit xml-macker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.autoenablesItems = true
        fileMenuItem.submenu = fileMenu

        // Core ones every doc app has: Open, Open Recent, Close, Save,
        // Save As, Revert. Modeled on TextEdit / Xcode / every official
        // Mac doc app. Selectors that need the active document (Save,
        // Save As, Revert) route through MainWindowController which
        // validates them against currentFileURL so they gray out when
        // nothing's open.
        let openItem = NSMenuItem(title: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o")
        openItem.target = self
        // A blank document, not an Open dialog: the + on the tab strip
        // does the same.
        let newItem = NSMenuItem(title: "New",
                                 action: #selector(MainWindowController.menuNewDocument(_:)),
                                 keyEquivalent: "n")
        fileMenu.addItem(newItem)
        fileMenu.addItem(openItem)

        // Open Recent submenu, SELF-MANAGED. The earlier build leaned
        // on the private "_NSRecentDocumentsMenu" identifier so AppKit
        // would populate it, but that mechanism is unreliable for
        // non-NSDocument apps, and our ad-hoc re-sign on every build
        // makes LaunchServices treat each build as a different app, so
        // the system recents never showed up. We keep our own list in
        // UserDefaults and rebuild the submenu ourselves: boring,
        // bulletproof.
        let recentRootItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentRootItem.submenu = recentMenu
        fileMenu.addItem(recentRootItem)
        self.recentMenu = recentMenu
        rebuildRecentMenu()

        fileMenu.addItem(NSMenuItem.separator())

        // Browser/document convention: ⌘W closes the active tab;
        // ⇧⌘W closes the whole window.
        let closeFileItem = NSMenuItem(title: "Close Tab",
                                       action: #selector(MainWindowController.menuCloseFile(_:)),
                                       keyEquivalent: "w")
        fileMenu.addItem(closeFileItem)
        let closeItem = NSMenuItem(title: "Close Window",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "W")
        closeItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeItem)

        fileMenu.addItem(NSMenuItem.separator())

        let saveItem = NSMenuItem(title: "Save",
                                  action: #selector(MainWindowController.menuSave(_:)),
                                  keyEquivalent: "s")
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: "Save As…",
                                    action: #selector(MainWindowController.menuSaveAs(_:)),
                                    keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)
        let revertItem = NSMenuItem(title: "Revert to Saved",
                                    action: #selector(MainWindowController.menuRevert(_:)),
                                    keyEquivalent: "")
        fileMenu.addItem(revertItem)

        fileMenu.addItem(NSMenuItem.separator())

        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(MainWindowController.menuRevealInFinder(_:)),
                                    keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(revealItem)
        let copyPathItem = NSMenuItem(title: "Copy Path",
                                      action: #selector(MainWindowController.menuCopyPath(_:)),
                                      keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .control]
        fileMenu.addItem(copyPathItem)

        fileMenu.addItem(NSMenuItem.separator())
        let reopenItem = NSMenuItem(title: "Reopen Files at Launch",
                                    action: #selector(AppDelegate.menuToggleReopenLastFiles(_:)),
                                    keyEquivalent: "")
        reopenItem.state = MainWindowController.reopenLastFilesEnabled ? .on : .off
        reopenItem.toolTip = "When xml-macker starts without a file, open the files you had open last time"
        fileMenu.addItem(reopenItem)
        fileMenu.addItem(NSMenuItem(title: "Reset All Settings…",
                                    action: #selector(AppDelegate.menuResetAllSettings(_:)),
                                    keyEquivalent: ""))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // The marker pen. Command-H is the system's Hide, so the marker
        // takes shift-command-H.
        let markerRoot = NSMenuItem(title: "Marker", action: nil, keyEquivalent: "")
        let markerMenu = NSMenu(title: "Marker")
        let markerToggle = NSMenuItem(title: "Take the Marker",
                                      action: #selector(MainWindowController.toggleMarker(_:)),
                                      keyEquivalent: "H")
        markerToggle.keyEquivalentModifierMask = [.command, .shift]
        markerMenu.addItem(markerToggle)
        markerMenu.addItem(.separator())
        for (title, raw) in [("Yellow", 3), ("Green", 4), ("Blue", 2), ("Red", 1), ("Eraser", 0)] {
            let item = NSMenuItem(title: title,
                                  action: #selector(MainWindowController.chooseMarkerColor(_:)),
                                  keyEquivalent: "")
            item.representedObject = raw
            markerMenu.addItem(item)
        }
        markerMenu.addItem(.separator())
        let markNow = NSMenuItem(title: "Mark the Selection or This Line Now",
                                 action: #selector(MainWindowController.markNow(_:)),
                                 keyEquivalent: "H")
        markNow.keyEquivalentModifierMask = [.command, .shift, .option]
        markerMenu.addItem(markNow)
        markerMenu.addItem(.separator())
        let nextMark = NSMenuItem(title: "Go to Next Mark",
                                  action: #selector(MainWindowController.jumpToNextMark(_:)),
                                  keyEquivalent: "]")
        nextMark.keyEquivalentModifierMask = [.command, .shift]
        markerMenu.addItem(nextMark)
        let prevMark = NSMenuItem(title: "Go to Previous Mark",
                                  action: #selector(MainWindowController.jumpToPreviousMark(_:)),
                                  keyEquivalent: "[")
        prevMark.keyEquivalentModifierMask = [.command, .shift]
        markerMenu.addItem(prevMark)
        markerMenu.addItem(.separator())
        markerMenu.addItem(NSMenuItem(title: "Remove All Marks",
                                      action: #selector(MainWindowController.removeAllMarks(_:)),
                                      keyEquivalent: ""))
        markerRoot.submenu = markerMenu
        editMenu.addItem(markerRoot)
        editMenu.addItem(NSMenuItem.separator())

        // Everything the app remembers, in one window.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(AppDelegate.showSettings(_:)),
                                      keyEquivalent: ",")
        editMenu.addItem(settingsItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())
        // One find entry: the Find & Replace panel already does
        // everything a find-only command would, so it is not offered.
        let frItem = NSMenuItem(title: "Find and Replace…",
                                action: #selector(MainWindowController.menuFindReplace(_:)),
                                keyEquivalent: "f")
        editMenu.addItem(frItem)

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // Workspace modes, the one-click "stop resizing everything"
        // switcher, same as the toolbar control. ⌥⌘1/2/3/4.
        let wsEntries: [(String, Selector, String)] = [
            ("Layout: Simple",   #selector(MainWindowController.workspaceEditMode(_:)),   "1"),
            ("Layout: Inspect", #selector(MainWindowController.workspaceInspectMode(_:)), "2"),
            ("Layout: Full",   #selector(MainWindowController.workspaceFullMode(_:)),   "3"),
            ("Layout: Learn",  #selector(MainWindowController.workspaceLearnMode(_:)),  "4"),
        ]
        for (label, sel, key) in wsEntries {
            let item = NSMenuItem(title: label, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            viewMenu.addItem(item)
        }
        viewMenu.addItem(NSMenuItem.separator())

        // Zoom, applies to whichever pane the user is currently
        // focused on (first-responder chain: tree, source, inspector
        // tables, subtags table, ...). VS-Code-style ⌘+ / ⌘- / ⌘0.
        // MainWindowController.xmZoomIn dispatches to the active pane.
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(MainWindowController.xmZoomIn(_:)), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(MainWindowController.xmZoomOut(_:)), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Reset Zoom", action: #selector(MainWindowController.xmZoomReset(_:)), keyEquivalent: "0")
        zoomReset.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomReset)

        viewMenu.addItem(NSMenuItem.separator())

        // Jump-to-line prompt, ⌘L brings up a small sheet that asks
        // for a line number and scrolls the source editor to it.
        let gotoItem = NSMenuItem(title: "Go to Line…",
                                  action: #selector(MainWindowController.menuGoToLine(_:)),
                                  keyEquivalent: "l")
        viewMenu.addItem(gotoItem)

        // Line-number gutter toggle. validateMenuItem ticks the
        // item's checkmark to reflect current visibility.
        let lineNumsItem = NSMenuItem(title: "Show Line Numbers",
                                      action: #selector(MainWindowController.menuToggleLineNumbers(_:)),
                                      keyEquivalent: "L")
        lineNumsItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(lineNumsItem)

        // The minimap can be put away, from here or from the small × at
        // its top; the source editor then takes the whole width.
        let minimapItem = NSMenuItem(title: "Show Minimap",
                                     action: #selector(MainWindowController.menuToggleMinimap(_:)),
                                     keyEquivalent: "M")
        minimapItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(minimapItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Validation window, lists parse errors with click-to-jump.
        let valItem = NSMenuItem(title: "Show Validation",
                                 action: #selector(MainWindowController.showValidation(_:)),
                                 keyEquivalent: "E")
        valItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(valItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Pane visibility, organized as two submenus, Show and Hide,
        // each opening onto the full list of panes instead of one long
        // flat menu. Items gray out when not applicable: Show lists
        // only what's hidden/minimized, Hide only what's visible,
        // validated live by MainWindowController.
        let paneTitles = ["Tree", "Source", "Details",
                          "Subtags", "Hierarchy", "Minimap"]
        let showRoot = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        let showMenu = NSMenu(title: "Show")
        let hideRoot = NSMenuItem(title: "Hide", action: nil, keyEquivalent: "")
        let hideMenu = NSMenu(title: "Hide")
        for title in paneTitles {
            let s = NSMenuItem(title: title,
                               action: #selector(MainWindowController.menuShowPane(_:)),
                               keyEquivalent: "")
            s.representedObject = title
            showMenu.addItem(s)
            let h = NSMenuItem(title: title,
                               action: #selector(MainWindowController.menuHidePane(_:)),
                               keyEquivalent: "")
            h.representedObject = title
            hideMenu.addItem(h)
        }
        showRoot.submenu = showMenu
        hideRoot.submenu = hideMenu
        viewMenu.addItem(showRoot)
        viewMenu.addItem(hideRoot)

        // Theme submenu, built straight from Theme.all so the menu, the
        // tick and the palette list can never drift apart again. Routed
        // through MainWindowController so the controller can broadcast
        // rebuildColors() and flip NSWindow.appearance in lockstep.
        viewMenu.addItem(NSMenuItem.separator())
        let themeRootItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        for theme in Theme.all {
            let item = NSMenuItem(title: theme.displayName,
                                  action: #selector(MainWindowController.selectTheme(_:)),
                                  keyEquivalent: "")
            item.representedObject = theme.id
            themeMenu.addItem(item)
        }
        themeRootItem.submenu = themeMenu
        viewMenu.addItem(themeRootItem)

        viewMenu.addItem(NSMenuItem.separator())
        let floatItem = NSMenuItem(title: "Pop-outs Float Above Other Apps",
                                   action: #selector(MainWindowController.togglePopoutsFloat(_:)),
                                   keyEquivalent: "")
        viewMenu.addItem(floatItem)

        // Layout submenu, RStudio-style pane arrangement. Each group
        // is a radio pair (checkmark shows the active side); Reset
        // Layout returns everything to the default arrangement.
        let layoutRootItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Layout")
        let layoutEntries: [(String, Selector)?] = [
            ("Tree on Left",             #selector(MainWindowController.layoutTreeLeft(_:))),
            ("Tree on Right",            #selector(MainWindowController.layoutTreeRight(_:))),
            nil,
            ("Inspector Column on Right", #selector(MainWindowController.layoutInspectorRight(_:))),
            ("Inspector Column on Left", #selector(MainWindowController.layoutInspectorLeft(_:))),
            nil,
            ("Hierarchy at Bottom",      #selector(MainWindowController.layoutHierarchyBottom(_:))),
            ("Hierarchy on Top",         #selector(MainWindowController.layoutHierarchyTop(_:))),
            nil,
            ("Reset Layout",             #selector(MainWindowController.layoutReset(_:))),
        ]
        for entry in layoutEntries {
            if let (label, sel) = entry {
                layoutMenu.addItem(NSMenuItem(title: label, action: sel, keyEquivalent: ""))
            } else {
                layoutMenu.addItem(.separator())
            }
        }
        layoutRootItem.submenu = layoutMenu
        viewMenu.addItem(layoutRootItem)

        // Window menu, the Mac way to reach floating windows (there
        // are no per-window Dock icons on macOS): every popped-out
        // pane, chart, find panel etc. is listed here automatically.
        let windowMenuItem = NSMenuItem()
        // ── Share menu (v0.36.0), print / send-to-LLM / system share.
        let shareMenuItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        let shareMenu = NSMenu(title: "Share")
        shareMenu.addItem(NSMenuItem(title: "Copy Selection in Full (No xml-macker Limit)",
            action: #selector(MainWindowController.shareCopySelectionInFull(_:)), keyEquivalent: ""))
        shareMenu.addItem(NSMenuItem.separator())
        shareMenu.addItem(NSMenuItem(title: "Print Selection…",
            action: #selector(MainWindowController.sharePrintSelection(_:)), keyEquivalent: ""))
        let printEl = NSMenuItem(title: "Print Current Element…",
            action: #selector(MainWindowController.sharePrintCurrentElement(_:)), keyEquivalent: "p")
        shareMenu.addItem(printEl)
        shareMenu.addItem(NSMenuItem(title: "Print Other Element…",
            action: #selector(MainWindowController.sharePrintPickElement(_:)), keyEquivalent: ""))
        shareMenu.addItem(NSMenuItem.separator())
        // Only the element goes out from here. A selection is sent from
        // its own right-click menu, or with Define in Learn, so the Share
        // menu does not offer the same thing twice.
        for (title, kind) in [("Send Current Element to", "element")] {
            let rootItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for target in LLMTarget.allCases {
                let item = NSMenuItem(title: target.displayName,
                    action: #selector(MainWindowController.shareToLLM(_:)), keyEquivalent: "")
                item.representedObject = [target.rawValue, kind]
                sub.addItem(item)
            }
            rootItem.submenu = sub
            shareMenu.addItem(rootItem)
        }
        shareMenu.addItem(NSMenuItem.separator())
        shareMenu.addItem(NSMenuItem(title: "Share File (AirDrop, Mail…)",
            action: #selector(MainWindowController.shareFileSystem(_:)), keyEquivalent: ""))
        shareMenu.addItem(NSMenuItem(title: "Locate File in Finder",
            action: #selector(MainWindowController.menuRevealInFinder(_:)), keyEquivalent: ""))
        shareMenu.addItem(NSMenuItem(title: "Export Current Element as XML…",
            action: #selector(MainWindowController.shareExportElement(_:)), keyEquivalent: ""))
        shareMenuItem.submenu = shareMenu
        mainMenu.addItem(shareMenuItem)

        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Enter Full Screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)),
                                      keyEquivalent: "f"))
        windowMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help: the tour again, and the About info.
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Show Tour…",
                                    action: #selector(MainWindowController.showTour(_:)),
                                    keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(NSMenuItem(title: "About xml-macker",
                                    action: #selector(AppDelegate.showAbout(_:)),
                                    keyEquivalent: ""))
        // The GitHub link lives in About, so the menu does not repeat it.
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    // File > Reset All Settings…, the standard dev pattern is
    // "restore defaults + restart" (Apple apps use `defaults delete`).
    // Wipes the app's whole preference domain: theme, layout,
    // workspace, remembered dialog answers, recent files, saved
    // window frames. XML files are untouched.
    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        let main = NSApp.mainWindow?.windowController as? MainWindowController
            ?? NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
        if settingsWindow == nil { settingsWindow = SettingsWindowController(main: main) }
        settingsWindow?.present()
    }

    @objc func menuResetAllSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset xml-macker to a fresh start?"
        alert.informativeText = "Theme, layout, workspace mode, remembered choices, recent files and window positions all return to defaults, and the app restarts. Your XML files are not touched."
        alert.addButton(withTitle: "Reset and Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            // Wiping the domain also wipes the migration flag, so stamp it
            // again or the next launch pulls every old setting back in.
            LegacyDefaults.markMigrated()
            UserDefaults.standard.synchronize()
        }
        let restart = { [weak self] in
            let path = Bundle.main.bundlePath
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
            try? task.run()
            self?.mainWindowController?.approveImmediateTermination()
            NSApp.terminate(nil)
        }
        if let controller = mainWindowController, !controller.canTerminateImmediately {
            controller.prepareForApplicationTermination { allowed in
                if allowed { restart() }
            }
        } else {
            restart()
        }
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an XML file"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.mainWindowController?.openFiles(panel.urls)
        }
    }
}
