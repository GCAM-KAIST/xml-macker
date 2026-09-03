import Cocoa

// Horizontal path of the currently-selected element's ancestors.
// Each segment is an NSButton styled as a chip. The last segment
// (the current node) is accent-tinted and bold. Separators are `›`.
//
// Clicking a segment fires `onSegmentClicked(node)` which the main
// window routes to treeVC.select, keeping the consistency rule of
// the app: any click anywhere reflects everywhere.
final class BreadcrumbBar: NSView {
    var onSegmentClicked: ((XMLTreeNode) -> Void)?

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var currentPath: [XMLTreeNode] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.autoresizingMask = [.height]

        let flipped = FlippedClip()
        scrollView.contentView = flipped
        scrollView.documentView = stack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setPath([])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The crumbs cache their colours, so replay the path to re-tint.
    func rebuildColors() { setPath(currentPath) }

    func setPath(_ path: [XMLTreeNode]) {
        currentPath = path
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !path.isEmpty else {
            let empty = NSTextField(labelWithString: "No selection")
            empty.font = XMFont.uiSmall
            empty.textColor = XMColor.text3
            stack.addArrangedSubview(empty)
            return
        }
        for (idx, node) in path.enumerated() {
            let isLast = (idx == path.count - 1)
            let chip = makeChip(for: node, highlighted: isLast)
            stack.addArrangedSubview(chip)
            if !isLast {
                let sep = NSTextField(labelWithString: "›")
                sep.font = XMFont.mono(12, .regular)
                sep.textColor = XMColor.text3
                sep.isBordered = false
                sep.drawsBackground = false
                sep.isEditable = false
                stack.addArrangedSubview(sep)
            }
        }
    }

    private func makeChip(for node: XMLTreeNode, highlighted: Bool) -> NSView {
        let btn = ChipButton(node: node)
        btn.title = node.displayLabel
        btn.font = XMFont.mono(11, highlighted ? .semibold : .regular)
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.contentTintColor = highlighted ? XMColor.text : XMColor.text2
        btn.target = self
        btn.action = #selector(segmentClicked(_:))
        btn.setButtonType(.momentaryChange)
        btn.cell?.backgroundStyle = .normal
        btn.wantsLayer = true
        btn.layer?.cornerRadius = XMMetric.radiusPill
        btn.layer?.backgroundColor = highlighted
            ? XMColor.accent.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        if highlighted {
            btn.layer?.borderColor = XMColor.accent.withAlphaComponent(0.45).cgColor
            btn.layer?.borderWidth = XMMetric.hairline
        }
        btn.contentEdgeInset = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        return btn
    }

    @objc private func segmentClicked(_ sender: ChipButton) {
        guard let node = sender.node else { return }
        onSegmentClicked?(node)
    }
}

// NSButton carrying a tree node reference.
private final class ChipButton: NSButton {
    let node: XMLTreeNode?
    var contentEdgeInset: NSEdgeInsets = .init(top: 3, left: 8, bottom: 3, right: 8)
    init(node: XMLTreeNode) {
        self.node = node
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { self.node = nil; super.init(coder: coder) }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width  += contentEdgeInset.left + contentEdgeInset.right
        s.height += contentEdgeInset.top + contentEdgeInset.bottom
        return s
    }
}

// Subclassed clip view used to keep document content top-aligned.
private final class FlippedClip: NSClipView {
    override var isFlipped: Bool { true }
}
