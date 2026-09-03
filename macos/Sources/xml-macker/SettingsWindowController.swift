// SettingsWindowController.swift
//
// Every preference in one place (Edit ▸ Settings…, ⌘,).
//
// None of these settings are new. They already existed and already
// applied the moment they changed, but they were scattered across the
// File menu, the View menu, the Layout submenu and the zoom slider in
// the status bar, so nobody could see what the app remembered about
// them. This window gathers them and changes nothing about how they
// work: every control writes through the same code the menu item does,
// and takes effect at once.

import Cocoa

final class SettingsWindowController: NSWindowController {

    private weak var main: MainWindowController?
    private var zoomLabel: NSTextField!
    private weak var zoomSlider: NSSlider?

    init(main: MainWindowController?) {
        self.main = main
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        super.init(window: win)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: building blocks

    private func heading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = XMFont.ui(10, .bold)
        f.textColor = XMColor.text3
        return f
    }

    /// A quiet line of explanation under a setting.
    private func note(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = XMFont.uiSmall
        f.textColor = XMColor.text3
        f.preferredMaxLayoutWidth = 430
        return f
    }

    private func check(_ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.font = XMFont.uiBody
        b.target = ActionProxy.shared
        b.action = #selector(ActionProxy.fire(_:))
        ActionProxy.shared.handlers[ObjectIdentifier(b)] = { action(b.state == .on) }
        return b
    }

