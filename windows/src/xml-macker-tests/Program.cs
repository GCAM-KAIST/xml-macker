using System.Reflection;
using XMLMacker.Core;
using XMLMacker.Charts;
using XMLMacker.Windows;

var failures = new List<string>();
void Check(bool condition, string name)
{
    if (!condition) failures.Add(name);
}

XmlTreeNode Root(string xml)
{
    ParseResult result = new XmlStreamParser().ParseText(xml);
    Check(result.Errors.Count == 0, $"parser accepted valid XML: {xml}");
    return result.Root.Children.First();
}

string Apply(string source, FixIt fix)
{
    Check(source.Substring(fix.Range.Start, fix.Range.Length) == fix.Original,
        $"fix original matches: {fix.Title}");
    return source.Remove(fix.Range.Start, fix.Range.Length).Insert(fix.Range.Start, fix.Replacement);
}

List<ParseError> Lint(string source, bool end = true, int offset = 0) =>
    XmlFragmentLinter.Lint(source, 1, end, offset);

XmlTreeNode? Find(XmlTreeNode node, string name)
{
    if (node.Kind == NodeKind.Element && node.Name == name) return node;
    foreach (XmlTreeNode child in node.Children)
        if (Find(child, name) is { } found) return found;
    return null;
}

XmlTreeNode entity = Root("<root>Hello &amp; world</root>");
Check(entity.TextValue == "Hello & world", "entity-separated text keeps spaces");
XmlTreeNode cdata = Root("<root>before <![CDATA[<tag>&value]]> after</root>");
Check(cdata.TextValue == "before <tag>&value after", "CDATA stays literal and keeps spaces");
XmlTreeNode multiline = Root("<root\n label=\"top\">\n<child\n label=\"nested\">value</child>\n</root>");
Check(multiline.StartLine == 1, "multiline root uses opening line");
Check(multiline.Children.First().StartLine == 3, "multiline child uses opening line");
Check(XmlStreamParser.ValidateText("<root><child/></root>").Count == 0,
    "errors-only validator accepts valid XML");
Check(XmlStreamParser.ValidateText("<root><child></root>").Count > 0,
    "errors-only validator reports malformed XML");

ParseError ambiguous = Lint("<region><period>1</peroid></region>").First();
Check(ambiguous.Fix?.Title == "Change closing tag to </period>",
    "innermost closing-tag typo offers the current Mac repair");
if (ambiguous.Fix is { } ambiguousFix)
    Check(Lint(Apply("<region><period>1</peroid></region>", ambiguousFix)).Count == 0,
        "innermost closing-tag repair produces valid XML");

// A slip typed into the OPENING tag among many correctly named siblings: the neighbours decide, and the
// opening tag is renamed instead of the closing tag being "repaired" into a brand-new element name.
string openingTypoSource = "<root><item>1</item><item>2</item><itme>3</item><item>4</item></root>";
ParseError openingTypo = Lint(openingTypoSource).First();
Check(openingTypo.Fix?.Title.StartsWith("Change opening tag to <item>", StringComparison.Ordinal) == true,
    "opening-tag typo among named siblings renames the opening tag");
if (openingTypo.Fix is { } openingFix)
{
    string repaired = Apply(openingTypoSource, openingFix);
    Check(Lint(repaired).Count == 0 && !repaired.Contains("itme"),
        "opening-tag repair produces valid XML with no new element name");
}
// With no neighbours to consult, the closing tag is still the one renamed (the Mac rule).
ParseError lonely = Lint("<root><peroid>1</period></root>").First();
Check(lonely.Fix?.Title == "Change closing tag to </peroid>",
    "without sibling evidence the closing tag is renamed");

string partialTreeSource =
    "<root><item name=\"first\"><value>1</vlaue></item><item name=\"later\"/></root>";
ParseResult partialTree = new XmlStreamParser().ParseText(partialTreeSource);
Check(Find(partialTree.Root, "item") is not null &&
      partialTree.Root.Children.SelectMany(node => node.Children).Count(node => node.Name == "item") == 1,
    "malformed closing tag leaves a partial pre-fix tree");
