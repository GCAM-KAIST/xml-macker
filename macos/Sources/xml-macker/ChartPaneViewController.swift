import Cocoa

// Chart detail section, selected from the shared right-side Details rail.
// The chart fills the rail and retains a useful large pop-out view without
// imitating close/minimize controls inside the document window.
final class ChartPaneViewController: NSViewController {
    var onSeriesChanged: ((TrendSeries?) -> Void)?

    private let trendView = TrendView()
    private let varLabel = NSTextField(labelWithString: "Series:")
    private let varPopup = NSPopUpButton(title: "", target: nil, action: nil)
    private var pickerHeightCon: NSLayoutConstraint?
    private static let pickerHeight: CGFloat = 22

    private var currentNode: XMLTreeNode?

    var exposedTrendView: TrendView { trendView }
    var currentTrendSeries: TrendSeries? { trendView.series }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        varLabel.translatesAutoresizingMaskIntoConstraints = false
        varLabel.font = XMFont.uiCaption
        varLabel.textColor = XMColor.text3
        v.addSubview(varLabel)

        varPopup.translatesAutoresizingMaskIntoConstraints = false
        varPopup.target = self
        varPopup.action = #selector(variableChanged(_:))
        varPopup.bezelStyle = .rounded
        varPopup.controlSize = .small
        varPopup.font = XMFont.ui(11, .medium)
        v.addSubview(varPopup)

        trendView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(trendView)

        let pickerH = varPopup.heightAnchor.constraint(equalToConstant: 0)
        self.pickerHeightCon = pickerH
        varLabel.isHidden = true
        varPopup.isHidden = true

        NSLayoutConstraint.activate([
            varLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            varLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            varPopup.leadingAnchor.constraint(equalTo: varLabel.trailingAnchor, constant: 8),
            varPopup.centerYAnchor.constraint(equalTo: varLabel.centerYAnchor),
            varPopup.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            pickerH,

            // The chart FILLS the pane, its size is whatever the
            // user gives the pane, not a hard-coded strip.
            trendView.topAnchor.constraint(equalTo: varPopup.bottomAnchor, constant: 6),
            trendView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            trendView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            trendView.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        view = v
    }

    func setNode(_ node: XMLTreeNode) {
        currentNode = node
        let options = TrendComputer.availableTargets(for: node)
        trendView.placeholderText = "No comparable numeric values under this element"

        // Preserve the previously-selected variable when it still
        // applies, keeps the chart's "mode" stable while the user
        // navigates between similar elements.
        let previouslySelected = varPopup.titleOfSelectedItem
        varPopup.removeAllItems()
        varPopup.addItems(withTitles: options)
        let chosen: String? = options.contains(previouslySelected ?? "")
            ? previouslySelected
            : options.first
        if let chosen = chosen { varPopup.selectItem(withTitle: chosen) }

        let showPicker = options.count >= 2
        varLabel.isHidden = !showPicker
        varPopup.isHidden = !showPicker
        pickerHeightCon?.constant = showPicker ? XMMetric.s(Self.pickerHeight) : 0

        trendView.series = TrendComputer.compute(for: node, preferring: chosen)
        onSeriesChanged?(trendView.series)
    }

    @objc private func variableChanged(_ sender: NSPopUpButton) {
        guard let node = currentNode,
              let chosen = sender.titleOfSelectedItem else { return }
        if let series = TrendComputer.compute(for: node, preferring: chosen) {
            trendView.series = series
        } else {
            // Honest empty state, never keep the previous variable's
            // series under a dropdown that names a different one.
            trendView.series = nil
            trendView.placeholderText = "No comparison available for '\(chosen)' here"
        }
        onSeriesChanged?(trendView.series)
    }

    func refreshCurrent() {
        if let node = currentNode { setNode(node) }
    }

    // Global zoom hook.
    func rebuildFonts() {
        varLabel.font = XMFont.uiCaption
        varPopup.font = XMFont.ui(11, .medium)
        if !varPopup.isHidden {
            pickerHeightCon?.constant = XMMetric.s(Self.pickerHeight)
        }
        trendView.needsDisplay = true
    }

    // Theme hook.
    func rebuildColors() {
        varLabel.textColor = XMColor.text3
        trendView.rebuildColors()
    }
}
