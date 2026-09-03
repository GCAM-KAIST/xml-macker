import Cocoa

/// File recognition and text encoding support shared by every open/save path.
///
/// XML is commonly UTF-8, but UTF-16 files are valid too.  The previous load
/// path silently turned any non-UTF-8 document into an empty editor, which made
/// a subsequent Save destructive.  This type either decodes losslessly and
/// remembers the original encoding, or returns a clear error.
struct XMLTextEncoding: Equatable {
    enum Kind: Equatable {
        case utf8(bom: Bool)
        case utf16LittleEndian
        case utf16BigEndian
        case utf32LittleEndian
        case utf32BigEndian
        case isoLatin1
        case windows1252
        case ascii
        case macRoman
    }

    let kind: Kind

    static let utf8 = XMLTextEncoding(kind: .utf8(bom: false))

    var displayName: String {
        switch kind {
        case .utf8(let bom):       return bom ? "UTF-8 BOM" : "UTF-8"
        case .utf16LittleEndian:   return "UTF-16 LE"
        case .utf16BigEndian:      return "UTF-16 BE"
        case .utf32LittleEndian:   return "UTF-32 LE"
        case .utf32BigEndian:      return "UTF-32 BE"
        case .isoLatin1:           return "ISO-8859-1"
        case .windows1252:         return "Windows-1252"
        case .ascii:               return "ASCII"
        case .macRoman:            return "Mac Roman"
        }
    }

    private var foundationEncoding: String.Encoding {
        switch kind {
        case .utf8:                return .utf8
        case .utf16LittleEndian:   return .utf16LittleEndian
        case .utf16BigEndian:      return .utf16BigEndian
        case .utf32LittleEndian:   return .utf32LittleEndian
        case .utf32BigEndian:      return .utf32BigEndian
        case .isoLatin1:           return .isoLatin1
        case .windows1252:         return .windowsCP1252
        case .ascii:               return .ascii
        case .macRoman:            return .macOSRoman
        }
    }

    private var byteOrderMark: [UInt8] {
        switch kind {
        case .utf8(let bom):       return bom ? [0xEF, 0xBB, 0xBF] : []
        case .utf16LittleEndian:   return [0xFF, 0xFE]
        case .utf16BigEndian:      return [0xFE, 0xFF]
        case .utf32LittleEndian:   return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian:      return [0x00, 0x00, 0xFE, 0xFF]
        case .isoLatin1, .windows1252, .ascii, .macRoman: return []
        }
    }

    func encode(_ text: String) throws -> Data {
        guard let body = text.data(using: foundationEncoding, allowLossyConversion: false) else {
            throw XMLDocumentError.cannotEncode(displayName)
        }
        guard !byteOrderMark.isEmpty else { return body }
        var data = Data(byteOrderMark)
        data.append(body)
        return data
    }

    /// Return the byte encoding that should be used for a save of `text`.
    ///
    /// The XML declaration is editable source, so it must not be allowed to
    /// drift away from the bytes we write. If the declaration names another
    /// supported encoding, that explicit choice wins. UTF-8 keeps its
    /// existing BOM preference when the declaration still says UTF-8, and a
    /// generic UTF-16/32 declaration keeps the document's current byte order
    /// when possible. Unsupported names fail instead of silently producing a
    /// document whose declaration lies about its bytes.
    func reconciledForSave(_ text: String) throws -> XMLTextEncoding {
        if let declared = Self.declaredEncoding(in: text) {
            guard let encoding = Self.encodingForSave(named: declared,
                                                       preserving: self) else {
                throw XMLDocumentError.unsupportedDeclaredEncoding(declared)
            }
            return encoding
        }

        // ASCII bytes are valid UTF-8 bytes, and Unicode encodings are
        // self-identifying through their BOM. The remaining legacy encodings
        // require an XML declaration; saving them without one would make a
        // conforming reader assume UTF-8 and misdecode the document.
        switch kind {
        case .isoLatin1, .windows1252, .macRoman:
            throw XMLDocumentError.missingEncodingDeclaration(displayName)
        case .utf8, .utf16LittleEndian, .utf16BigEndian,
             .utf32LittleEndian, .utf32BigEndian, .ascii:
            return self
        }
    }

