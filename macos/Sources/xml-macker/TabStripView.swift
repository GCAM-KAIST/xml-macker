import Cocoa

// Multi-tab strip above the breadcrumb bar (real multi-document since
// v0.35.0, was a one-tab scaffold before). Chrome model: click a tab
// to switch, × to close it, + to open another file.
final class TabStripView: NSView {
    private let scroller = NSScrollView()
    private let stack = NSStackView()
    private var chips: [TabChip] = []
    private let plusButton = NSButton()

    var onTabSelected: ((URL) -> Void)?
    var onTabCloseRequested: ((URL) -> Void)?
    var onPlusClicked: (() -> Void)?
    /// Right-click on a tab: close it, close the others, copy its path,
    /// or show it in the Finder.
    var onCloseOtherTabs: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Many tabs scroll horizontally instead of crushing each other.
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = false
        scroller.hasHorizontalScroller = false
        scroller.verticalScrollElasticity = .none
        scroller.documentView = stack
        addSubview(scroller)

        // Big circular +: the previous one was too small a target.
        plusButton.title = "＋"
        plusButton.font = XMFont.ui(15, .semibold)
        plusButton.isBordered = false
        plusButton.contentTintColor = XMColor.text2
        plusButton.toolTip = "Open another file in a new tab"
        plusButton.wantsLayer = true
        plusButton.layer?.cornerRadius = 11
        plusButton.layer?.backgroundColor = XMColor.glassTop.cgColor
        plusButton.layer?.borderWidth = XMMetric.hairline
        plusButton.layer?.borderColor = XMColor.hairlineS.cgColor
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        plusButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        plusButton.target = self
        plusButton.action = #selector(plusClicked)

        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor),
        ])

        setTabs([], activeIndex: -1)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastURLs: [URL] = []
    private var lastActive: Int = 0

    /// Chips cache their colours, so replay the last content to re-tint.
    func rebuildColors() { setTabs(lastURLs, activeIndex: lastActive) }

    func setTabs(_ urls: [URL], activeIndex: Int) {
        lastURLs = urls
        lastActive = activeIndex
        chips.forEach { $0.removeFromSuperview() }
        chips.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "No file")
            empty.font = XMFont.uiSmall
            empty.textColor = XMColor.text3
            stack.addArrangedSubview(empty)
        } else {
            for (i, url) in urls.enumerated() {
                let chip = TabChip(url: url, active: i == activeIndex)
                chip.onSelect = { [weak self] u in self?.onTabSelected?(u) }
                chip.onClose  = { [weak self] u in self?.onTabCloseRequested?(u) }
                chip.onCloseOthers = { [weak self] u in self?.onCloseOtherTabs?(u) }
                chips.append(chip)
                stack.addArrangedSubview(chip)
            }
        }
        stack.addArrangedSubview(plusButton)
    }

    // Legacy single-file API kept for any straggler call sites.
    func setFile(_ url: URL?) {
        if let url { setTabs([url], activeIndex: 0) } else { setTabs([], activeIndex: -1) }
    }

    @objc private func plusClicked() {
        onPlusClicked?()
    }
}

// One tab: translucent pill with filename + close button. Clicking
// the pill selects its tab; the × closes it.
final class TabChip: NSView {
    let url: URL
    let active: Bool
    var onSelect: ((URL) -> Void)?
    var onClose: ((URL) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let closeBtn  = NSButton()

    init(url: URL, active: Bool) {
        self.url = url
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = XMMetric.radiusPill
        layer?.backgroundColor = active
            ? XMColor.glassTop.cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = active ? XMColor.hairline.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = active ? XMMetric.hairline : 0
        toolTip = url.path

        nameLabel.stringValue = url.lastPathComponent
        nameLabel.font = XMFont.mono(11, active ? .medium : .regular)
        nameLabel.textColor = active ? XMColor.text : XMColor.text2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        closeBtn.title = "×"
        closeBtn.font = XMFont.uiBodyB
        closeBtn.isBordered = false
        closeBtn.contentTintColor = XMColor.text3
        closeBtn.target = self
        closeBtn.action = #selector(closeClicked)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeBtn)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            closeBtn.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // The × button handles its own clicks; anywhere else on the
        // pill selects the tab.
        onSelect?(url)
    }

    var onCloseOthers: ((URL) -> Void)?

    /// The menu is titled with the file name so there is no doubt which
    /// tab it belongs to.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(title: url.lastPathComponent)
        let header = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(menuClose), keyEquivalent: "")
        close.target = self
        m.addItem(close)
        let others = NSMenuItem(title: "Close Other Tabs", action: #selector(menuCloseOthers), keyEquivalent: "")
        others.target = self
        m.addItem(others)
        m.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Full Path", action: #selector(menuCopyPath), keyEquivalent: "")
        copy.target = self
        m.addItem(copy)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(menuReveal), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = FileManager.default.fileExists(atPath: url.path)
        m.addItem(reveal)
        return m
    }

    @objc private func menuClose()       { onClose?(url) }
    @objc private func menuCloseOthers() { onCloseOthers?(url) }
    @objc private func menuCopyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func menuReveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func closeClicked() {
        onClose?(url)
    }
}
