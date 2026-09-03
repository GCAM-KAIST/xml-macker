import Foundation
import XCTest
@testable import XMLMacker

final class XMLStreamParserTests: XCTestCase {
    func testEntitySeparatedCharacterCallbacksKeepSpaces() throws {
        let root = try parseRoot("<root>Hello &amp; world</root>")
        XCTAssertEqual(root.textValue, "Hello & world")
    }

    func testCDATAIsIncludedAsLiteralText() throws {
        let root = try parseRoot("<root>before <![CDATA[<tag>&value]]> after</root>")
        XCTAssertEqual(root.textValue, "before <tag>&value after")
    }

    func testMultilineOpeningTagsUseLineContainingLessThanSign() throws {
        let root = try parseRoot("""
        <root
          label="top">
          <child
            label="nested">value</child>
        </root>
        """)

        XCTAssertEqual(root.startLine, 1)
        let child = try XCTUnwrap(root.children.first)
        XCTAssertEqual(child.startLine, 3)
        XCTAssertEqual(child.textValue, "value")
    }

    func testMarkupLikeTextInsideCDATADoesNotDesynchroniseStartLines() throws {
        let root = try parseRoot("""
        <root>
          <![CDATA[<not-an-element
            fake="true">]]>
          <real
            value="yes" />
        </root>
        """)

        let real = try XCTUnwrap(root.children.first)
        XCTAssertEqual(real.name, "real")
        XCTAssertEqual(real.startLine, 4)
    }

    func testUTF16FileTracksMultilineOpeningTag() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<root\n  value=\"yes\">ok</root>"
        let data = try XCTUnwrap(xml.data(using: .utf16))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xml")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = XMLStreamParser().parseFile(at: url)
        XCTAssertTrue(result.errors.isEmpty, "Unexpected parse errors: \(result.errors.map(\.message))")
        let root = try XCTUnwrap(result.root.children.first)
        XCTAssertEqual(root.startLine, 2)
        XCTAssertEqual(root.textValue, "ok")
    }

    func testEntityGeneratedElementDoesNotConsumeNextRealTagLocation() throws {
        let root = try parseRoot("""
        <!DOCTYPE root [
          <!ELEMENT root ANY>
          <!ENTITY generated "<from-entity/>">
        ]>
        <root>
          &generated;
          <real
            value="yes" />
        </root>
        """)

        XCTAssertEqual(root.startLine, 5)
        XCTAssertEqual(root.children.map(\.name), ["from-entity", "real"])
        XCTAssertEqual(root.children[0].startLine, 6) // entity reference
        XCTAssertEqual(root.children[1].startLine, 7) // physical '<real'
    }

    func testErrorsOnlyValidationReportsMalformedXML() {
        XCTAssertTrue(XMLStreamParser.validateText("<root><child/></root>").isEmpty)
        let errors = XMLStreamParser.validateText("<root><child></root>")
        XCTAssertFalse(errors.isEmpty)
    }

    func testProgressSnapshotReachesFinalLine() {
        let parser = XMLStreamParser()
        let xml = "<root>\n" + Array(repeating: "  <child/>\n", count: 600).joined() + "</root>"
        let result = parser.parseText(xml)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertGreaterThanOrEqual(parser.currentLineNumber, 601)
    }

    private func parseRoot(_ xml: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> XMLTreeNode {
        let result = XMLStreamParser().parseText(xml)
        XCTAssertTrue(result.errors.isEmpty,
                      "Unexpected parse errors: \(result.errors.map(\.message))",
                      file: file, line: line)
        return try XCTUnwrap(result.root.children.first, file: file, line: line)
    }
}
