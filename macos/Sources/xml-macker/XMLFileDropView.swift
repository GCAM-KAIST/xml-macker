import Cocoa
import WebKit

/// Native Finder drag destination for the whole document window.
final class XMLFileDropView: NSView {
    var onFilesDropped: (([URL]) -> Void)?

    private var overlay: XMLDropOverlayView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = acceptableURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        showOverlay(fileCount: urls.count)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideOverlay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !acceptableURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = acceptableURLs(from: sender)
        hideOverlay()
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideOverlay()
    }

    /// True when the drag carries at least one XML-family file.
    func accepts(_ sender: NSDraggingInfo) -> Bool {
        !acceptableURLs(from: sender).isEmpty
    }

    private func acceptableURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { object -> URL? in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
        return XMLDocumentSupport.canonicalFileURLs(urls)
            .filter(XMLDocumentSupport.isLikelyXML)
    }

    private func showOverlay(fileCount: Int) {
        if overlay == nil {
            let view = XMLDropOverlayView()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
            overlay = view
        }
        overlay?.setFileCount(fileCount)
    }

    private func hideOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }
}

private final class XMLDropOverlayView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Drop to Open")
    private let detailLabel = NSTextField(labelWithString: "XML files open in new tabs")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = XMMetric.radiusCard
        layer?.borderWidth = 2
        layer?.borderColor = XMColor.accent.cgColor
        layer?.backgroundColor = XMColor.bg.withAlphaComponent(0.90).cgColor

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "doc.badge.plus",
                             accessibilityDescription: "Open XML files")
        icon.contentTintColor = XMColor.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.ui(18, .semibold)
        titleLabel.textColor = XMColor.text
        titleLabel.alignment = .center

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = XMFont.uiBody
        detailLabel.textColor = XMColor.text2
        detailLabel.alignment = .center

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -12),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop XML files to open")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFileCount(_ count: Int) {
        detailLabel.stringValue = count == 1
            ? "Open this XML file in a new tab"
            : "Open \(count) XML files in new tabs"
    }
}

// MARK: - Drag forwarding

// AppKit hands a drag to the DEEPEST view under the pointer that is
// registered for the dragged type. NSTextView and WKWebView register
// for file URLs themselves (to insert attachments / navigate), so once
// a document is open the editor, the Preview text and the Learn
// browser swallow every Finder drop before the window's
// XMLFileDropView ever sees it, and, being plain-text / a chat page,
// they then do nothing with it. The symptom (fixed in v0.44.1): with
// a file already open, dragging in a second one had no effect. These
// subclasses hand XML-file drags back to the nearest XMLFileDropView
// and leave every other drag (text, images, non-XML files) to the
// control's own behavior.
extension NSView {
    var xmFileDropTarget: XMLFileDropView? {
        var v: NSView? = superview
        while let cur = v {
            if let drop = cur as? XMLFileDropView { return drop }
            v = cur.superview
        }
        return nil
    }
}

/// Small state machine shared by the forwarding subclasses: decides on
/// entry whether this drag belongs to the drop view, then routes every
/// later callback of the SAME drag the same way.
@MainActor
struct XMLDragForwarder {
    private(set) var active = false

    mutating func entered(_ view: NSView, _ sender: NSDraggingInfo) -> NSDragOperation? {
        guard let drop = view.xmFileDropTarget, drop.accepts(sender) else { active = false; return nil }
        active = true
        return drop.draggingEntered(sender)
    }
    func updated(_ view: NSView, _ sender: NSDraggingInfo) -> NSDragOperation? {
        guard active, let drop = view.xmFileDropTarget else { return nil }
        return drop.draggingUpdated(sender)
    }
    mutating func exited(_ view: NSView, _ sender: NSDraggingInfo?) -> Bool {
        guard active else { return false }
        active = false
        view.xmFileDropTarget?.draggingExited(sender)
        return true
    }
    func prepare(_ view: NSView, _ sender: NSDraggingInfo) -> Bool? {
        guard active, let drop = view.xmFileDropTarget else { return nil }
        return drop.prepareForDragOperation(sender)
    }
    func perform(_ view: NSView, _ sender: NSDraggingInfo) -> Bool? {
        guard active, let drop = view.xmFileDropTarget else { return nil }
        return drop.performDragOperation(sender)
    }
    mutating func conclude(_ view: NSView, _ sender: NSDraggingInfo?) -> Bool {
        guard active else { return false }
        active = false
        view.xmFileDropTarget?.concludeDragOperation(sender)
        return true
    }
}

class XMLDropForwardingTextView: NSTextView {
    private var forwarder = XMLDragForwarder()
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { forwarder.entered(self, s) ?? super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { forwarder.updated(self, s) ?? super.draggingUpdated(s) }
    override func draggingExited(_ s: NSDraggingInfo?) { if !forwarder.exited(self, s) { super.draggingExited(s) } }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { forwarder.prepare(self, s) ?? super.prepareForDragOperation(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { forwarder.perform(self, s) ?? super.performDragOperation(s) }
    override func concludeDragOperation(_ s: NSDraggingInfo?) { if !forwarder.conclude(self, s) { super.concludeDragOperation(s) } }
}

/// The chat page keeps what is dropped on it.
///
/// Everywhere else in the app a dropped XML file opens as a tab. On the
/// Learn page that is the wrong answer: dropping a file, or a piece of
/// XML, onto a chat means "take this", and every chat site accepts both.
/// So this view forwards nothing and lets the page have the drop.
final class XMLDropForwardingWebView: WKWebView {
}
