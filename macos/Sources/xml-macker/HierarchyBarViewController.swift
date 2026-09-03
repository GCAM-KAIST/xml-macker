import Cocoa

// Thin wrapper around HierarchyMiniView that lives as its own pane
// at the bottom of the window (below the Subtags strip). Giving the
// hierarchy view the full window width means the child boxes get
// enough room to show the real tag names instead of truncating to
// "AgProduct…" the way they did when the view was squeezed into the
// narrow inspector column.
final class HierarchyBarViewController: NSViewController {

    let hierarchy = HierarchyMiniView()
    private let titleLabel = NSTextField(labelWithString: "HIERARCHY")
    // "Structure only", shared preference with Orbit (StructureFilter).
    private let structureToggle = NSButton(checkboxWithTitle: "Structure only",
                                           target: nil, action: nil)
    private var structureObserver: NSObjectProtocol?

    var onChildClicked: ((XMLTreeNode) -> Void)? {
        get { hierarchy.onChildClicked }
        set { hierarchy.onChildClicked = newValue }
    }

    deinit {
        if let o = structureObserver { NotificationCenter.default.removeObserver(o) }
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.uiCaption
        titleLabel.textColor = XMColor.text3
        // The pane's own header bar already says HIERARCHY; printing it
        // twice just eats a row.
        titleLabel.isHidden = true
        v.addSubview(titleLabel)

        structureToggle.translatesAutoresizingMaskIntoConstraints = false
        structureToggle.target = self
        structureToggle.action = #selector(toggleStructure(_:))
        structureToggle.controlSize = .small
        structureToggle.font = XMFont.uiCaption
        structureToggle.state = StructureFilter.enabled ? .on : .off
        structureToggle.toolTip = "Show only elements that contain other elements; plain values fold into one bar"
        v.addSubview(structureToggle)

        hierarchy.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(hierarchy)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            structureToggle.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            structureToggle.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            structureToggle.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

            hierarchy.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            hierarchy.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            hierarchy.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            hierarchy.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        // Keep the checkbox honest when Orbit flips the same preference.
        structureObserver = NotificationCenter.default.addObserver(
            forName: StructureFilter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.structureToggle.state = StructureFilter.enabled ? .on : .off
        }

        view = v
    }

    @objc private func toggleStructure(_ sender: NSButton) {
        StructureFilter.enabled = sender.state == .on
    }

    func setNode(_ node: XMLTreeNode) {
        hierarchy.setNode(node)
    }

    // Global zoom slider hook. HierarchyMiniView's intrinsicContentSize
    // folds in the global scale; we poke auto-layout to re-query it
    // so the pane resizes itself, and redraw since the node drawing
    // also uses XMFont (which picked up the new scale already).
    func rebuildFonts() {
        titleLabel.font = XMFont.uiCaption
        structureToggle.font = XMFont.uiCaption
        hierarchy.invalidateIntrinsicContentSize()
        hierarchy.needsDisplay = true
    }
}