FixIt? partialTreeFix = Lint(partialTreeSource).FirstOrDefault(error => error.Fix is not null)?.Fix;
if (partialTreeFix is not null)
{
    string repairedTreeSource = Apply(partialTreeSource, partialTreeFix);
    ParseResult rebuiltTree = new XmlStreamParser().ParseText(repairedTreeSource);
    XmlTreeNode? rebuiltRoot = Find(rebuiltTree.Root, "root");
    Check(rebuiltTree.Errors.Count == 0 &&
          rebuiltRoot?.Children.Count(node => node.Kind == NodeKind.Element && node.Name == "item") == 2,
        "reparsing after a syntax repair restores later siblings to the tree model");
}
ParseError ambiguousOpen = Lint("<region><peiod>1</period></region>").First();
Check(ambiguousOpen.Fix?.Title == "Change closing tag to </peiod>",
    "innermost mismatch always exposes a reversible Fix button");

string established = "<region><period/><period>1</peroid></region>";
FixIt? establishedFix = Lint(established).FirstOrDefault()?.Fix;
Check(establishedFix?.Title == "Change closing tag to </period>", "established sibling enables safe rename");
if (establishedFix is not null) Check(Lint(Apply(established, establishedFix)).Count == 0,
    "established sibling rename repairs XML");

string establishedAncestor = "<root><region/><region><period>1</regoin></root>";
List<ParseError> ancestorErrors = Lint(establishedAncestor);
Check(ancestorErrors.Select(error => error.Fix?.Title).Where(title => title is not null)
        .SequenceEqual(new[] { "Insert </period> before </regoin>", "Change closing tag to </region>" }),
    "established outer sibling safely closes the inner element before renaming");
if (ancestorErrors.FirstOrDefault()?.Fix is { } closeInner)
{
    establishedAncestor = Apply(establishedAncestor, closeInner);
    FixIt? renameOuter = Lint(establishedAncestor).FirstOrDefault(error => error.Fix is not null)?.Fix;
    if (renameOuter is not null) establishedAncestor = Apply(establishedAncestor, renameOuter);
    Check(establishedAncestor == "<root><region/><region><period>1</period></region></root>",
        "outer typo repairs preserve nested content");
    Check(Lint(establishedAncestor).Count == 0, "outer typo repair produces valid XML");
}

ParseError unrelatedClose = Lint("<period></technology></period>").First();
Check(unrelatedClose.Message.Contains("Stray closing tag") && unrelatedClose.Fix is null,
    "unrelated closing tag remains diagnostic only");

string missingCloseEnd = "<region></region";
FixIt? missingCloseFix = Lint(missingCloseEnd).FirstOrDefault()?.Fix;
Check(missingCloseFix is not null && Apply(missingCloseEnd, missingCloseFix) == "<region></region>",
    "missing closing-tag delimiter is inserted");

string missingCloseBeforeTag = "<root></root<outside/>";
FixIt? missingCloseBeforeTagFix = Lint(missingCloseBeforeTag).FirstOrDefault()?.Fix;
Check(missingCloseBeforeTagFix is not null &&
      Apply(missingCloseBeforeTag, missingCloseBeforeTagFix) == "<root></root><outside/>",
    "missing closing-tag delimiter before another tag is inserted");

ParseError? malformedCloseName = Lint("<root></ ></root>").FirstOrDefault();
Check(malformedCloseName?.Message.Contains("Malformed closing tag") == true &&
      malformedCloseName.Fix is null,
    "closing tag without a name is diagnosed without guessing a repair");

ParseError? closingTagJunk = Lint("<root></root junk>").FirstOrDefault();
Check(closingTagJunk?.Message.Contains("Unexpected text in closing tag") == true &&
      closingTagJunk.Fix is null,
    "closing-tag junk is recovered but never deleted automatically");

string missingOpenEnd = "<region name=\"USA\"<period/></region>";
FixIt? missingOpenEndFix = Lint(missingOpenEnd).FirstOrDefault()?.Fix;
Check(missingOpenEndFix is not null && Apply(missingOpenEnd, missingOpenEndFix) ==
    "<region name=\"USA\"><period/></region>", "missing opening-tag delimiter is inserted");

