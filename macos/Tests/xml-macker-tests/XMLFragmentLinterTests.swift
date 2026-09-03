import Foundation
import XCTest
@testable import XMLMacker

final class XMLFragmentLinterTests: XCTestCase {
    // v0.44.4 changed this deliberately: with no sibling evidence either
    // way, the innermost mismatch still offers to rename the CLOSING tag,
    // because that never moves or drops content, so a Fix button can
    // always be offered. The message still names the opening tag's line,
    // so the other reading stays visible.
    func testInnermostTypoStillOffersToRenameTheClosingTag() throws {
        let misspelledClose = try XCTUnwrap(
            lint("<region><period>1</peroid></region>").first)
        let misspelledOpen = try XCTUnwrap(
            lint("<region><peiod>1</period></region>").first)

        XCTAssertEqual(misspelledClose.fix?.title, "Change closing tag to </period>")
        XCTAssertEqual(misspelledOpen.fix?.title, "Change closing tag to </peiod>")
    }

    // The neighbour rule, ported from the Windows edition: when the
    // CLOSING tag's name is the one the siblings already use and the
    // OPENING tag's name is used by nothing else, the opening tag is the
    // typo. Renaming the closing tag there would invent an element name
    // that appears nowhere in the file.
    func testOpeningTagTypoAmongNamedSiblingsRenamesTheOpeningTag() throws {
        let source = "<root><AgSupplySector/><AgSupplySector/>"
            + "<AgSuplySector>x</AgSupplySector></root>"
        let error = try XCTUnwrap(lint(source).first)

        XCTAssertEqual(error.fix?.title, "Change opening tag to <AgSupplySector>")
        XCTAssertEqual(applying(try XCTUnwrap(error.fix), to: source),
                       "<root><AgSupplySector/><AgSupplySector/>"
                       + "<AgSupplySector>x</AgSupplySector></root>")
        XCTAssertTrue(lint(applying(try XCTUnwrap(error.fix), to: source)).isEmpty)
    }

    func testEstablishedSiblingMakesClosingTagRenameSafe() throws {
        let source = "<region><period/><period>1</peroid></region>"
        let error = try XCTUnwrap(lint(source).first)

        XCTAssertEqual(error.fix?.title, "Change closing tag to </period>")
        XCTAssertEqual(applying(try XCTUnwrap(error.fix), to: source),
                       "<region><period/><period>1</period></region>")
    }

    func testMisspelledAncestorOffersInnerCloseBeforeRename() throws {
        var source = "<root><region/><region><period>1</regoin></root>"
        let initial = lint(source)

        XCTAssertEqual(initial.compactMap(\.fix?.title), [
            "Insert </period> before </regoin>",
            "Change closing tag to </region>"
        ])

        source = applying(try XCTUnwrap(initial.first?.fix), to: source)
        XCTAssertEqual(source, "<root><region/><region><period>1</period></regoin></root>")
        source = applying(try XCTUnwrap(lint(source).first?.fix), to: source)
        XCTAssertEqual(source, "<root><region/><region><period>1</period></region></root>")
        XCTAssertTrue(lint(source).isEmpty)
    }

    func testUnrelatedClosingTagIsDiagnosticOnly() throws {
        let source = "<period></technology></period>"
        let error = try XCTUnwrap(lint(source).first)

        XCTAssertTrue(error.message.contains("Stray closing tag"))
        XCTAssertNil(error.fix)
    }

    func testMissingClosingTagDelimiterCanBeInserted() throws {
        let source = "<region></region"
        let fix = try XCTUnwrap(lint(source).first?.fix)

        XCTAssertEqual(applying(fix, to: source), "<region></region>")
        XCTAssertTrue(lint(applying(fix, to: source)).isEmpty)
    }

    func testMissingOpeningTagDelimiterBeforeChildCanBeInserted() throws {
        let source = "<region name=\"USA\"<period/></region>"
        let fix = try XCTUnwrap(lint(source).first?.fix)

        XCTAssertEqual(applying(fix, to: source),
                       "<region name=\"USA\"><period/></region>")
        XCTAssertTrue(lint(applying(fix, to: source)).isEmpty)
    }

