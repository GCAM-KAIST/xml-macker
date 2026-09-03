// SelfCheck.swift
//
// A self-test that lives inside the shipped app and runs against the
// exact code that ships:
//
//     /Applications/xml-macker.app/Contents/MacOS/xml-macker --self-check
//
// Why it is here and not in Tests/: the XCTest suite in Tests/ cannot run
// on a Mac that has only the Command Line Tools, because XCTest ships
// with Xcode. This harness needs nothing but the app itself, so it can be
// run on any machine, before every release, and by anyone.
//
// It covers the pure logic: parsing, the linter, the level index behind
// the minimap lane, CSV export, the share excerpt, and the invariants of
// the theme palettes. It cannot click buttons; tools/smoke-test.applescript
// does that part.

import Cocoa

enum SelfCheck {

    private static var failures: [String] = []
    private static var passes = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passes += 1
            print("  ok   \(name)")
        } else {
            failures.append(name)
            print("  FAIL \(name)")
        }
    }

    private static func equal<T: Equatable>(_ name: String, _ a: T, _ b: T) {
        if a == b {
            passes += 1
            print("  ok   \(name)")
        } else {
            failures.append("\(name) (got \(a), wanted \(b))")
            print("  FAIL \(name): got \(a), wanted \(b)")
        }
    }

    private static func section(_ title: String) { print("\n\(title)") }

    /// Runs every check and returns a process exit status.
    static func run() -> Int32 {
        let started = Date()
        print("xml-macker self-check")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("version \(version) build \(build)")

        checkParser()
        checkLinter()
        checkLevelIndex()
        checkStructuralDiff()
        checkBalance()
        checkHighlights()
        checkCSV()
        checkShareExcerpt()
        checkThemes()
        checkQuickChart()
        checkElementDrag()

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print("\n\(passes) passed, \(failures.count) failed, \(elapsed)s")
        for f in failures { print("  - \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    /// `--chart-check file.xml <element> [key] [variable]` prints what the
    /// quick chart would draw for that element in a real file.
    static func chartCheck(_ path: String, _ element: String,
                           _ key: String?, _ variable: String?) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("could not read \(path)")
            return 1
        }
        let root = parse(text).root
        let key = (key?.isEmpty ?? true) ? nil : key      // "" means "any"
        guard let node = find(root, element, key: key) else {
            print("no <\(element)>\(key.map { " with \($0)" } ?? "") in \(path)")
            return 1
        }
        var chain: [String] = []
        var up: XMLTreeNode? = node
        while let n = up { chain.insert(n.displayLabel, at: 0); up = n.parent }
        print("selected: \(chain.joined(separator: " > "))")
        let variable = (variable?.isEmpty ?? true) ? nil : variable
        guard let series = TrendComputer.compute(for: node, preferring: variable) else {
            print("no chart")
            return 0
        }
        print("title:  \(series.title)")
        print("kind:   \(series.kind)")
        print("labels: \(series.xLabels.prefix(8).joined(separator: ", "))\(series.xLabels.count > 8 ? ", … (\(series.xLabels.count) in all)" : "")")
        return 0
    }

    // MARK: dragging an element out of the tree

    private static func checkElementDrag() {
        section("Element drag")
        let small = ElementDragItem(name: "region USA", xml: "<region name=\"USA\"><a>1</a></region>")
        let pb = NSPasteboard.general
        check("a small element goes as text", small.writableTypes(for: pb).contains(.string))
        check("and as a file, for anything that wants one",
              small.writableTypes(for: pb).contains(.fileURL))
        equal("the text is the element itself",
              small.pasteboardPropertyList(forType: .string) as? String ?? "",
              "<region name=\"USA\"><a>1</a></region>")

        // Past the limit only the file is offered: a chat page given a
        // million characters at once stops responding.
        let big = ElementDragItem(name: "world", xml: String(repeating: "<a>1</a>", count: 200_000))
        check("a huge element is not offered as text",
              !big.writableTypes(for: pb).contains(.string))
        check("and its text really is withheld",
              big.pasteboardPropertyList(forType: .string) == nil)
        check("but the file is still there", big.writableTypes(for: pb).contains(.fileURL))

        // The file it writes is real, named after the element, and holds
        // the element with a declaration in front.
        let named = ElementDragItem(name: "supplysector/iron and steel",
                                    xml: "<supplysector name=\"iron and steel\"/>")
        guard let plist = named.pasteboardPropertyList(forType: .fileURL) as? String,
              let url = URL(string: plist) else {
            check("the drag writes a file", false)
            return
        }
        check("the file is named after the element, without the slash",
              url.lastPathComponent == "supplysector_iron and steel.xml")
        let written = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("it starts with an XML declaration", written.hasPrefix("<?xml"))
        check("and contains the element", written.contains("iron and steel"))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: the quick chart

    /// A miniature GCAM file with the shape that caused the complaint:
    /// three regions, each with one supplysector holding three subsectors,
    /// and a logit-exponent at every level.
    private static let chartSample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scenario>
      <world>
        <region name="USA">
          <supplysector name="iron and steel">
            <relative-cost-logit>
              <logit-exponent fillout="1" year="1975">-3</logit-exponent>
            </relative-cost-logit>
            <subsector name="BLASTFUR">
              <relative-cost-logit>
                <logit-exponent fillout="1" year="1975">-6</logit-exponent>
              </relative-cost-logit>
              <stub-technology name="BF">
                <period year="1975"><share-weight>0.4</share-weight></period>
                <period year="1990"><share-weight>0.5</share-weight></period>
                <period year="2005"><share-weight>0.6</share-weight></period>
              </stub-technology>
            </subsector>
            <subsector name="EAF with DRI">
              <relative-cost-logit>
                <logit-exponent fillout="1" year="1975">-4</logit-exponent>
              </relative-cost-logit>
            </subsector>
            <subsector name="EAF with scrap">
              <relative-cost-logit>
                <logit-exponent fillout="1" year="1975">-5</logit-exponent>
              </relative-cost-logit>
            </subsector>
          </supplysector>
        </region>
        <region name="Africa_Eastern">
          <supplysector name="iron and steel">
            <relative-cost-logit>
              <logit-exponent fillout="1" year="1975">-3</logit-exponent>
            </relative-cost-logit>
          </supplysector>
        </region>
        <region name="Brazil">
          <supplysector name="iron and steel">
            <relative-cost-logit>
              <logit-exponent fillout="1" year="1975">-3</logit-exponent>
            </relative-cost-logit>
          </supplysector>
        </region>
      </world>
    </scenario>
    """

    /// Depth-first search for the first element with this name, and this
    /// key attribute value when one is given.
    private static func find(_ root: XMLTreeNode, _ name: String, key: String? = nil) -> XMLTreeNode? {
        if root.name == name {
            if let key {
                if root.attributes.contains(where: { $0.value == key }) { return root }
            } else {
                return root
            }
        }
        for c in root.children where c.kind == .element {
            if let hit = find(c, name, key: key) { return hit }
        }
        return nil
    }

    private static func checkQuickChart() {
        section("Quick chart")
        let root = parse(chartSample).root
        guard let world = find(root, "world"),
              let usa = find(root, "region", key: "USA"),
              let sector = find(usa, "supplysector"),
              let container = find(sector, "relative-cost-logit"),
              let leaf = find(container, "logit-exponent"),
              let blast = find(usa, "subsector", key: "BLASTFUR"),
              let tech = find(blast, "stub-technology") else {
            check("the chart sample parses into the expected shape", false)
            return
        }

        // The pane always pins the variable it is showing, so the checks
        // call the engine the way the app does.
        let logit = "logit-exponent"

        // The complaint: a selection inside one region must not be
        // charted across every region.
        let inContainer = TrendComputer.compute(for: container, preferring: logit)
        equal("a container inside a region charts that region's own members",
              inContainer?.xLabels.count ?? -1, 3)
        check("and it names the subsectors, not the regions",
              inContainer?.xLabels.contains("BLASTFUR") == true)
        let onLeaf = TrendComputer.compute(for: leaf, preferring: logit)
        check("the value itself stays inside its region too",
              onLeaf?.xLabels.contains("Brazil") != true)
        equal("and charts the subsectors beside it", onLeaf?.xLabels.count ?? -1, 3)

        // What used to work must go on working.
        let onSector = TrendComputer.compute(for: sector, preferring: logit)
        equal("a supplysector charts its subsectors", onSector?.xLabels.count ?? -1, 3)
        let onRegion = TrendComputer.compute(for: usa, preferring: logit)
        equal("a region charts its subsectors", onRegion?.xLabels.count ?? -1, 3)
        let onWorld = TrendComputer.compute(for: world, preferring: logit)
        equal("world is still how you compare regions", onWorld?.xLabels.count ?? -1, 3)
        check("and those are the regions", onWorld?.xLabels.contains("Brazil") == true)
        let onTech = TrendComputer.compute(for: tech, preferring: "share-weight")
        equal("a technology charts its periods over time", onTech?.xLabels.count ?? -1, 3)
        check("as a line", onTech?.kind == .line)
    }

    // MARK: parser

    private static func parse(_ text: String) -> XMLStreamParser.Result {
        XMLStreamParser().parseText(text)
    }

    private static func checkParser() {
        section("Parser")
        let simple = parse("<root><a/><b>x</b></root>")
        equal("root name", simple.root.children.first?.name ?? "?", "root")
        equal("no errors on clean XML", simple.errors.count, 0)

        let multiline = parse("<root\n  label=\"top\">\n  <child>value</child>\n</root>")
        let child = multiline.root.children.first?.children.first
        equal("start line of a multi-line opening tag", child?.startLine ?? -1, 3)
        equal("text content", child?.textValue ?? "?", "value")

        let entity = parse("<root>Hello &amp; world</root>")
        equal("entities decode", entity.root.children.first?.textValue ?? "?", "Hello & world")

        let cdata = parse("<root>before <![CDATA[<tag>&value]]> after</root>")
        equal("CDATA is literal text",
              cdata.root.children.first?.textValue ?? "?", "before <tag>&value after")

        let broken = parse("<root><a></b></root>")
        check("malformed XML reports an error", broken.errors.isEmpty == false)
    }

    // MARK: linter

    private static func lint(_ s: String) -> [XMLStreamParser.ParseError] {
        XMLFragmentLinter.lint(s, baseLine: 1, reachedDocEnd: true)
    }

    private static func checkLinter() {
        section("Linter")
        check("a clean fragment has no errors",
              lint("<region name=\"USA\"><period>1</period></region>").isEmpty)
        check("a mismatched pair is reported",
              lint("<region><period>1</peroid></region>").isEmpty == false)
        // Neighbour rule: whichever name opens no other element is the
        // typo. Here "period" opens one and "peroid" opens none, so the
        // CLOSING tag is the mistake.
        equal("a closing-tag typo is renamed",
              lint("<region><period>1</peroid></region>").first?.fix?.title ?? "no fix",
              "Change closing tag to </period>")
        // The mirror case: the OPENING tag is the odd one out because
        // twenty siblings are named AgSupplySector.
        let openingTypo = lint("<root><AgSupplySector/><AgSupplySector/>"
                               + "<AgSuplySector>x</AgSupplySector></root>")
        equal("an opening-tag typo among named siblings is renamed",
              openingTypo.first?.fix?.title ?? "no fix",
              "Change opening tag to <AgSupplySector>")
        let withEvidence = lint("<region><period/><period>1</peroid></region>")
        equal("a sibling makes the closing-tag rename safe",
              withEvidence.first?.fix?.title ?? "none", "Change closing tag to </period>")
        check("an unfinished trailing tag mid-window is not an error",
              XMLFragmentLinter.lint("<region><period>1</period><per",
                                     baseLine: 1, reachedDocEnd: false).isEmpty)
    }

    // MARK: level index (the minimap's magnet lane)

    private static func checkLevelIndex() {
        section("Level index")
        // Two regions, each with two supplysectors and one other tag, so
        // "same depth" and "same tag" can be told apart.
        var xml = "<scenario><world>"
        for r in 0..<2 {
            xml += "<region name=\"R\(r)\">"
            xml += "<supplysector name=\"a\"/><supplysector name=\"b\"/><energy-final-demand name=\"e\"/>"
            xml += "</region>"
        }
        xml += "</world></scenario>"
        // One element per line so start lines are distinguishable.
        let spaced = xml.replacingOccurrences(of: "><", with: ">\n<")
        let root = parse(spaced).root
        let index = LevelIndex(root: root)

        guard let scenario = root.children.first(where: { $0.kind == .element }),
              let world = scenario.children.first(where: { $0.kind == .element }),
              let region = world.children.first(where: { $0.kind == .element }),
              let sector = region.children.first(where: { $0.name == "supplysector" }) else {
            failures.append("level index: could not build the sample tree")
            print("  FAIL level index: could not build the sample tree")
            return
        }

        equal("root element is depth 0", LevelIndex.level(of: scenario)?.depth ?? -1, 0)
        equal("region is depth 2", LevelIndex.level(of: region)?.depth ?? -1, 2)
        equal("supplysector is depth 3", LevelIndex.level(of: sector)?.depth ?? -1, 3)

        let regions = index.magnets(for: region)
        equal("a region sees both regions", regions.lines.count, 2)

        // The whole point of the rebuild: from inside ONE region the lane
        // must still reach the supplysectors of the other region.
        let sectors = index.magnets(for: sector)
        equal("a supplysector sees all four supplysectors in the file", sectors.lines.count, 4)
        equal("and stays on its own tag", sectors.level?.name ?? "?", "supplysector")
        check("magnets are sorted ascending", sectors.lines == sectors.lines.sorted())
        check("a sibling tag at the same depth is a different level",
              index.magnets(for: region.children.first(where: { $0.name == "energy-final-demand" })!)
                   .lines.count == 2)

        // Alone at its level: the lane must not go empty, it steps down.
        check("the document root does not leave the lane empty",
              index.magnets(for: scenario).lines.count >= 2)
    }

    // MARK: structural diff

    private static func lines(_ s: String) -> [String] {
        var out = s.components(separatedBy: "\n")
        if out.last == "" { out.removeLast() }
        return out
    }

    private static func checkStructuralDiff() {
        section("Element-aware diff")

        // The case a line algorithm cannot do: the same two regions, in
        // the opposite order, with one value changed inside the second.
        let a = """
        <world>
        <region name="USA">
        <sector>1</sector>
        </region>
        <region name="EU">
        <sector>2</sector>
        </region>
        </world>
        """
        let b = """
        <world>
        <region name="EU">
        <sector>2</sector>
        </region>
        <region name="USA">
        <sector>9</sector>
        </region>
        </world>
        """
        let la = lines(a), lb = lines(b)
        let ra = parse(a).root, rb = parse(b).root
        guard let aligned = StructuralDiff.align(leftRoot: ra, rightRoot: rb,
                                                 leftLines: la, rightLines: lb) else {
            failures.append("structural diff: reordered regions did not align")
            print("  FAIL structural diff: reordered regions did not align")
            return
        }
        // Line by line this is a wall; by element it is the one changed
        // value plus the two moved blocks.
        let byLine = DiffEngine.diff(left: la, right: lb)
        let hunks = aligned.filter(\.isHunk)
        check("reordered regions align by element", true)
        check("element-aware finds fewer differences than line-by-line (\(hunks.count) vs \(byLine.count))",
              hunks.count <= byLine.count)
        let changed = hunks.filter { $0.leftCount > 0 && $0.rightCount > 0 }
        check("the changed value is reported as a change", changed.isEmpty == false)

        // Identical files: nothing at all.
        let same = StructuralDiff.align(leftRoot: parse(a).root, rightRoot: parse(a).root,
                                        leftLines: la, rightLines: la)
        equal("identical files produce no differences", same?.filter(\.isHunk).count ?? -1, 0)

        // An element present on one side only becomes ONE block, not one
        // difference per line.
        let c = """
        <world>
        <region name="USA">
        <sector>1</sector>
        </region>
        </world>
        """
        let lc = lines(c)
        let missing = StructuralDiff.align(leftRoot: parse(a).root, rightRoot: parse(c).root,
                                           leftLines: la, rightLines: lc)?.filter(\.isHunk)
        equal("a whole missing element is one difference", missing?.count ?? -1, 1)
        equal("and it carries all of its lines", missing?.first?.leftCount ?? -1, 3)
        equal("with nothing on the other side", missing?.first?.rightCount ?? -1, 0)

        // Every line of both files must appear exactly once, or the two
        // sides would not line up on screen.
        var lSeen = 0, rSeen = 0
        for s in aligned { lSeen += s.leftCount; rSeen += s.rightCount }
        equal("every left line is shown once", lSeen, la.count)
        equal("every right line is shown once", rSeen, lb.count)
    }

    private static func checkBalance() {
        section("Copy balance check")
        // The shape that broke: one line out of a bigger element.
        check("a lone closing tag is not balanced",
              DiffWindowController.isBalancedFragment("</absolute-cost-logit>\n") == false)
        check("a lone opening tag is not balanced",
              DiffWindowController.isBalancedFragment("<relative-cost-logit>\n") == false)
        check("a whole element is balanced",
              DiffWindowController.isBalancedFragment("<a><b>1</b></a>\n"))
        check("a self-closing tag is balanced",
              DiffWindowController.isBalancedFragment("<keyword final-energy=\"transportation\"/>\n"))
        check("plain text is balanced", DiffWindowController.isBalancedFragment("just words\n"))
        check("empty is balanced", DiffWindowController.isBalancedFragment(""))
        check("a '>' inside an attribute value does not end the tag",
              DiffWindowController.isBalancedFragment("<a name=\"x>y\"></a>\n"))
        check("a comment is skipped",
              DiffWindowController.isBalancedFragment("<!-- </a> -->\n"))
        check("CDATA is skipped",
              DiffWindowController.isBalancedFragment("<a><![CDATA[</a>]]></a>\n"))
        check("a declaration is skipped",
              DiffWindowController.isBalancedFragment("<?xml version=\"1.0\"?>\n<a></a>\n"))
        check("crossed tags are not balanced",
              DiffWindowController.isBalancedFragment("<a><b></a></b>\n") == false)
        check("an unfinished tag is left to the parser",
              DiffWindowController.isBalancedFragment("<a><b"))
    }

    private static func checkHighlights() {
        section("Marker strokes")
        let h = TextHighlights()
        h.paint(start: 10, length: 5, color: .yellow)
        equal("painting adds a stroke", h.count, 1)
        check("the stroke covers what was painted", h.isCovered(start: 10, length: 5, color: .yellow))
        check("and not a neighbouring colour", h.isCovered(start: 10, length: 5, color: .red) == false)

        h.paint(start: 12, length: 2, color: .red)
        equal("painting inside splits the old stroke", h.count, 3)
        check("the middle is the new colour", h.isCovered(start: 12, length: 2, color: .red))

        h.paint(start: 10, length: 5, color: .none)
        equal("the eraser clears the whole span", h.count, 0)

        h.paint(start: 0, length: 4, color: .green)
        h.paint(start: 4, length: 4, color: .green)
        equal("touching strokes of one colour merge", h.count, 1)
        equal("and cover both", h.ranges.first?.length ?? 0, 8)

        // Following edits.
        h.clear()
        h.paint(start: 20, length: 5, color: .blue)
        h.shiftForEdit(start: 0, removed: 0, inserted: 3)
        equal("a stroke after an insert moves", h.ranges.first?.start ?? -1, 23)
        h.shiftForEdit(start: 24, removed: 0, inserted: 2)
        equal("typing inside a stroke joins it", h.ranges.first?.length ?? 0, 7)
        h.shiftForEdit(start: 23, removed: 7, inserted: 0)
        equal("removing a stroke's text removes the stroke", h.count, 0)

        // Navigation wraps.
        h.clear()
        h.paint(start: 100, length: 2, color: .red)
        h.paint(start: 200, length: 2, color: .red)
        equal("next after the last wraps to the first", h.next(after: 500)?.start ?? -1, 100)
        equal("previous before the first wraps to the last", h.previous(before: 0)?.start ?? -1, 200)
        equal("ordinal counts from one", h.ordinal(of: HighlightRange(start: 200, length: 2, color: .red)), 2)
        equal("intersecting finds the visible ones", h.intersecting(from: 150, to: 250).count, 1)
    }

    /// `--diff-check left.xml right.xml` compares two real files with both
    /// engines and prints the numbers, so a change to the aligner can be
    /// judged on the files it is meant for rather than on toy input.
    static func diffCheck(_ leftPath: String, _ rightPath: String) -> Int32 {
        func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
        guard let lt = read(leftPath) else { print("cannot read \(leftPath)"); return 2 }
        guard let rt = read(rightPath) else { print("cannot read \(rightPath)"); return 2 }
        let la = lines(lt), lb = lines(rt)
        print("left  \(leftPath)  \(la.count) lines")
        print("right \(rightPath)  \(lb.count) lines")

        var t = Date()
        let byLine = DiffEngine.diff(left: la, right: lb)
        print(String(format: "line by line: %d differences in %.2fs", byLine.count, Date().timeIntervalSince(t)))

        t = Date()
        let lp = XMLStreamParser().parseText(lt)
        let rp = XMLStreamParser().parseText(rt)
        let parsed = Date().timeIntervalSince(t)
        if let e = lp.errors.first { print("left has an XML error at line \(e.line): \(e.message)") }
        if let e = rp.errors.first { print("right has an XML error at line \(e.line): \(e.message)") }

        t = Date()
        let aligned = StructuralDiff.align(leftRoot: lp.root, rightRoot: rp.root,
                                           leftLines: la, rightLines: lb)
        let alignTime = Date().timeIntervalSince(t)
        if let aligned {
            let hunks = aligned.filter(\.isHunk)
            print(String(format: "by element: %d differences, parse %.2fs + align %.2fs",
                         hunks.count, parsed, alignTime))
            var lSeen = 0, rSeen = 0
            for s in aligned { lSeen += s.leftCount; rSeen += s.rightCount }
            let ok = lSeen == la.count && rSeen == lb.count
            print(ok ? "every line of both files is shown exactly once"
                     : "LINE COUNTS DO NOT MATCH: left \(lSeen)/\(la.count), right \(rSeen)/\(lb.count)")
            if let first = hunks.first {
                print("first difference: left \(first.leftCount) lines, right \(first.rightCount) lines")
            }
            return ok ? 0 : 1
        }
        print("by element: could not align, the window would fall back to line by line")
        return 1
    }

    // MARK: CSV export

    private static func checkCSV() {
        section("CSV export")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xmleditorx-selfcheck.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = CSVExport.write(
            header: ["Line", "Path", "Text"],
            rows: [["4",
                    CSVExport.field("scenario \u{203A} region[USA]", foldTypography: true),
                    CSVExport.field("he said \"hi\"\nand left")]],
            to: url)
        check("the file is written", ok)

        guard let data = try? Data(contentsOf: url) else {
            failures.append("CSV: the file could not be read back")
            print("  FAIL CSV: the file could not be read back")
            return
        }
        check("starts with a UTF-8 byte-order mark",
              data.count > 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        check("rows end with CRLF", text.contains("\r\n"))
        check("the app's own separator folds to ASCII", text.contains("scenario > region[USA]"))
        check("quotes inside a cell are doubled", text.contains("\"\"hi\"\""))
        check("a newline inside a cell becomes a space", text.contains("he said \"\"hi\"\" and left"))
        equal("a non-finite number becomes an empty cell", CSVExport.number(.nan), "")
        equal("an ordinary number is written plainly", CSVExport.number(1.5), "1.5")
    }

    // MARK: share excerpt

    private static func checkShareExcerpt() {
        section("Share excerpt")
        let short = ShareTextPolicy.excerpt(from: "hello", maximumUTF8Bytes: 100)
        equal("text within the limit is unchanged", short.text, "hello")
        let cut = ShareTextPolicy.excerpt(from: "hello world", maximumUTF8Bytes: 5)
        check("text over the limit is cut", cut.text.utf8.count <= 5)
        let emoji = ShareTextPolicy.excerpt(from: "ab\u{1F600}cd", maximumUTF8Bytes: 4)
        check("an emoji is never split", emoji.text == "ab")
    }

    // MARK: themes

    private static func checkThemes() {
        section("Themes")
        func luminance(_ c: NSColor) -> CGFloat {
            guard let s = c.usingColorSpace(.sRGB) else { return 0 }
            func f(_ v: CGFloat) -> CGFloat {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * f(s.redComponent) + 0.7152 * f(s.greenComponent) + 0.0722 * f(s.blueComponent)
        }
        func over(_ fg: NSColor, _ bg: NSColor) -> NSColor {
            guard let f = fg.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return fg }
            let a = f.alphaComponent
            return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a),
                           green: f.greenComponent * a + b.greenComponent * (1 - a),
                           blue: f.blueComponent * a + b.blueComponent * (1 - a),
                           alpha: 1)
        }
        func contrast(_ fg: NSColor, _ bg: NSColor) -> CGFloat {
            let a = luminance(over(fg, bg)) + 0.05
            let b = luminance(bg) + 0.05
            return max(a, b) / min(a, b)
        }

        check("there is at least one theme", Theme.all.isEmpty == false)
        for t in Theme.all {
            let ground = t.panelOpaque
            // The window title is drawn by the system from the window's
            // appearance, while the titlebar behind it is painted from the
            // theme, so a dark palette MUST declare itself dark.
            equal("\(t.id): appearance matches isDark",
                  t.appearance.name, t.isDark ? NSAppearance.Name.darkAqua : .aqua)
            check("\(t.id): isDark agrees with the background",
                  (luminance(t.bg) < 0.18) == t.isDark)
            let pairs: [(String, NSColor)] = [
                ("text", t.text), ("text2", t.text2), ("text3", t.text3),
                ("syntaxTag", t.syntaxTag), ("syntaxAttr", t.syntaxAttr),
                ("syntaxVal", t.syntaxVal), ("syntaxText", t.syntaxText),
                ("syntaxCom", t.syntaxCom), ("ok", t.ok), ("warn", t.warn), ("err", t.err),
            ]
            for (name, color) in pairs {
                let ratio = contrast(color, ground)
                check("\(t.id): \(name) reads on the pane (\(String(format: "%.2f", ratio)):1)",
                      ratio >= 4.5)
            }
        }
    }
}