string missingQuote = "<period year=\"2020>\n<technology/>\n</period>";
FixIt? missingQuoteFix = Lint(missingQuote).FirstOrDefault()?.Fix;
Check(missingQuoteFix is not null && Apply(missingQuote, missingQuoteFix) ==
    "<period year=\"2020\">\n<technology/>\n</period>", "missing attribute quote is inserted");

string eofQuote = "<period year=\"2020";
FixIt? eofQuoteFix = Lint(eofQuote).FirstOrDefault()?.Fix;
if (eofQuoteFix is not null) eofQuote = Apply(eofQuote, eofQuoteFix);
Check(eofQuote == "<period year=\"2020\">", "end-of-file quote and tag delimiter repair is local");
FixIt? eofElementFix = Lint(eofQuote).FirstOrDefault()?.Fix;
if (eofElementFix is not null) eofQuote = Apply(eofQuote, eofElementFix);
Check(eofQuote == "<period year=\"2020\"></period>" && Lint(eofQuote).Count == 0,
    "end-of-file element closes in a second local repair");

string missingEquals = "<period year \"2020\"></period>";
FixIt? missingEqualsFix = Lint(missingEquals).FirstOrDefault()?.Fix;
if (missingEqualsFix is not null) missingEquals = Apply(missingEquals, missingEqualsFix);
Check(missingEquals == "<period year =\"2020\"></period>" && Lint(missingEquals).Count == 0,
    "missing attribute equals sign has an insertion repair");

string missingOpeningQuote = "<period year=2020\"></period>";
FixIt? missingOpeningQuoteFix = Lint(missingOpeningQuote).FirstOrDefault()?.Fix;
if (missingOpeningQuoteFix is not null) missingOpeningQuote = Apply(missingOpeningQuote, missingOpeningQuoteFix);
Check(missingOpeningQuote == "<period year=\"2020\"></period>" && Lint(missingOpeningQuote).Count == 0,
    "missing attribute opening quote has an insertion repair");

foreach ((string source, string expected) in new[]
{
    ("<!-- note", "<!-- note-->"),
    ("<![CDATA[value", "<![CDATA[value]]>"),
    ("<?work value", "<?work value?>")
})
{
    FixIt? fix = Lint(source).FirstOrDefault()?.Fix;
    Check(fix is not null && Apply(source, fix) == expected, $"append-only repair: {source}");
}

foreach (string source in new[]
{
    "<root><!-- note",
    "<root><![CDATA[value",
    "<root><?work value",
    "<root><child value=\""
})
    Check(Lint(source).Count(error => error.Fix is not null) == 1,
        $"unfinished construct exposes only one independent repair: {source}");

Check(Lint("<region><period", end: false).Count == 0,
    "truncated validation window does not append missing syntax");
Check(Lint("<!-- note", end: false).Count == 0,
    "truncated comment window does not append a closing marker");

string declarationWithNestedEnds =
    "<!DOCTYPE root [<!ELEMENT root (#PCDATA)><!ENTITY sample \"a>b\">]><root/>";
Check(Lint(declarationWithNestedEnds).Count == 0,
    "markup declaration ignores quoted and internal-subset closing characters");
List<ParseError> unfinishedDeclaration = Lint("<root><!DOCTYPE nested [");
Check(unfinishedDeclaration.Count == 1 &&
      unfinishedDeclaration[0].Message.Contains("Markup declaration is never closed") &&
      unfinishedDeclaration[0].Fix is null,
    "unfinished markup declaration suppresses dependent element-close repairs");

Check(Lint("<value>&gcam-entity;</value>").Count == 0, "custom entity syntax is accepted");
ParseError? badNumericEntity = Lint("<value>&#xZZ;</value>").FirstOrDefault();
Check(badNumericEntity?.Fix?.Replacement == "&amp;", "invalid numeric entity repairs ampersand");

foreach (string source in new[] { "<value>&amp</value>", "<value>&#65</value>" })
{
    FixIt? semicolonFix = Lint(source).FirstOrDefault()?.Fix;
    string repaired = semicolonFix is null ? source : Apply(source, semicolonFix);
    Check(semicolonFix?.Replacement == ";" && Lint(repaired).Count == 0,
        $"safe missing entity semicolon is inserted: {source}");
}
ParseError? customEntityWithoutSemicolon = Lint("<value>&custom</value>").FirstOrDefault();
Check(customEntityWithoutSemicolon?.Fix?.Replacement == "&amp;",
    "unknown missing-semicolon entity is escaped instead of guessed");