    static func decode(_ data: Data) throws -> (text: String, encoding: XMLTextEncoding) {
        if hasPrefix(data, [0x00, 0x00, 0xFE, 0xFF]) {
            return try decodeBody(data.dropFirst(4), as: .init(kind: .utf32BigEndian))
        }
        if hasPrefix(data, [0xFF, 0xFE, 0x00, 0x00]) {
            return try decodeBody(data.dropFirst(4), as: .init(kind: .utf32LittleEndian))
        }
        if hasPrefix(data, [0xEF, 0xBB, 0xBF]) {
            return try decodeBody(data.dropFirst(3), as: .init(kind: .utf8(bom: true)))
        }
        if hasPrefix(data, [0xFE, 0xFF]) {
            return try decodeBody(data.dropFirst(2), as: .init(kind: .utf16BigEndian))
        }
        if hasPrefix(data, [0xFF, 0xFE]) {
            return try decodeBody(data.dropFirst(2), as: .init(kind: .utf16LittleEndian))
        }

        // XML without a BOM can still advertise an ASCII-compatible
        // encoding in its declaration. Read only the prefix to select it.
        if let declared = declaredEncoding(in: data) {
            guard let encoding = encoding(named: declared, sample: data) else {
                throw XMLDocumentError.unsupportedDeclaredEncoding(declared)
            }
            return try decodeBody(data[...], as: encoding)
        }

        // UTF-16/32 documents without a BOM have recognizable '<' / '?'
        // byte patterns. XML 1.0 explicitly defines these signatures.
        let prefix = Array(data.prefix(4))
        if prefix == [0x00, 0x00, 0x00, 0x3C] {
            return try decodeBody(data[...], as: .init(kind: .utf32BigEndian))
        }
        if prefix == [0x3C, 0x00, 0x00, 0x00] {
            return try decodeBody(data[...], as: .init(kind: .utf32LittleEndian))
        }
        if prefix.starts(with: [0x00, 0x3C]) {
            return try decodeBody(data[...], as: .init(kind: .utf16BigEndian))
        }
        if prefix.starts(with: [0x3C, 0x00]) {
            return try decodeBody(data[...], as: .init(kind: .utf16LittleEndian))
        }

        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        throw XMLDocumentError.unsupportedEncoding
    }

    private static func decodeBody(_ bytes: Data.SubSequence,
                                   as encoding: XMLTextEncoding) throws
        -> (text: String, encoding: XMLTextEncoding) {
        guard let text = String(data: bytes, encoding: encoding.foundationEncoding) else {
            throw XMLDocumentError.cannotDecode(encoding.displayName)
        }
        if let declared = declaredEncoding(in: text),
           encodingForSave(named: declared, preserving: encoding) == nil {
            throw XMLDocumentError.unsupportedDeclaredEncoding(declared)
        }
        return (text, encoding)
    }

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.count >= bytes.count && Array(data.prefix(bytes.count)) == bytes
    }

    private static func declaredEncoding(in data: Data) -> String? {
        let prefix = Data(data.prefix(4_096))
        guard let ascii = String(data: prefix, encoding: .isoLatin1) else { return nil }
        return declaredEncoding(in: ascii)
    }

    /// Extract only an encoding on the real XML declaration. In particular,
    /// do not mistake an `encoding=` attribute or comment near the beginning
    /// of an ordinary UTF-8 document for the document's character encoding.
    private static func declaredEncoding(in text: String) -> String? {
        let prefix = String(text.prefix(4_096))
        let marker = "<?xml"
        guard prefix.hasPrefix(marker) else { return nil }
        let afterMarker = prefix.index(prefix.startIndex, offsetBy: marker.count)
        guard afterMarker < prefix.endIndex,
              isXMLSpace(prefix[afterMarker]),
              let declarationEnd = prefix.range(of: "?>",
                                                range: afterMarker..<prefix.endIndex) else {
            return nil
        }
        let declaration = String(prefix[..<declarationEnd.upperBound])
        let pattern = #"(?i)(?:^|\s)encoding\s*=\s*(['\"])([A-Za-z][A-Za-z0-9._-]*)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: declaration,
                range: NSRange(declaration.startIndex..., in: declaration)),
              let range = Range(match.range(at: 2), in: declaration) else { return nil }
        return String(declaration[range])
    }

    private static func isXMLSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" ||
        character == "\n" || character == "\r"
    }

    private static func encoding(named rawName: String, sample: Data) -> XMLTextEncoding? {
        let name = rawName.lowercased().replacingOccurrences(of: "_", with: "-")
        switch name {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16":
            let p = Array(sample.prefix(2))
            return p == [0x00, 0x3C]
                ? .init(kind: .utf16BigEndian)
                : .init(kind: .utf16LittleEndian)
        case "utf-16le", "utf16le": return .init(kind: .utf16LittleEndian)
        case "utf-16be", "utf16be": return .init(kind: .utf16BigEndian)
        case "utf-32le", "utf32le": return .init(kind: .utf32LittleEndian)
        case "utf-32be", "utf32be": return .init(kind: .utf32BigEndian)
        case "iso-8859-1", "latin1", "latin-1": return .init(kind: .isoLatin1)
        case "windows-1252", "cp1252": return .init(kind: .windows1252)
        case "us-ascii", "ascii": return .init(kind: .ascii)
        case "macintosh", "macroman", "x-mac-roman": return .init(kind: .macRoman)
        default: return nil
        }
    }

    private static func encodingForSave(named rawName: String,
                                        preserving current: XMLTextEncoding)
        -> XMLTextEncoding? {
        let name = rawName.lowercased().replacingOccurrences(of: "_", with: "-")
        switch name {
        case "utf-8", "utf8":
            if case .utf8 = current.kind { return current }
            return .utf8
        case "utf-16", "utf16":
            switch current.kind {
            case .utf16LittleEndian, .utf16BigEndian: return current
            default: return .init(kind: .utf16LittleEndian)
            }
        case "utf-16le", "utf16le": return .init(kind: .utf16LittleEndian)
        case "utf-16be", "utf16be": return .init(kind: .utf16BigEndian)
        case "utf-32", "utf32":
            switch current.kind {
            case .utf32LittleEndian, .utf32BigEndian: return current
            default: return .init(kind: .utf32LittleEndian)
            }
        case "utf-32le", "utf32le": return .init(kind: .utf32LittleEndian)
        case "utf-32be", "utf32be": return .init(kind: .utf32BigEndian)
        case "iso-8859-1", "latin1", "latin-1": return .init(kind: .isoLatin1)
        case "windows-1252", "cp1252": return .init(kind: .windows1252)
        case "us-ascii", "ascii": return .init(kind: .ascii)
        case "macintosh", "macroman", "x-mac-roman": return .init(kind: .macRoman)
        default: return nil
        }
    }
}

