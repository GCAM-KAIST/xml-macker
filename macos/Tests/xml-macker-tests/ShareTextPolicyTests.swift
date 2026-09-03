import XCTest
@testable import XMLMacker

final class ShareTextPolicyTests: XCTestCase {
    func testTextWithinLimitIsUnchanged() {
        let plan = ShareTextPolicy.excerpt(from: "<speed year=\"2050\">450</speed>", maximumUTF8Bytes: 1_000)

        XCTAssertFalse(plan.isTruncated)
        XCTAssertEqual(plan.text, "<speed year=\"2050\">450</speed>")
        XCTAssertEqual(plan.includedUTF8Bytes, plan.totalUTF8Bytes)
        XCTAssertEqual(plan.omittedUTF8Bytes, 0)
    }

    func testASCIIPrefixReportsExactByteCounts() {
        let plan = ShareTextPolicy.excerpt(from: "abcdefghij", maximumUTF8Bytes: 6)

        XCTAssertEqual(plan.text, "abcdef")
        XCTAssertEqual(plan.totalUTF8Bytes, 10)
        XCTAssertEqual(plan.includedUTF8Bytes, 6)
        XCTAssertEqual(plan.omittedUTF8Bytes, 4)
        XCTAssertTrue(plan.isTruncated)
    }

    func testDoesNotSplitEmojiGraphemeCluster() {
        let family = "👩‍👩‍👧‍👦"
        let source = "ab\(family)cd"
        let limitInsideFamily = 2 + family.utf8.count - 1
        let plan = ShareTextPolicy.excerpt(from: source, maximumUTF8Bytes: limitInsideFamily)

        XCTAssertEqual(plan.text, "ab")
        XCTAssertEqual(plan.includedUTF8Bytes, 2)
        XCTAssertEqual(plan.omittedUTF8Bytes, source.utf8.count - 2)
    }

    func testDoesNotSplitCombiningCharacterSequence() {
        let combined = "e\u{301}"
        let source = "A\(combined)B"
        let plan = ShareTextPolicy.excerpt(from: source, maximumUTF8Bytes: 2)

        XCTAssertEqual(plan.text, "A")
        XCTAssertEqual(plan.includedUTF8Bytes, 1)
    }

    func testZeroLimitProducesEmptyExcerptWithExactOmission() {
        let source = "<?xml version=\"1.0\"?>"
        let plan = ShareTextPolicy.excerpt(from: source, maximumUTF8Bytes: 0)

        XCTAssertEqual(plan.text, "")
        XCTAssertEqual(plan.includedUTF8Bytes, 0)
        XCTAssertEqual(plan.omittedUTF8Bytes, source.utf8.count)
    }
}