string quotedBadEntity = "<root a=\"foo&bar\"/>";
List<ParseError> quotedEntityErrors = Lint(quotedBadEntity);
Check(quotedEntityErrors.Any(error => error.Message.Contains("attribute 'a'")) &&
      quotedEntityErrors.FirstOrDefault(error => error.Fix is not null)?.Fix?.Replacement == "&amp;",
    "quoted attribute entity is diagnosed before quote repair");

string unquotedBadEntity = "<root a=foo&bar/>";
List<ParseError> unquotedEntityErrors = Lint(unquotedBadEntity);
Check(unquotedEntityErrors.Count(error => error.Fix is not null) == 1 &&
      unquotedEntityErrors.FirstOrDefault(error => error.Fix is not null)?.Fix?.Replacement == "&amp;" &&
      unquotedEntityErrors.All(error => error.Fix?.Title.Contains("Wrap") != true),
    "unquoted attribute entity is escaped before wrapping the value");
string quotedMissingSemicolon = "<root a=\"A&amp\"/>";
FixIt? quotedSemicolonFix = Lint(quotedMissingSemicolon).FirstOrDefault()?.Fix;
Check(quotedSemicolonFix?.Replacement == ";" &&
      Lint(Apply(quotedMissingSemicolon, quotedSemicolonFix)).Count == 0,
    "quoted attribute gets the safe missing-semicolon repair");

Check(Lint("<root year 2020/>").All(e => e.Fix is null), "bare attribute is diagnostic only");
string emptyBareAttribute = "<root enabled/>";
FixIt? emptyBareAttributeFix = Lint(emptyBareAttribute).FirstOrDefault()?.Fix;
Check(emptyBareAttributeFix is not null &&
      Apply(emptyBareAttribute, emptyBareAttributeFix) == "<root enabled=\"\"/>",
    "unambiguous empty bare attribute gets a local repair");
string wordBareAttribute = "<root name USA/>";
FixIt? wordBareAttributeFix = Lint(wordBareAttribute).FirstOrDefault()?.Fix;
Check(wordBareAttributeFix is not null &&
      Apply(wordBareAttribute, wordBareAttributeFix) == "<root name =\"USA\"/>" &&
      Lint(Apply(wordBareAttribute, wordBareAttributeFix)).Count == 0,
    "unambiguous word after a bare attribute becomes its quoted value");
ParseError? illegalTagJunk = Lint("<root @x/>")
    .FirstOrDefault(error => error.Message.Contains("Unexpected token"));
Check(illegalTagJunk is not null && illegalTagJunk.Fix is null,
    "illegal tag token itself remains diagnostic only");

string noWhitespace = "<root a=\"1\"b=\"2\"/>";
FixIt? whitespaceFix = Lint(noWhitespace).FirstOrDefault()?.Fix;
Check(whitespaceFix is not null && Apply(noWhitespace, whitespaceFix) == "<root a=\"1\" b=\"2\"/>",
    "missing attribute whitespace is inserted");
Check(Lint("<root a=\n\"1\"/>").Count == 0, "line break is valid attribute whitespace");

string spacedSlash = "<root / >";
FixIt? spacedSlashFix = Lint(spacedSlash).FirstOrDefault()?.Fix;
Check(spacedSlashFix is not null && Apply(spacedSlash, spacedSlashFix) == "<root />",
    "self-closing slash is normalized");

string missingSlashEnd = "<root /  ";
FixIt? missingSlashEndFix = Lint(missingSlashEnd).FirstOrDefault()?.Fix;
Check(missingSlashEndFix is not null && Apply(missingSlashEnd, missingSlashEndFix) == "<root />",
    "unfinished self-closing slash is completed");
List<ParseError> slashJunk = Lint("<root / junk></root>");
ParseError? unsafeSlash = slashJunk.FirstOrDefault(error => error.Message.Contains("Unexpected '/'"));
Check(unsafeSlash is not null && unsafeSlash.Fix is null,
    "unexpected self-closing slash itself remains diagnostic only");

