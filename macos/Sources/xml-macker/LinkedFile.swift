import Foundation

// "Open Linked File" (v1.0). GCAM configuration files sit in exe/ and
// point at other XML files by relative path (../input/gcamdata/xml/…).
// When an element's text or an attribute value names a file that really
// exists next to the current document (or one folder up), the tree and
// source context menus offer to open it in a new tab.
enum LinkedFile {
    static func resolve(_ raw: String, relativeTo documentURL: URL?) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 1024, !text.contains("\n") else { return nil }
        let lower = text.lowercased()
        guard text.contains("/") || text.contains("\\") || lower.hasSuffix(".xml") else { return nil }
        let path = text.replacingOccurrences(of: "\\", with: "/")
        var candidates: [URL] = []
        if path.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: path))
        } else if path.hasPrefix("~") {
            candidates.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else if let dir = documentURL?.deletingLastPathComponent() {
            candidates.append(dir.appendingPathComponent(path).standardizedFileURL)
            candidates.append(dir.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL)
        }
        var isDir: ObjCBool = false
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Every text a node carries that could be a path: its own text, then attribute values.
    static func resolve(node: XMLTreeNode, relativeTo documentURL: URL?) -> URL? {
        if let u = resolve(node.textValue, relativeTo: documentURL) { return u }
        for a in node.attributes {
            if let u = resolve(a.value, relativeTo: documentURL) { return u }
        }
        return nil
    }
}
