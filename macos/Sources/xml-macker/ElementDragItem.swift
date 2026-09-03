import Cocoa

/// One element on its way out of the tree.
///
/// It offers itself two ways, and the receiver picks: as text, which is
/// what the source editor, a chat box and most apps want, and as a file,
/// which is what a page that takes attachments wants. The file is only
/// written if somebody actually asks for it, so dragging a large element
/// around costs nothing until it is dropped somewhere that wants a file.
///
/// Text is offered only up to `textLimit`. A chat page given a few
/// million characters at once stops responding, which is what happens
/// when a whole file goes on the clipboard, so past that size the only
/// thing on offer is the file.
final class ElementDragItem: NSObject, NSPasteboardWriting {
    static let textLimit = 1_000_000

    private let name: String
    private let xml: String
    private var writtenURL: URL?

    init(name: String, xml: String) {
        self.name = name
        self.xml = xml
    }

    var fitsAsText: Bool { xml.utf8.count <= Self.textLimit }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        fitsAsText ? [.string, .fileURL] : [.fileURL]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        // Both are produced on demand: the file is only written when a
        // receiver asks for a file.
        [.promised]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string:
            return fitsAsText ? xml : nil
        case .fileURL:
            return fileURL()?.absoluteString
        default:
            return nil
        }
    }

    /// Writes the element into the app's own temporary folder, once.
    private func fileURL() -> URL? {
        if let writtenURL { return writtenURL }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("xml-macker-drags", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeName())
        let head = xml.hasPrefix("<?xml") ? "" : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        guard (try? (head + xml).write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        writtenURL = url
        return url
    }

    private func safeName() -> String {
        let cleaned = name.map { ch -> Character in
            "/\\:?%*|\"<>".contains(ch) || ch.isNewline ? "_" : ch
        }
        var base = String(cleaned).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "element" }
        if base.count > 60 { base = String(base.prefix(60)) }
        return base.hasSuffix(".xml") ? base : base + ".xml"
    }
}