foreach (string source in new[]
{
    "<root><transportation></transport></root>",
    "<root><abcdefgh></abcxyzgh></root>"
})
{
    ParseError? distantName = Lint(source).FirstOrDefault();
    Check(distantName?.Message.Contains("Stray closing tag") == true && distantName.Fix is null,
        $"distant tag names are not treated as safe typos: {source}");
}

string duplicate = "<period year=\"1975\" year=\"1975\"/>";
FixIt? duplicateFix = Lint(duplicate).FirstOrDefault()?.Fix;
Check(duplicateFix?.Title.Contains("exactly redundant") == true, "exact duplicate attribute has a safe fix");
Check(Lint("<period year=\"1975\" year=\"2000\"/>").FirstOrDefault()?.Fix is null,
    "conflicting duplicate attribute has no unsafe fix");
Check(Lint("<period/></period-broken>").Count == 0, "self-closing scope ignores trailing text");
FixIt? absoluteFix = Lint(missingCloseEnd, offset: 12_345).FirstOrDefault()?.Fix;
Check(absoluteFix?.Range.Start == 12_345 + missingCloseEnd.Length, "fix range is document-absolute");

MethodInfo? diffLineStarts = typeof(DiffWindow).GetMethod(
    "LineStarts", BindingFlags.NonPublic | BindingFlags.Static);
int[]? unterminatedLineStarts = diffLineStarts?.Invoke(
    null, new object[] { new List<string> { "a", "b" }, 3 }) as int[];
Check(unterminatedLineStarts?.SequenceEqual(new[] { 0, 2, 3 }) == true,
    "diff final-line range ends at the real document length");

MethodInfo? diffCopyText = typeof(DiffWindow).GetMethod(
    "CopyTextForLines", BindingFlags.NonPublic | BindingFlags.Static);
string? copiedUnterminatedLastLine = diffCopyText?.Invoke(
    null, new object[] { new List<string> { "a", "b" }, "a\nb", 1, 1 }) as string;
string? copiedTerminatedLastLine = diffCopyText?.Invoke(
    null, new object[] { new List<string> { "a", "b" }, "a\nb\n", 1, 1 }) as string;
Check(copiedUnterminatedLastLine == "b",
    "diff copy preserves a final line without a newline");
Check(copiedTerminatedLastLine == "b\n",
    "diff copy preserves a final line with a newline");

XmlTreeNode trendRoot = new XmlStreamParser().ParseText("""
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
""").Root;
XmlTreeNode technologyA = Find(trendRoot, "stub-technology")!;
XmlTreeNode period = Find(technologyA, "period")!;
TrendSeries? timeSeries = TrendComputer.Compute(period, "share-weight");
Check(timeSeries?.Kind == TrendKind.Line, "time comparison is a line chart");
Check(timeSeries?.XLabels.SequenceEqual(new[] { "1975", "1990", "2005" }) == true,
    "time comparison is sorted by year");
Check(timeSeries?.Values.SequenceEqual(new[] { 0.5, 1.0, 2.0 }) == true,
    "time comparison stays inside the selected technology");

XmlTreeNode nestedTrendRoot = Root("""
<technology>
  <period year="1975"><minicam-energy-input name="electricity"><efficiency>0.25</efficiency><calibrated-value>4</calibrated-value></minicam-energy-input></period>
  <period year="1990"><minicam-energy-input name="electricity"><efficiency>0.5</efficiency><calibrated-value>5</calibrated-value></minicam-energy-input></period>
  <period year="2005"><minicam-energy-input name="electricity"><efficiency>0.75</efficiency><calibrated-value>6</calibrated-value></minicam-energy-input></period>
</technology>
""");
XmlTreeNode nestedPeriod = Find(nestedTrendRoot, "period")!;
IReadOnlyList<string> nestedTargets = TrendComputer.AvailableTargets(nestedPeriod);
Check(nestedTargets.Contains("efficiency") && nestedTargets.Contains("calibrated-value"),
    "chart variable discovery includes numeric grandchildren");
TrendSeries? nestedSeries = TrendComputer.Compute(nestedPeriod, "efficiency");
Check(nestedSeries?.XLabels.SequenceEqual(new[] { "1975", "1990", "2005" }) == true &&
      nestedSeries?.Values.SequenceEqual(new[] { 0.25, 0.5, 0.75 }) == true,
    "numeric-grandchild chart follows the matching nested path across periods");

