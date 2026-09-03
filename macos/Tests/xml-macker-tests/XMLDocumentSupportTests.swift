import XCTest
@testable import XMLMacker

final class XMLDocumentSupportTests: XCTestCase {
    func testUTF8BOMIsPreservedAcrossRoundTrip() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("<root>é</root>".utf8)
        let decoded = try XMLTextEncoding.decode(original)
        XCTAssertEqual(decoded.text, "<root>é</root>")
        XCTAssertEqual(decoded.encoding.displayName, "UTF-8 BOM")
        XCTAssertEqual(try decoded.encoding.encode(decoded.text), original)
    }

    func testUTF16LittleEndianIsDecodedAndPreserved() throws {
        let xml = #"<?xml version="1.0" encoding="UTF-16"?><root>서울</root>"#
        let encoding = XMLTextEncoding(kind: .utf16LittleEndian)
        let original = try encoding.encode(xml)
        let decoded = try XMLTextEncoding.decode(original)
        XCTAssertEqual(decoded.text, xml)
        XCTAssertEqual(decoded.encoding, encoding)
        XCTAssertEqual(try decoded.encoding.encode(decoded.text), original)
    }

    func testInvalidUnknownEncodingNeverBecomesAnEmptyDocument() {
        let invalid = Data([0x81, 0x82, 0x83, 0x84])
        XCTAssertThrowsError(try XMLTextEncoding.decode(invalid))
    }

    func testUnsupportedDeclaredEncodingIsRejectedEvenForValidUTF8Bytes() {
        let data = Data(#"<?xml version="1.0" encoding="Shift_JIS"?><root>ASCII</root>"#.utf8)
        XCTAssertThrowsError(try XMLTextEncoding.decode(data)) { error in
            guard case let XMLDocumentError.unsupportedDeclaredEncoding(name) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "Shift_JIS")
        }
    }

    func testOrdinaryEncodingAttributeDoesNotOverrideDocumentEncoding() throws {
        let xml = #"<root encoding="ISO-8859-1">é</root>"#
        let decoded = try XMLTextEncoding.decode(Data(xml.utf8))
        XCTAssertEqual(decoded.text, xml)
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testEncodingTextInsideCommentDoesNotOverrideDocumentEncoding() throws {
        let xml = #"<!-- encoding="ISO-8859-1" --><root>é</root>"#
        let decoded = try XMLTextEncoding.decode(Data(xml.utf8))
        XCTAssertEqual(decoded.text, xml)
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testEditedDeclarationSelectsMatchingSaveEncoding() throws {
        let xml = #"<?xml version="1.0" encoding="ISO-8859-1"?><root>é</root>"#
        let encoding = try XMLTextEncoding.utf8.reconciledForSave(xml)
        XCTAssertEqual(encoding, XMLTextEncoding(kind: .isoLatin1))
        let bytes = try encoding.encode(xml)
        XCTAssertTrue(bytes.contains(0xE9))
        XCTAssertFalse(bytes.contains(0xC3))
    }

    func testReconciledUTF8KeepsExistingBOMPreference() throws {
        let current = XMLTextEncoding(kind: .utf8(bom: true))
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><root/>"#
        XCTAssertEqual(try current.reconciledForSave(xml), current)
    }

    func testLegacyEncodingCannotLoseItsDeclarationOnSave() {
        let current = XMLTextEncoding(kind: .windows1252)
        XCTAssertThrowsError(try current.reconciledForSave("<root>€</root>")) { error in
            guard case XMLDocumentError.missingEncodingDeclaration(_) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