    func testMissingAttributeQuoteBeforeTagEndCanBeInserted() throws {
        let source = "<period year=\"2020>\n  <technology/>\n</period>"
        let fix = try XCTUnwrap(lint(source).first?.fix)

        XCTAssertEqual(applying(fix, to: source),
                       "<period year=\"2020\">\n  <technology/>\n</period>")
        XCTAssertTrue(lint(applying(fix, to: source)).isEmpty)
    }

    func testMissingQuoteAndTagEndAtEOFRepairsInTwoLocalSteps() throws {
        var source = "<period year=\"2020"

        source = applying(try XCTUnwrap(lint(source).first?.fix), to: source)
        XCTAssertEqual(source, "<period year=\"2020\">")
        source = applying(try XCTUnwrap(lint(source).first?.fix), to: source)
        XCTAssertEqual(source, "<period year=\"2020\"></period>")
        XCTAssertTrue(lint(source).isEmpty)
    }

    func testMissingEqualsAndOpeningQuoteHaveInsertionFixes() throws {
        var missingEquals = "<period year \"2020\"></period>"
        missingEquals = applying(try XCTUnwrap(lint(missingEquals).first?.fix),
                                 to: missingEquals)
        XCTAssertEqual(missingEquals, "<period year =\"2020\"></period>")
        XCTAssertTrue(lint(missingEquals).isEmpty)

        var missingOpeningQuote = "<period year=2020\"></period>"
        missingOpeningQuote = applying(
            try XCTUnwrap(lint(missingOpeningQuote).first?.fix),
            to: missingOpeningQuote)
        XCTAssertEqual(missingOpeningQuote, "<period year=\"2020\"></period>")
        XCTAssertTrue(lint(missingOpeningQuote).isEmpty)
    }

    func testUnclosedDelimitedMarkupGetsAppendOnlyFixAtDocumentEnd() throws {
        let cases = [
            ("<!-- note", "<!-- note-->"),
            ("<![CDATA[value", "<![CDATA[value]]>"),
            ("<?work value", "<?work value?>")
        ]

        for (source, expected) in cases {
            let fix = try XCTUnwrap(lint(source).first?.fix)
            XCTAssertEqual(applying(fix, to: source), expected)
            XCTAssertTrue(lint(expected).isEmpty)
        }
    }

    func testUnterminatedConstructSuppressesDependentElementCloseFixes() {
        let cases = [
            "<root><!-- note",
            "<root><![CDATA[value",
            "<root><?work value",
            "<root><child value=\""
        ]

        for source in cases {
            XCTAssertEqual(lint(source).compactMap(\.fix).count, 1, source)
        }
    }

    func testTruncatedWindowDoesNotSuggestAppendingMissingSyntax() {
        XCTAssertTrue(lint("<region><period", reachedDocEnd: false).isEmpty)
        XCTAssertTrue(lint("<!-- note", reachedDocEnd: false).isEmpty)
    }

    func testScopedLinterAcceptsSyntacticCustomEntityAndRejectsInvalidNumericEntity() throws {
        XCTAssertTrue(lint("<value>&gcam-entity;</value>").isEmpty)

        let source = "<value>&#xZZ;</value>"
        let error = try XCTUnwrap(lint(source).first)
        XCTAssertEqual(error.fix?.replacement, "&amp;")
        XCTAssertEqual(applying(try XCTUnwrap(error.fix), to: source),
                       "<value>&amp;#xZZ;</value>")
    }

    func testAttributeEntitiesAreCheckedBeforeOfferingQuoteRepair() throws {
        let quoted = "<root a=\"foo&bar\"/>"
        let quotedErrors = lint(quoted)
        XCTAssertTrue(quotedErrors.contains { $0.message.contains("attribute 'a'") })
        XCTAssertEqual(quotedErrors.compactMap(\.fix).first?.replacement, "&amp;")

        var unquoted = "<root a=foo&bar/>"
        let initial = lint(unquoted)
        XCTAssertEqual(initial.compactMap(\.fix).count, 1)
        XCTAssertEqual(initial.compactMap(\.fix).first?.replacement, "&amp;")
        XCTAssertFalse(initial.compactMap(\.fix).contains { $0.title.contains("Wrap") })

        unquoted = applying(try XCTUnwrap(initial.compactMap(\.fix).first), to: unquoted)
        unquoted = applying(try XCTUnwrap(lint(unquoted).compactMap(\.fix).first), to: unquoted)
        XCTAssertEqual(unquoted, "<root a=\"foo&amp;bar\"/>")
        XCTAssertTrue(lint(unquoted).isEmpty)
    }

