import XCTest
@testable import XMLMacker

// The chart rule (v0.43.1, restored in v0.44.3):
// a comparison lives INSIDE the selected element's own family, 
// values across the years under one parent, or the same value at one
// year across sibling elements, never across a different parent.
final class TrendComputerTests: XCTestCase {

    private func firstElement(named name: String, below node: XMLTreeNode) -> XMLTreeNode? {
        if node.kind == .element && node.name == name { return node }
        for c in node.children {
            if let found = firstElement(named: name, below: c) { return found }
        }
        return nil
    }

    func testTimeSeriesStaysInsideTheSelectedTechnology() throws {
        let root = XMLStreamParser().parseText("""
        <scenario><world><region name="USA"><supplysector name="trn_pass">
          <tranSubsector name="road">
            <stub-technology name="A">
              <period year="1990"><share-weight>1</share-weight></period>
              <period year="1975"><share-weight>0.5</share-weight></period>
              <period year="2005"><share-weight>2</share-weight></period>
            </stub-technology>
            <stub-technology name="B">
              <period year="1975"><share-weight>9</share-weight></period>
              <period year="1990"><share-weight>9</share-weight></period>
            </stub-technology>
          </tranSubsector>
        </supplysector></region></world></scenario>
        """).root
        let techA = try XCTUnwrap(firstElement(named: "stub-technology", below: root))
        let period = try XCTUnwrap(firstElement(named: "period", below: techA))
        let series = try XCTUnwrap(TrendComputer.compute(for: period, preferring: "share-weight"))
        XCTAssertEqual(series.kind, .line)
        XCTAssertEqual(series.xLabels, ["1975", "1990", "2005"])   // sorted by year
        XCTAssertEqual(series.values, [0.5, 1, 2])                 // technology A only, never B
        XCTAssertEqual(series.xPositions, [1975, 1990, 2005])      // real year spacing
    }

    func testFixedYearComparisonUsesSiblingsUnderTheSameParentOnly() throws {
        let root = XMLStreamParser().parseText("""
        <scenario><world><region name="USA">
          <supplysector name="trn_pass">
            <tranSubsector name="road"><logit-exponent year="1975">-3</logit-exponent></tranSubsector>
            <tranSubsector name="rail"><logit-exponent year="1975">-2</logit-exponent></tranSubsector>
            <tranSubsector name="air"><logit-exponent year="1975">-1</logit-exponent></tranSubsector>
          </supplysector>
          <supplysector name="trn_freight">
            <tranSubsector name="truck"><logit-exponent year="1975">-9</logit-exponent></tranSubsector>
          </supplysector>
        </region></world></scenario>
        """).root
        let road = try XCTUnwrap(firstElement(named: "tranSubsector", below: root))
        let series = try XCTUnwrap(TrendComputer.compute(for: road))
        XCTAssertEqual(series.kind, .bar)
        XCTAssertEqual(series.xLabels, ["road", "rail", "air"])
        XCTAssertEqual(series.values, [-3, -2, -1])                // "truck" lives under another parent
        XCTAssertTrue(series.title.contains("(year 1975)"))
        XCTAssertNil(series.xPositions)
    }

    func testUnrelatedFlagsWithoutNumbersGiveNoChart() {
        let root = XMLStreamParser().parseText("""
        <config><Value name="a">true</Value><Value name="b">false</Value></config>
        """).root
        let config = firstElement(named: "config", below: root)!
        XCTAssertTrue(TrendComputer.availableTargets(for: config).isEmpty)
        XCTAssertNil(TrendComputer.compute(for: config))
    }
}
