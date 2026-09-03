import Cocoa

// Share menu support (v0.36.0). Printing comes first (print
// selection, print main element with a chooser), then the LLM
// targets, where one click opens the browser.
//
// LLM reality check: a browser can't receive a file attachment from a
// plain URL, so the contract is: the payload ALWAYS goes to the
// clipboard, and when it's small enough it is ALSO pre-filled into the
// chat through the site's ?q= parameter. Large payloads use the
// provider-neutral, explicitly confirmed policy in ShareTextPolicy:
// either a disclosed compatibility excerpt or an uncapped full copy.
enum LLMTarget: String, CaseIterable {
    case chatgpt, claude, gemini, grok, perplexity
    // The well-known Chinese models: DeepSeek, Qwen (Alibaba),
    // GLM = Zhipu's Z.ai, Kimi (Moonshot), Manus.
    case deepseek, qwen, glm, kimi, manus

    var displayName: String {
        switch self {
        case .chatgpt:    return "ChatGPT"
        case .claude:     return "Claude"
        case .gemini:     return "Gemini"
        case .grok:       return "Grok"
        case .perplexity: return "Perplexity"
        case .deepseek:   return "DeepSeek"
        case .qwen:       return "Qwen"
        case .glm:        return "GLM (Z.ai)"
        case .kimi:       return "Kimi"
        case .manus:      return "Manus"
        }
    }

    private var home: String {
        switch self {
        case .chatgpt:    return "https://chatgpt.com/"
        case .claude:     return "https://claude.ai/new"
        case .gemini:     return "https://gemini.google.com/app"
        case .grok:       return "https://grok.com/"
        case .perplexity: return "https://www.perplexity.ai/"
        case .deepseek:   return "https://chat.deepseek.com/"
        case .qwen:       return "https://chat.qwen.ai/"
        case .glm:        return "https://chat.z.ai/"
        case .kimi:       return "https://www.kimi.com/"
        case .manus:      return "https://manus.im/"
        }
    }

    // Gemini has no documented prefill parameter, it opens plain and
    // the clipboard carries the payload.
    func url(prefill: String?) -> URL {
        guard let prefill,
              // Percent-encoding a multi-megabyte selection only to reject the
              // resulting URL wastes time and memory. Encoded text can never
              // be shorter than its UTF-8 representation, so reject early.
              prefill.utf8.count <= 6000,
              let encoded = prefill.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              encoded.count <= 6000 else {
            return URL(string: home)!
        }
        switch self {
        case .chatgpt:    return URL(string: "https://chatgpt.com/?q=\(encoded)")!
        case .claude:     return URL(string: "https://claude.ai/new?q=\(encoded)")!
        case .grok:       return URL(string: "https://grok.com/?q=\(encoded)")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/search?q=\(encoded)")!
        // No known prefill parameter, clipboard carries the payload.
        case .gemini, .deepseek, .qwen, .glm, .kimi, .manus:
            return URL(string: home)!
        }
    }
}

// Small tree-browser panel: pick any element, hit Choose (or
// double-click). Used by Share > Print Other Element….
final class ElementPickerWindowController: NSWindowController,
                                           NSOutlineViewDataSource,
                                           NSOutlineViewDelegate,
                                           NSWindowDelegate {
    private let root: XMLTreeNode
    private let onPick: (XMLTreeNode) -> Void
    private let outline = NSOutlineView()
    private var selfRef: ElementPickerWindowController?   // keeps us alive while shown

    init(root: XMLTreeNode, title: String, onPick: @escaping (XMLTreeNode) -> Void) {
        self.root = root
        self.onPick = onPick
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = title
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self   // red-button close must also drop selfRef

        let content = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = XMColor.bgDeep

        outline.dataSource = self
        outline.delegate = self
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 20
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("el"))
        col.width = 380
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.target = self
        outline.doubleAction = #selector(chooseClicked)
        scroll.documentView = outline
        content.addSubview(scroll)

        let choose = NSButton(title: "Choose", target: self, action: #selector(chooseClicked))
        choose.bezelStyle = .rounded
        choose.keyEquivalent = "\r"
        choose.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(choose)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            choose.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            choose.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            choose.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: choose.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: choose.leadingAnchor, constant: -8),
        ])
        win.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(over parent: NSWindow?) {
        selfRef = self
        if let parent {
            var frame = window!.frame
            frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2,
                                   y: parent.frame.midY - frame.height / 2)
            window!.setFrame(frame, display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Expand the first couple of levels so it doesn't open blank.
        outline.expandItem(nil, expandChildren: false)
        for child in elementChildren(of: root) { outline.expandItem(child) }
    }

    @objc private func chooseClicked() {
        let row = outline.selectedRow >= 0 ? outline.selectedRow : outline.clickedRow
        if row >= 0, let node = outline.item(atRow: row) as? XMLTreeNode {
            onPick(node)
        }
        dismiss()
    }

    @objc private func cancelClicked() { dismiss() }

    func windowWillClose(_ notification: Notification) { selfRef = nil }

    private func dismiss() {
        window?.orderOut(nil)
        selfRef = nil
    }

    private func elementChildren(of node: XMLTreeNode) -> [XMLTreeNode] {
        node.children.filter { $0.kind == .element }
    }

    // MARK: Outline plumbing

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        elementChildren(of: (item as? XMLTreeNode) ?? root).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        elementChildren(of: (item as? XMLTreeNode) ?? root)[index]
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
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let detail = n.displayDetail
        let s = NSMutableAttributedString(string: n.displayLabel, attributes: [
            .font: XMFont.mono(11.5, .medium), .foregroundColor: XMColor.syntaxTag])
        if !detail.isEmpty {
            s.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: XMFont.mono(10.5, .regular), .foregroundColor: XMColor.text3]))
        }
        cell.textField?.attributedStringValue = s
        return cell
    }
}