    func testBareAttributeAndIllegalTagJunkAreDiagnosticOnly() {
        for source in ["<root year 2020/>", "<root @x/>"] {
            let errors = lint(source)
            XCTAssertFalse(errors.isEmpty, source)
            XCTAssertTrue(errors.allSatisfy { $0.fix == nil }, source)
        }
    }

    func testAttributeWhitespaceRulesMatchXML() throws {
        XCTAssertTrue(lint("<root a=\n\"1\"/>").isEmpty)

        let source = "<root a=\"1\"b=\"2\"/>"
        let fix = try XCTUnwrap(lint(source).first?.fix)
        XCTAssertEqual(applying(fix, to: source), "<root a=\"1\" b=\"2\"/>")
        XCTAssertTrue(lint(applying(fix, to: source)).isEmpty)
    }

    func testSelfClosingSlashMustImmediatelyPrecedeTagEnd() throws {
        let spaced = "<root / >"
        let spacedFix = try XCTUnwrap(lint(spaced).first?.fix)
        XCTAssertEqual(applying(spacedFix, to: spaced), "<root />")
        XCTAssertTrue(lint(applying(spacedFix, to: spaced)).isEmpty)

        let missingEnd = "<root /  "
        let missingEndFix = try XCTUnwrap(lint(missingEnd).first?.fix)
        XCTAssertEqual(applying(missingEndFix, to: missingEnd), "<root />")
        XCTAssertTrue(lint(applying(missingEndFix, to: missingEnd)).isEmpty)

        let junk = lint("<root / junk></root>")
        XCTAssertTrue(junk.contains { $0.message.contains("Unexpected '/'") })
        XCTAssertTrue(junk.allSatisfy { $0.fix == nil })
    }

    func testDuplicateAttributeFixRequiresExactRedundancy() throws {
        let redundant = "<period year=\"1975\" year=\"1975\"/>"
        let redundantFix = try XCTUnwrap(lint(redundant).first?.fix)
        XCTAssertTrue(redundantFix.title.contains("exactly redundant"))
        XCTAssertTrue(lint(applying(redundantFix, to: redundant)).isEmpty)

        let conflicting = "<period year=\"1975\" year=\"2000\"/>"
        let conflictError = try XCTUnwrap(lint(conflicting).first)
        XCTAssertTrue(conflictError.message.contains("Duplicate attribute"))
        XCTAssertNil(conflictError.fix)
    }

    func testSelfClosingScopeDoesNotLintTrailingSiblingText() {
        XCTAssertTrue(lint("<period/></period-broken>").isEmpty)
    }

    func testFixRangeUsesAbsoluteDocumentOffset() throws {
        let source = "<region></region"
        let baseOffset = 12_345
        let fix = try XCTUnwrap(lint(source, baseOffset: baseOffset).first?.fix)

        XCTAssertEqual(fix.range.location, baseOffset + (source as NSString).length)
    }

    private func lint(_ source: String,
                      reachedDocEnd: Bool = true,
                      baseOffset: Int = 0) -> [XMLStreamParser.ParseError] {
        XMLFragmentLinter.lint(source,
                               baseLine: 1,
                               reachedDocEnd: reachedDocEnd,
                               baseOffset: baseOffset)
    }

    private func applying(_ fix: XMLStreamParser.FixIt,
                          to source: String,
                          baseOffset: Int = 0) -> String {
        let mutable = NSMutableString(string: source)
        let localRange = NSRange(location: fix.range.location - baseOffset,
                                 length: fix.range.length)
        XCTAssertEqual(mutable.substring(with: localRange), fix.original)
        mutable.replaceCharacters(in: localRange, with: fix.replacement)
        return mutable as String
    }
}