enum XMLDocumentError: LocalizedError {
    case unsupportedEncoding
    case unsupportedDeclaredEncoding(String)
    case cannotDecode(String)
    case cannotEncode(String)
    case missingEncodingDeclaration(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "The file uses an unsupported text encoding. xml-macker supports UTF-8, UTF-16, UTF-32, ASCII, ISO-8859-1, Windows-1252, and Mac Roman."
        case .unsupportedDeclaredEncoding(let name):
            return "The XML declaration names unsupported encoding '\(name)'. xml-macker did not guess or change the document's bytes."
        case .cannotDecode(let name):
            return "The file declares \(name), but its bytes are not valid \(name) text."
        case .cannotEncode(let name):
            return "Some edited characters cannot be saved using the document's original \(name) encoding."
        case .missingEncodingDeclaration(let name):
            return "A \(name) XML document must keep an encoding declaration. Restore the declaration or change it to a supported encoding before saving."
        }
    }
}

enum XMLDocumentSupport {
    static let knownExtensions: Set<String> = [
        "xml", "xsd", "xsl", "xslt", "svg", "plist", "gpx", "kml",
        "rss", "atom", "wsdl", "xhtml", "opf", "ncx", "mathml"
    ]

    static func canonicalFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { raw in
            guard raw.isFileURL else { return nil }
            let url = raw.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    /// Known XML-family extensions are accepted even when the document is
    /// malformed (the editor exists to repair those). Unknown extensions are
    /// accepted only when their first bytes look like XML.
    static func isLikelyXML(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4096) else { return false }
        let bytes = Array(prefix.prefix(8))
        // `.plist` can also be Apple's binary property-list format. It is not
        // XML and decoding it as legacy text would expose garbage in the
        // editor, so reject its stable magic signature even though the suffix
        // is otherwise in the XML family.
        if bytes == Array("bplist00".utf8) { return false }
        if knownExtensions.contains(url.pathExtension.lowercased()) { return true }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) ||
           bytes.starts(with: [0xFE, 0xFF]) ||
           bytes.starts(with: [0xFF, 0xFE]) ||
           bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) ||
           bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return true }
        if bytes.starts(with: [0x00, 0x3C]) || bytes.starts(with: [0x3C, 0x00]) ||
           bytes.starts(with: [0x00, 0x00, 0x00, 0x3C]) ||
           bytes.starts(with: [0x3C, 0x00, 0x00, 0x00]) { return true }
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }
}
