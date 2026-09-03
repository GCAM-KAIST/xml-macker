import Cocoa

// Preview detail section, selected from the shared right-side Details
// rail: the bytes of the currently-selected element, up to 1 MB,
// dedented so nested content reads cleanly. Errors used to be a second
// tab here, v0.44.3 gave them their own Details section
// (ErrorsPaneViewController) with a red badge on the rail.
final class PreviewPaneViewController: NSViewController {

    // Exposed so MainWindowController's per-pane zoom dispatch knows
    // which pane the first-responder lives in.
    var exposedPreviewView: NSTextView { previewView }

    // Per-pane zoom, matches the pattern used elsewhere.
    private(set) var zoomStep: Int = 0
    func zoomIn()    { zoomStep = min(zoomStep + 1, 16); applyZoom() }
    func zoomOut()   { zoomStep = max(zoomStep - 1, -3); applyZoom() }
    func zoomReset() { zoomStep = 0; applyZoom() }
    private func applyZoom() {
        previewView.font = XMFont.mono(11 + CGFloat(zoomStep), .regular)
    }

    // Global zoom slider hook.
    func rebuildFonts() {
        headerNote.font = XMFont.uiCaption
        applyZoom()
    }

    // Theme hook, re-apply NSColor backgrounds baked at init so
    // Light themes actually paint white surfaces instead of keeping
    // the dark color snapshotted at launch.
    func rebuildColors() {
        previewScroll.backgroundColor = XMColor.bgDeep
        previewView.backgroundColor = XMColor.bgDeep
        previewView.textColor = XMColor.text
        headerNote.textColor = XMColor.text3
    }

    private let headerNote = NSTextField(labelWithString: "")
    private let previewScroll = NSScrollView()
    private let previewView = XMLDropForwardingTextView()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        headerNote.translatesAutoresizingMaskIntoConstraints = false
        headerNote.font = XMFont.uiCaption
        headerNote.textColor = XMColor.text3
        headerNote.lineBreakMode = .byTruncatingTail
        v.addSubview(headerNote)

        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = XMColor.bgDeep
        previewScroll.borderType = .noBorder

        previewView.translatesAutoresizingMaskIntoConstraints = true
        previewView.minSize = .zero
        previewView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                     height: CGFloat.greatestFiniteMagnitude)
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = false
        previewView.font = XMFont.monoSmall
        previewView.textColor = XMColor.text
        previewView.backgroundColor = XMColor.bgDeep
        previewView.drawsBackground = true
        previewView.isVerticallyResizable = true
        previewView.isHorizontallyResizable = true
        // No-wrap: the autoresizing mask must NOT include .width, that
        // flag clamps the text view's frame to the scroll view's width,
        // forcing TextKit to reflow (the "many indents" look when the
        // pane is narrow). Empty mask + infinite container width means
        // long lines extend and the horizontal scroller takes over.
        previewView.autoresizingMask = []
        previewView.textContainerInset = NSSize(width: 6, height: 6)
        if let container = previewView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
        }
        previewScroll.documentView = previewView
        v.addSubview(previewScroll)

        NSLayoutConstraint.activate([
            headerNote.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            headerNote.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            headerNote.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            previewScroll.topAnchor.constraint(equalTo: headerNote.bottomAnchor, constant: 6),
            previewScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            previewScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            previewScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        view = v
    }

    // MARK: public API

    func updatePreview(text: String, truncated: Bool) {
        previewView.string = dedent(text)
        // Wording matters: "truncated at 1 MB" read as "your file was
        // truncated" and scared the user. The cap only limits how much
        // of the SELECTED ELEMENT this preview box displays, the file
        // itself is fully loaded and intact.
        headerNote.stringValue = truncated
            ? "large element, preview shows its first 1 MB (file is fully loaded)"
            : ""
    }

    // Dedent: strip the longest common leading-whitespace prefix so
    // nested XML reads cleanly instead of drifting right.
    private func dedent(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        var minIndent: Int = .max
        for line in lines {
            if line.isEmpty { continue }
            var count = 0
            for ch in line {
                if ch == " " || ch == "\t" { count += 1 } else { break }
            }
            if count < line.count {
                minIndent = min(minIndent, count)
                if minIndent == 0 { break }
            }
        }
        guard minIndent > 0, minIndent != .max else { return s }
        return lines.map { line -> String in
            if line.isEmpty { return line }
            let drop = min(minIndent, line.count)
            return String(line.dropFirst(drop))
        }.joined(separator: "\n")
    }
}