    private func buildLayout() {
        guard let win = window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = XMColor.bg.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ── General ──────────────────────────────────────────────────
        stack.addArrangedSubview(heading("General"))
        stack.addArrangedSubview(check("Reopen the files I had open, at launch",
                                       MainWindowController.reopenLastFilesEnabled) { on in
            UserDefaults.standard.set(on, forKey: MainWindowController.reopenLastFilesKey)
        })
        stack.addArrangedSubview(note("Large files take a while to load, so you may prefer to start empty and open what you need."))
        stack.addArrangedSubview(check("Ask before closing a window with more than one file open",
                                       MainWindowController.askOnCloseEnabled) { on in
            UserDefaults.standard.set(on, forKey: MainWindowController.askOnCloseKey)
        })
        // Closing a window with several files open. The same three
        // answers the question itself offers, so a remembered choice can
        // be changed here instead of by resetting everything.
        let closeRow = NSStackView()
        closeRow.orientation = .horizontal
        closeRow.spacing = 8
        let closeLabel = NSTextField(labelWithString: "Closing a window with several files open")
        closeLabel.font = XMFont.uiBody
        closeLabel.textColor = XMColor.text2
        let closePop = NSPopUpButton()
        for t in ["Ask me every time", "Close only the current tab", "Close all files"] {
            closePop.addItem(withTitle: t)
        }
        switch UserDefaults.standard.string(forKey: MainWindowController.closeChoiceKey) {
        case "tab": closePop.selectItem(at: 1)
        case "all": closePop.selectItem(at: 2)
        default:    closePop.selectItem(at: 0)
        }
        closePop.target = self
        closePop.action = #selector(closeChoiceChanged(_:))
        closeRow.addArrangedSubview(closeLabel)
        closeRow.addArrangedSubview(closePop)
        stack.addArrangedSubview(closeRow)

        let tourBtn = NSButton(title: "Show the tour again", target: self, action: #selector(showTour))
        tourBtn.bezelStyle = .rounded
        stack.addArrangedSubview(tourBtn)

        stack.addArrangedSubview(spacer())

        // ── Appearance ───────────────────────────────────────────────
        stack.addArrangedSubview(heading("Appearance"))
        let themeRow = NSStackView()
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        let themeLabel = NSTextField(labelWithString: "Theme")
        themeLabel.font = XMFont.uiBody
        themeLabel.textColor = XMColor.text2
        let themePopUp = NSPopUpButton()
        for t in Theme.all { themePopUp.addItem(withTitle: t.displayName) }
        themePopUp.selectItem(at: Theme.all.firstIndex(where: { $0.id == ThemeManager.current.id }) ?? 0)
        themePopUp.target = self
        themePopUp.action = #selector(themeChanged(_:))
        themeRow.addArrangedSubview(themeLabel)
        themeRow.addArrangedSubview(themePopUp)
        stack.addArrangedSubview(themeRow)

        let zoomRow = NSStackView()
        zoomRow.orientation = .horizontal
        zoomRow.spacing = 8
        let zl = NSTextField(labelWithString: "Zoom")
        zl.font = XMFont.uiBody
        zl.textColor = XMColor.text2
        let slider = NSSlider(value: Double(XMFont.globalScale), minValue: 0.5, maxValue: 2.0,
                              target: self, action: #selector(zoomChanged(_:)))
        zoomSlider = slider
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        zoomLabel = NSTextField(labelWithString: "\(Int((XMFont.globalScale * 100).rounded()))%")
        zoomLabel.font = XMFont.mono(11, .medium)
        zoomLabel.textColor = XMColor.text2
        zoomRow.addArrangedSubview(zl)
        zoomRow.addArrangedSubview(slider)
        zoomRow.addArrangedSubview(zoomLabel)
        stack.addArrangedSubview(zoomRow)
        let zoomBack = NSButton(title: "Back to \(Int((XMFont.defaultScale * 100).rounded())) %",
                                target: self, action: #selector(zoomBackToDefault(_:)))
        zoomBack.bezelStyle = .rounded
        zoomBack.controlSize = .small
        stack.addArrangedSubview(zoomBack)
        stack.addArrangedSubview(note("Scales the whole app, 50 % to 200 %. The slider at the bottom right of the main window does the same."))

        stack.addArrangedSubview(spacer())

        // ── Editor ───────────────────────────────────────────────────
        stack.addArrangedSubview(heading("Editor"))
        stack.addArrangedSubview(check("Show line numbers",
                                       main?.sourceLineNumbersVisible ?? true) { [weak self] _ in
            self?.main?.menuToggleLineNumbers(nil)
        })
        stack.addArrangedSubview(check("Show the minimap beside the source",
                                       MainWindowController.minimapVisible) { [weak self] on in
            self?.main?.setMinimapVisible(on)
        })
        stack.addArrangedSubview(check("Structure only, hide plain values in Hierarchy and Orbit",
                                       StructureFilter.enabled) { on in
            StructureFilter.enabled = on
        })

        stack.addArrangedSubview(spacer())

        // ── Windows ──────────────────────────────────────────────────
        stack.addArrangedSubview(heading("Pop-out windows"))
        stack.addArrangedSubview(check("Float above every other application",
                                       MainWindowController.popoutsFloat) { [weak self] _ in
            self?.main?.togglePopoutsFloat(nil)
        })
        stack.addArrangedSubview(note("Off: a pop-out behaves like any other window. On: it floats above everything, including other programs."))

        stack.addArrangedSubview(spacer())

        // ── Learn ────────────────────────────────────────────────────
        stack.addArrangedSubview(heading("Learn"))
        let chatRow = NSStackView()
        chatRow.orientation = .horizontal
        chatRow.spacing = 8
        let chatLabel = NSTextField(labelWithString: "Chat site")
        chatLabel.font = XMFont.uiBody
        chatLabel.textColor = XMColor.text2
        let chatPop = NSPopUpButton()
        for c in LearnPaneViewController.Chat.allCases { chatPop.addItem(withTitle: c.title) }
        chatPop.selectItem(at: LearnPaneViewController.defaultChat.rawValue)
        chatPop.target = self
        chatPop.action = #selector(chatSiteChanged(_:))
        chatRow.addArrangedSubview(chatLabel)
        chatRow.addArrangedSubview(chatPop)
        stack.addArrangedSubview(chatRow)
        stack.addArrangedSubview(note("The site the Learn workspace opens, and the one Send Current Element to types the element into."))

        stack.addArrangedSubview(spacer())

        // ── Reset ────────────────────────────────────────────────────
        let reset = NSButton(title: "Reset Everything and Restart", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        win.contentView = root
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    @objc private func zoomBackToDefault(_ sender: Any?) {
        main?.applyGlobalScale(XMFont.defaultScale)
        zoomSlider?.doubleValue = Double(XMFont.defaultScale)
        zoomLabel.stringValue = "\(Int((XMFont.defaultScale * 100).rounded()))%"
    }

    @objc private func closeChoiceChanged(_ sender: NSPopUpButton) {
        let d = UserDefaults.standard
        switch sender.indexOfSelectedItem {
        case 1: d.set("tab", forKey: MainWindowController.closeChoiceKey)
        case 2: d.set("all", forKey: MainWindowController.closeChoiceKey)
        default: d.removeObject(forKey: MainWindowController.closeChoiceKey)
        }
    }

    @objc private func chatSiteChanged(_ sender: NSPopUpButton) {
        guard let c = LearnPaneViewController.Chat(rawValue: sender.indexOfSelectedItem) else { return }
        LearnPaneViewController.defaultChat = c
        main?.applyDefaultChatSite()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Theme.all.count else { return }
        let item = NSMenuItem()
        item.representedObject = Theme.all[i].id
        main?.selectTheme(item)
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue)
        zoomLabel.stringValue = "\(Int((v * 100).rounded()))%"
        main?.applyGlobalScale(v)
    }

    @objc private func showTour() {
        close()
        main?.showTour(nil)
    }

    @objc private func resetAll() {
        (NSApp.delegate as? AppDelegate)?.menuResetAllSettings(nil)
    }

    func present() {
        window?.appearance = ThemeManager.current.appearance
        window?.backgroundColor = XMColor.bg
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Checkboxes built in a loop need a target that outlives the loop.
private final class ActionProxy: NSObject {
    static let shared = ActionProxy()
    var handlers: [ObjectIdentifier: () -> Void] = [:]
    @objc func fire(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?() }
}