XmlTreeNode unrelatedDescendantRoot = Root("""
<root><branch>
  <item name="a"><value>1</value></item>
  <item name="b"><value>2</value></item>
</branch></root>
""");
Check(TrendComputer.AvailableTargets(unrelatedDescendantRoot).Count == 0,
    "automatic chart scope does not descend into an unrelated grandchild group");

XmlTreeNode structuralRoot = Root("""
<root>
  <item name="a"><child/></item>
  <item name="b"><child/><child/><child/></item>
  <item name="c"><child/><child/><child/><child/><child/></item>
  <item name="d"><child/><child/><child/><child/><child/><child/><child/></item>
</root>
""");
Check(!TrendComputer.AvailableTargets(structuralRoot).Contains("# children"),
    "element-child counts are not presented as chart values");

XmlTreeNode attributeRoot = Root("""
<root>
  <item name="a" amount="10" constant="5" flag="0"/>
  <item name="b" amount="20" constant="5" flag="1"/>
  <item name="c" amount="30" constant="5" flag="0"/>
  <item name="d" amount="40" constant="5" flag="1"/>
</root>
""");
IReadOnlyList<string> attributeTargets = TrendComputer.AvailableTargets(attributeRoot);
Check(attributeTargets.Contains("@amount") && !attributeTargets.Contains("@constant") &&
      !attributeTargets.Contains("@flag"),
    "generic charts keep varying quantities and reject constant or binary-flag attributes");

ChartPathBuilder builder = new(trendRoot);
builder.Rebuild(technologyA);
builder.ValueName = "share-weight";
TrendSeries? builtSeries = builder.Compute();
Check(builtSeries?.XLabels.SequenceEqual(new[] { "1975", "1990", "2005" }) == true,
    "whole-file chart builder follows the selected technology path");
Check(builtSeries?.Values.SequenceEqual(new[] { 0.5, 1.0, 2.0 }) == true,
    "whole-file chart builder returns the selected path values");

if (failures.Count == 0)
{
    // ── Marker strokes: painting, recolouring, erasing, following edits, next/previous ──────────
{
    var h = new TextHighlights();
    h.Paint(10, 5, HighlightColor.Yellow);          // [10,15)
    h.Paint(30, 4, HighlightColor.Red);             // [30,34)
    Check(h.Count == 2 && h.IsCovered(11, 3, HighlightColor.Yellow) && !h.IsCovered(9, 3, HighlightColor.Yellow), "highlight: strokes and coverage");
    h.Paint(12, 2, HighlightColor.Blue);            // recolour the middle: [10,12) Y, [12,14) B, [14,15) Y
    Check(h.Count == 4 && h.All[1].Color == HighlightColor.Blue && h.All[1].Start == 12 && h.All[1].Length == 2, "highlight: painting over a stroke recolours that part");
    h.Paint(12, 2, HighlightColor.None);            // erase the blue part
    Check(h.Count == 3 && !h.IsCovered(12, 2, HighlightColor.Blue), "highlight: painting with the eraser removes");
    h.ShiftForEdit(0, 0, 3);                        // 3 characters inserted at the very start
    Check(h.All[0].Start == 13 && h.All[^1].Start == 33, "highlight: strokes move after an insertion before them");
    h.ShiftForEdit(13, 2, 0);                       // the first stroke's text deleted
    Check(h.Count == 2 && h.All[0].Start == 15 && h.All[1].Start == 31, "highlight: a stroke whose text was deleted disappears, later strokes move up");
    Check(h.Next(15)!.Value.Start == 31 && h.Next(31)!.Value.Start == 15 && h.Previous(15)!.Value.Start == 31, "highlight: next/previous wrap around");
    Check(h.OrdinalOf(h.All[1]) == 2, "highlight: ordinal");
}

Console.WriteLine("All xml-macker compatibility checks passed.");
    return 0;
}

Console.Error.WriteLine($"{failures.Count} compatibility checks failed:");
foreach (string failure in failures) Console.Error.WriteLine($"- {failure}");
return 1;
