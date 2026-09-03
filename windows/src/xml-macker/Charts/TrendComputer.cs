using System.Globalization;
using XMLMacker.Core;

namespace XMLMacker.Charts;

/// <summary>
/// Pure, stateless data layer: turns a selected <see cref="XmlTreeNode"/> into an optional
/// <see cref="TrendSeries"/>, or <c>null</c> when the selection has no meaningful numeric
/// comparison. 1:1 port of the Swift <c>TrendComputer</c> enum-namespace.
/// Two engines run in sequence:
/// <list type="bullet">
/// <item><b>GCAM engine</b>, domain-specific: a repeating axis carrying <c>year/period/time</c> →
///   LINE; a non-time repeater with a pinned year/period somewhere → BAR; else no chart.</item>
/// <item><b>Universal / generic engine</b>, answers whenever GCAM comes up empty: any structure
///   that repeats (≥2 same-tag siblings) carrying a number plus a label.</item>
/// </list>
/// The generic engine's dropdown spellings begin with <c>@</c> / <c>=</c> / <c>#</c>, all illegal
/// as XML tag-name starts, so they can never collide with a real leaf name and they route
/// <see cref="Compute"/> to the generic engine.
/// </summary>
public static class TrendComputer
{
    // ── Constants ──────────────────────────────────────────────
    private const int ChildScanCap = 2000;
    private const int GenericSampleSize = 40;
    private const int StrideCap = 1500;
    private const int CategoricalToLineFlip = 40;
    private const int LabelTruncation = 24;

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>Key attributes, order significant.</summary>
    private static readonly string[] KeyAttributeNames = { "name", "year", "type", "id", "key" };

    /// <summary>Attributes that act as labels, never as chartable values.</summary>
    private static readonly HashSet<string> LabelAttrNames = new(StringComparer.Ordinal)
    {
        "year", "period", "time", "date", "id", "name", "key", "label", "title"
    };

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Public API
    // ════════════════════════════════════════════════════════════════════════════════════

    /// <summary>
    /// The ordered, de-duplicated list of variable names offered in the pane's "Variable:" dropdown.
    /// GCAM leaf names first (the node itself, numeric-leaf element children, then numeric-leaf
    /// grandchildren), then
    /// the generic engine's variables in group/scan order. Returns an empty list when nothing is
    /// chartable.
    /// </summary>
    public static IReadOnlyList<string> AvailableTargets(XmlTreeNode? node)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var outList = new List<string>();
        if (node is null) return outList;

        // 2. node itself is a numeric leaf.
        if (IsNumericLeaf(node) && seen.Add(node.Name))
            outList.Add(node.Name);

        // 3. numeric-leaf element children.
        foreach (var c in node.Children)
        {
            if (c.Kind == NodeKind.Element && IsNumericLeaf(c) && seen.Add(c.Name))
                outList.Add(c.Name);
        }

        // 4. Numeric leaves one level deeper, such as period/input/efficiency.
        foreach (var c in node.Children)
        {
            if (c.Kind != NodeKind.Element) continue;
            foreach (var grandchild in c.Children)
            {
                if (grandchild.Kind == NodeKind.Element && IsNumericLeaf(grandchild) && seen.Add(grandchild.Name))
                    outList.Add(grandchild.Name);
            }
        }

        // 5. generic engine variables.
        foreach (var g in GenericGroups(node))
        {
            foreach (var v in GenericVars(g))
            {
                string d = v.Display;
                if (seen.Add(d)) outList.Add(d);
            }
        }

        return outList;
    }

    /// <summary>
    /// Router: a <paramref name="preferred"/> starting with <c>@</c>/<c>=</c>/<c>#</c>
    /// goes straight to the generic engine; otherwise the GCAM engine is tried first, then the generic
    /// engine as a fallback. <paramref name="preferred"/> is the dropdown selection (or <c>null</c> to
    /// auto-pick the first target).
    /// </summary>
    public static TrendSeries? Compute(XmlTreeNode? node, string? preferred = null)
    {
        if (node is null) return null;

        if (!string.IsNullOrEmpty(preferred) &&
            (preferred[0] == '@' || preferred[0] == '=' || preferred[0] == '#'))
        {
            return GenericCompute(node, preferred);
        }

        var gcam = GcamCompute(node, preferred);
        if (gcam is not null) return gcam;

        return GenericCompute(node, preferred);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  GCAM engine
    // ════════════════════════════════════════════════════════════════════════════════════

    private sealed class Repeater
    {
        public required List<XmlTreeNode> Siblings { get; init; }
        public required List<XmlTreeNode> Path { get; init; }
        public required XmlTreeNode Node { get; init; }
    }

    private static TrendSeries? GcamCompute(XmlTreeNode node, string? preferred)
    {
        // INSIDE the selection first. A level that repeats under the selected element (its subsectors,
        // its periods…) is what the selection points at. Only when nothing inside repeats does it climb above
        // it, the same element in every region, and so on. (Before, the engine always climbed from the
        // first value it found: a supplysector inside USA charted "32 regions" instead of its own parts.)
        TrendSeries? inside = InsideCompute(node, preferred);
        if (inside is not null) return inside;

        XmlTreeNode? target = FindNumericLeafTarget(node, preferred);
        if (target is null) return null;

        var pathDown = new List<XmlTreeNode>();
        Repeater? timeRepeater = null;
        Repeater? fallbackRepeater = null;

        XmlTreeNode cursor = target;
        while (cursor.Parent is not null)
        {
            XmlTreeNode parent = cursor.Parent;
            var siblings = new List<XmlTreeNode>();
            foreach (var c in parent.Children)
                if (c.Kind == NodeKind.Element && c.Name == cursor.Name)
                    siblings.Add(c);

            if (siblings.Count >= 2)
            {
                var cand = new Repeater
                {
                    Siblings = siblings,
                    Path = new List<XmlTreeNode>(pathDown),
                    Node = cursor
                };
                if (HasTimeKey(cursor) && timeRepeater is null) timeRepeater = cand;
                else if (fallbackRepeater is null) fallbackRepeater = cand;
            }

            pathDown.Insert(0, cursor);
            cursor = parent;
        }

        // Prefer a genuine time axis → LINE.
        if (timeRepeater is not null)
            return BuildSeries(target, timeRepeater.Path, timeRepeater.Siblings,
                               timeRepeater.Node, TrendKind.Line, null);

        // Non-time repeater accepted ONLY if a year/period is pinned somewhere → BAR.
        if (fallbackRepeater is not null)
        {
            string? ctxYear = CollectContextYear(target, fallbackRepeater.Path);
            if (ctxYear is not null)
                return BuildSeries(target, fallbackRepeater.Path, fallbackRepeater.Siblings,
                                   fallbackRepeater.Node, TrendKind.Bar, $"year {ctxYear}");
        }

        return null;
    }

    /// <summary>How far below the selection repeating levels are searched, and how many containers at most.</summary>
    private const int InsideMaxDepth = 8;
    private const int InsideMaxContainers = 4000;

    /// <summary>
    /// The chart WITHIN the selected element: the shallowest level under it whose same-named children
    /// (two or more) each lead down to the wanted numeric leaf. A level keyed by year/period wins, a
    /// line over time, even when a shallower plain level exists; otherwise the shallowest plain level
    /// with a year pinned on the way down gives a bar per member (logit-exponent per subsector in 1975).
    /// Nothing repeats inside → null, and the caller climbs above the selection as before.
    /// </summary>
    private static TrendSeries? InsideCompute(XmlTreeNode node, string? preferred)
    {
        if (IsNumericLeaf(node)) return null;   // a value itself has nothing inside

        var queue = new Queue<(XmlTreeNode Container, int Depth)>();
        queue.Enqueue((node, 0));
        int seen = 0;
        (Group Group, List<XmlTreeNode> Path, XmlTreeNode Target)? timeHit = null;
        (Group Group, List<XmlTreeNode> Path, XmlTreeNode Target, string Year)? barHit = null;

        while (queue.Count > 0 && seen < InsideMaxContainers)
        {
            (XmlTreeNode container, int depth) = queue.Dequeue();
            seen++;
            foreach (Group g in SameNameGroups(container.Children))
            {
                List<XmlTreeNode>? path = LeafPathBelow(g.Members[0], preferred);
                if (path is null) continue;
                XmlTreeNode target = path.Count > 0 ? path[^1] : g.Members[0];
                if (HasTimeKey(g.Members[0]))
                {
                    timeHit ??= (g, path, target);
                }
                else if (barHit is null)
                {
                    string? year = CollectContextYear(target, path);
                    if (year is not null) barHit = (g, path, target, year);
                }
            }
            if (timeHit is not null) break;   // the shallowest time level wins outright
            if (depth < InsideMaxDepth)
                foreach (var c in container.Children)
                    if (c.Kind == NodeKind.Element) queue.Enqueue((c, depth + 1));
        }

        if (timeHit is { } t)
            return BuildSeries(t.Target, t.Path, t.Group.Members, t.Group.Members[0], TrendKind.Line, null);
        if (barHit is { } b)
            return BuildSeries(b.Target, b.Path, b.Group.Members, b.Group.Members[0], TrendKind.Bar, $"year {b.Year}");
        return null;
    }

    /// <summary>
    /// The chain of elements from just below <paramref name="start"/> down to the first numeric leaf
    /// (named <paramref name="preferred"/> when given), shallowest first. Empty when
    /// <paramref name="start"/> itself is that leaf; null when there is none within reach.
    /// </summary>
    private static List<XmlTreeNode>? LeafPathBelow(XmlTreeNode start, string? preferred)
    {
        bool Wanted(XmlTreeNode n) => IsNumericLeaf(n) && (string.IsNullOrEmpty(preferred) || n.Name == preferred);
        if (Wanted(start)) return new List<XmlTreeNode>();

        var queue = new Queue<(XmlTreeNode Node, int Depth)>();
        var parentOf = new Dictionary<XmlTreeNode, XmlTreeNode>(ReferenceEqualityComparer.Instance);
        queue.Enqueue((start, 0));
        int seen = 0;
        while (queue.Count > 0 && seen++ < 2000)
        {
            (XmlTreeNode n, int depth) = queue.Dequeue();
            foreach (var c in n.Children)
            {
                if (c.Kind != NodeKind.Element) continue;
                parentOf[c] = n;
                if (Wanted(c))
                {
                    var chain = new List<XmlTreeNode>();
                    for (XmlTreeNode x = c; !ReferenceEquals(x, start); x = parentOf[x]) chain.Insert(0, x);
                    return chain;
                }
                if (depth + 1 < 6) queue.Enqueue((c, depth + 1));
            }
        }
        return null;
    }

    /// <summary>
    /// Chooses which leaf to plot. When <paramref name="preferred"/> is set the choice is binding
    /// (never silently substitute another variable); when it is <c>null</c> the node itself, else the
    /// first numeric-leaf element child, else nothing.
    /// </summary>
    private static XmlTreeNode? FindNumericLeafTarget(XmlTreeNode node, string? preferred)
    {
        if (!string.IsNullOrEmpty(preferred))
        {
            if (IsNumericLeaf(node) && node.Name == preferred) return node;
            foreach (var c in node.Children)
                if (c.Kind == NodeKind.Element && IsNumericLeaf(c) && c.Name == preferred)
                    return c;
            foreach (var c in node.Children)
            {
                if (c.Kind != NodeKind.Element) continue;
                foreach (var grandchild in c.Children)
                    if (grandchild.Kind == NodeKind.Element && IsNumericLeaf(grandchild) && grandchild.Name == preferred)
                        return grandchild;
            }
            return null;
        }

        if (IsNumericLeaf(node)) return node;
        foreach (var c in node.Children)
            if (c.Kind == NodeKind.Element && IsNumericLeaf(c))
                return c;
        foreach (var c in node.Children)
        {
            if (c.Kind != NodeKind.Element) continue;
            foreach (var grandchild in c.Children)
                if (grandchild.Kind == NodeKind.Element && IsNumericLeaf(grandchild))
                    return grandchild;
        }
        return null;
    }

    /// <summary>True iff the node has no element children and its trimmed text parses as a Double.</summary>
    private static bool IsNumericLeaf(XmlTreeNode n)
    {
        foreach (var c in n.Children)
            if (c.Kind == NodeKind.Element) return false;
        return ParseD(n.TextValue) is not null;
    }

    /// <summary>True iff any attribute name (lowercased) is exactly <c>year</c>, <c>period</c> or <c>time</c>.</summary>
    private static bool HasTimeKey(XmlTreeNode node)
    {
        foreach (var (name, _) in node.Attributes)
        {
            string l = name.ToLowerInvariant();
            if (l == "year" || l == "period" || l == "time") return true;
        }
        return false;
    }

    /// <summary>
    /// Scans <c>[target] + path</c>; returns the first <c>year</c>/<c>period</c> attribute value found
    /// (lowercased name match). <c>time</c> is NOT accepted as a context year here.
    /// </summary>
    private static string? CollectContextYear(XmlTreeNode target, List<XmlTreeNode> path)
    {
        var scan = new List<XmlTreeNode>(path.Count + 1) { target };
        scan.AddRange(path);
        foreach (var node in scan)
            foreach (var (name, value) in node.Attributes)
            {
                string l = name.ToLowerInvariant();
                if (l == "year" || l == "period") return value;
            }
        return null;
    }

    private static TrendSeries? BuildSeries(XmlTreeNode target, List<XmlTreeNode> path,
        List<XmlTreeNode> siblings, XmlTreeNode repeater, TrendKind kind, string? context)
    {
        var labels = new List<string>();
        var values = new List<double>();

        foreach (var sib in siblings)
        {
            XmlTreeNode? leaf = Walk(sib, path);
            if (leaf is null) continue;
            double? val = ParseD(leaf.TextValue);
            if (val is null) continue;
            labels.Add(LabelFor(sib));
            values.Add(val.Value);
        }

        if (values.Count < 2) return null;

        // Sample when there are more points than the view can distinguish, exactly as the generic engine
        // does below. Without it a document with a million repeated elements makes every repaint build a
        // million text labels.
        if (values.Count > StrideCap)
        {
            int n = values.Count;
            double step = n / (double)StrideCap;
            var sampledLabels = new List<string>();
            var sampledValues = new List<double>();
            for (double i = 0; i < n; i += step)
            {
                int idx = (int)i;
                if (idx < n) { sampledLabels.Add(labels[idx]); sampledValues.Add(values[idx]); }
            }
            labels = sampledLabels;
            values = sampledValues;
        }

        // Time series with all-integer labels → sort ascending by integer label (chronological).
        if (kind == TrendKind.Line && labels.All(l => int.TryParse(l, NumberStyles.Integer, Inv, out _)))
        {
            var order = Enumerable.Range(0, labels.Count)
                .OrderBy(i => int.Parse(labels[i], NumberStyles.Integer, Inv))
                .ToList();
            labels = order.Select(i => labels[i]).ToList();
            values = order.Select(i => values[i]).ToList();
        }

        string title = $"{target.Name} · {values.Count} {repeater.Name}" + (values.Count == 1 ? "" : "s");
        if (context is not null) title += $" ({context})";

        IReadOnlyList<double>? positions = null;
        if (kind == TrendKind.Line && labels.All(label =>
                double.TryParse(label, NumberStyles.Float, Inv, out double number) && double.IsFinite(number)))
        {
            List<double> parsed = labels.Select(label => double.Parse(label, NumberStyles.Float, Inv)).ToList();
            if (parsed.Zip(parsed.Skip(1), (left, right) => left < right).All(increasing => increasing))
                positions = parsed;
        }
        return new TrendSeries(title, labels, values, values.Min(), values.Max(), kind)
            { XPositions = positions };
    }

    /// <summary>
    /// Re-descends the recorded tag chain under a sibling to fetch its corresponding leaf. Rejects
    /// wrong-key matches (a lone <c>year="1975"</c> must not be matched against <c>year="1990"</c>).
    /// </summary>
    private static XmlTreeNode? Walk(XmlTreeNode start, List<XmlTreeNode> path)
    {
        XmlTreeNode current = start;
        foreach (var step in path)
        {
            var candidates = new List<XmlTreeNode>();
            foreach (var c in current.Children)
                if (c.Kind == NodeKind.Element && c.Name == step.Name)
                    candidates.Add(c);

            if (candidates.Count == 0) return null;

            if (candidates.Count == 1)
            {
                XmlTreeNode cand = candidates[0];
                if (StepHasKey(step) && !KeysMatch(cand, step)) return null;
                current = cand;
            }
            else
            {
                XmlTreeNode? picked = null;
                foreach (var c in candidates)
                    if (KeysMatch(c, step)) { picked = c; break; }
                if (picked is null) return null;
                current = picked;
            }
        }
        return current;
    }

    private static bool StepHasKey(XmlTreeNode node)
    {
        foreach (var (name, _) in node.Attributes)
        {
            string l = name.ToLowerInvariant();
            foreach (var k in KeyAttributeNames)
                if (l == k) return true;
        }
        return false;
    }

    /// <summary>
    /// For each key name in order, read both sides' value; the first key where at least one side is
    /// present decides (<c>a == b</c>). If neither side has any of the 5 keys → <c>false</c>.
    /// </summary>
    private static bool KeysMatch(XmlTreeNode a, XmlTreeNode b)
    {
        foreach (var key in KeyAttributeNames)
        {
            string? va = AttrCI(a, key);
            string? vb = AttrCI(b, key);
            if (va is not null || vb is not null)
                return va == vb;
        }
        return false;
    }

    /// <summary>First present attribute among year/name/period/id → value; else first attribute; else name.</summary>
    private static string LabelFor(XmlTreeNode node)
    {
        foreach (var key in new[] { "year", "name", "period", "id" })
        {
            string? v = AttrCI(node, key);
            if (v is not null) return v;
        }
        if (node.Attributes.Count > 0) return node.Attributes[0].Value;
        return node.Name;
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Universal / generic engine
    // ════════════════════════════════════════════════════════════════════════════════════

    private sealed class Group
    {
        public required string Name { get; init; }
        public required List<XmlTreeNode> Members { get; init; }
    }

    private enum GenericVarKind { Attribute, OwnText, ValueChild }

    private readonly struct GenericVar
    {
        public GenericVarKind Kind { get; }
        public string Name { get; }
        public GenericVar(GenericVarKind kind, string name) { Kind = kind; Name = name; }

        public string Display => Kind switch
        {
            GenericVarKind.Attribute => "@" + Name,
            GenericVarKind.OwnText => "= value",
            GenericVarKind.ValueChild => Name,
            _ => Name
        };
    }

    /// <summary>
    /// Buckets the first <see cref="ChildScanCap"/> children by tag name (first-seen order preserved),
    /// keeps buckets with ≥2 members, and sorts by member count descending.
    /// </summary>
    private static List<Group> SameNameGroups(List<XmlTreeNode> children)
    {
        var order = new List<string>();
        var buckets = new Dictionary<string, List<XmlTreeNode>>(StringComparer.Ordinal);

        int scanned = 0;
        foreach (var c in children)
        {
            if (scanned >= ChildScanCap) break;
            scanned++;
            if (c.Kind != NodeKind.Element) continue;
            if (!buckets.TryGetValue(c.Name, out var list))
            {
                list = new List<XmlTreeNode>();
                buckets[c.Name] = list;
                order.Add(c.Name);
            }
            list.Add(c);
        }

        var groups = new List<Group>();
        foreach (var name in order)
        {
            var members = buckets[name];
            if (members.Count >= 2) groups.Add(new Group { Name = name, Members = members });
        }

        groups.Sort((x, y) => y.Members.Count.CompareTo(x.Members.Count));
        return groups;
    }

    /// <summary>Candidate repeats, nearest first.</summary>
    private static List<Group> GenericGroups(XmlTreeNode node)
    {
        var result = new List<Group>();

        // 1. the container itself is selected.
        foreach (var g in SameNameGroups(node.Children).Take(2))
            result.Add(g);

        // 2. one member is selected, its same-name siblings.
        if (node.Parent is not null)
        {
            var siblings = new List<XmlTreeNode>();
            foreach (var c in node.Parent.Children)
                if (c.Kind == NodeKind.Element && c.Name == node.Name)
                    siblings.Add(c);
            if (siblings.Count >= 2)
                result.Add(new Group { Name = node.Name, Members = siblings });
        }

        return result;
    }

    /// <summary>Chartable variables for a group, in value-child → own-text → attribute order.</summary>
    private static List<GenericVar> GenericVars(Group group)
    {
        int sampleCount = Math.Min(GenericSampleSize, group.Members.Count);
        var sample = group.Members.Take(sampleCount).ToList();
        int need = Math.Max(2, (sampleCount * 4 + 4) / 5);

        var vars = new List<GenericVar>();

        // 1. Value-child vars (element-child tag names in first-seen order).
        var childOrder = new List<string>();
        var seenChild = new HashSet<string>(StringComparer.Ordinal);
        foreach (var m in sample)
            foreach (var c in m.Children)
                if (c.Kind == NodeKind.Element && seenChild.Add(c.Name))
                    childOrder.Add(c.Name);

        foreach (var name in childOrder)
        {
            int count = 0;
            foreach (var m in sample)
            {
                foreach (var c in m.Children)
                {
                    if (c.Kind == NodeKind.Element && c.Name == name && IsNumericLeaf(c))
                    {
                        count++;
                        break;
                    }
                }
            }
            if (count >= need) vars.Add(new GenericVar(GenericVarKind.ValueChild, name));
        }

        // 2. Own-text var.
        int ownTextCount = 0;
        foreach (var m in sample)
            if (IsNumericLeaf(m)) ownTextCount++;
        if (ownTextCount >= need) vars.Add(new GenericVar(GenericVarKind.OwnText, ""));

        // 3. Attribute vars (names not in labelAttrNames).
        var attrOrder = new List<string>();
        var seenAttr = new HashSet<string>(StringComparer.Ordinal);
        foreach (var m in sample)
            foreach (var (aName, _) in m.Attributes)
                if (!LabelAttrNames.Contains(aName.ToLowerInvariant()) && seenAttr.Add(aName))
                    attrOrder.Add(aName);

        foreach (var name in attrOrder)
        {
            var values = new List<string>();
            foreach (var m in sample)
            {
                string? v = AttrExact(m, name);
                if (v is null) continue;
                string trimmed = v.Trim();
                if (ParseD(trimmed) is not null) values.Add(trimmed);
            }
            var distinct = new HashSet<string>(values, StringComparer.Ordinal);
            bool binaryFlag = distinct.IsSubsetOf(new[] { "0", "1" });
            if (values.Count >= need && distinct.Count >= 2 && !binaryFlag)
                vars.Add(new GenericVar(GenericVarKind.Attribute, name));
        }

        return vars;
    }

    private static TrendSeries? GenericCompute(XmlTreeNode node, string? preferred)
    {
        foreach (var g in GenericGroups(node))
        {
            var vars = GenericVars(g);
            if (vars.Count == 0) continue;

            GenericVar? chosen = null;
            if (!string.IsNullOrEmpty(preferred))
            {
                foreach (var v in vars)
                    if (v.Display == preferred) { chosen = v; break; }
            }
            else if (vars.Count > 0)
            {
                chosen = vars[0];
            }

            if (chosen is null) continue;

            var s = BuildGenericSeries(g, chosen.Value);
            if (s is not null) return s;
        }
        return null;
    }

    private static double? GenericValue(GenericVar v, XmlTreeNode member)
    {
        switch (v.Kind)
        {
            case GenericVarKind.Attribute:
                return ParseD(AttrExact(member, v.Name));
            case GenericVarKind.OwnText:
                return ParseD(member.TextValue);
            case GenericVarKind.ValueChild:
                foreach (var c in member.Children)
                    if (c.Kind == NodeKind.Element && c.Name == v.Name)
                        return ParseD(c.TextValue);
                return null;
            default:
                return null;
        }
    }

    private static string GenericLabel(XmlTreeNode member, int index)
    {
        // 1. First present attribute among the label set.
        foreach (var key in new[] { "year", "name", "period", "id", "date", "label", "title", "key" })
        {
            string? v = AttrCI(member, key);
            if (!string.IsNullOrEmpty(v)) return Trunc(v);
        }

        // 2. First child named title/name/label with non-empty text.
        foreach (var c in member.Children)
        {
            if (c.Kind != NodeKind.Element) continue;
            string l = c.Name.ToLowerInvariant();
            if ((l == "title" || l == "name" || l == "label") && !string.IsNullOrEmpty(c.TextValue))
                return Trunc(c.TextValue);
        }

        // 3. Member's first attribute value.
        if (member.Attributes.Count > 0 && !string.IsNullOrEmpty(member.Attributes[0].Value))
            return Trunc(member.Attributes[0].Value);

        // 4. 1-based index.
        return (index + 1).ToString(Inv);
    }

    private static TrendSeries? BuildGenericSeries(Group group, GenericVar v)
    {
        var labels = new List<string>();
        var values = new List<double>();

        for (int i = 0; i < group.Members.Count; i++)
        {
            var m = group.Members[i];
            double? val = GenericValue(v, m);
            if (val is null) continue;
            labels.Add(GenericLabel(m, i));
            values.Add(val.Value);
        }

        if (values.Count < 2) return null;

        bool numericLabels = labels.All(l => double.TryParse(l, NumberStyles.Float, Inv, out _));
        if (numericLabels)
        {
            var order = Enumerable.Range(0, labels.Count)
                .OrderBy(i => double.Parse(labels[i], NumberStyles.Float, Inv))
                .ToList();
            labels = order.Select(i => labels[i]).ToList();
            values = order.Select(i => values[i]).ToList();
        }

        TrendKind kind = (numericLabels || values.Count > CategoricalToLineFlip)
            ? TrendKind.Line : TrendKind.Bar;

        // Stride-sample so drawing stays instant while the shape survives.
        if (values.Count > StrideCap)
        {
            int n = values.Count;
            double step = n / (double)StrideCap;
            var sl = new List<string>();
            var sv = new List<double>();
            for (double i = 0; i < n; i += step)
            {
                int idx = (int)i;
                if (idx < n) { sl.Add(labels[idx]); sv.Add(values[idx]); }
            }
            labels = sl;
            values = sv;
        }

        string title = $"{v.Display} · {values.Count} {group.Name}" + (values.Count == 1 ? "" : "s");
        IReadOnlyList<double>? positions = numericLabels
            ? labels.Select(label => double.Parse(label, NumberStyles.Float, Inv)).ToList()
            : null;
        return new TrendSeries(title, labels, values, values.Min(), values.Max(), kind)
            { XPositions = positions };
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Shared helpers
    // ════════════════════════════════════════════════════════════════════════════════════

    /// <summary>Parses a trimmed Double using invariant culture; <c>null</c> when empty or non-numeric.</summary>
    private static double? ParseD(string? s)
    {
        if (s is null) return null;
        string t = s.Trim();
        if (t.Length == 0) return null;
        return double.TryParse(t, NumberStyles.Float, Inv, out double v) ? v : null;
    }

    /// <summary>First attribute whose lowercased name equals <paramref name="lowerName"/>.</summary>
    private static string? AttrCI(XmlTreeNode node, string lowerName)
    {
        foreach (var (name, value) in node.Attributes)
            if (name.ToLowerInvariant() == lowerName) return value;
        return null;
    }

    /// <summary>First attribute whose name matches <paramref name="name"/> exactly (ordinal).</summary>
    private static string? AttrExact(XmlTreeNode node, string name)
    {
        foreach (var (n, value) in node.Attributes)
            if (n == name) return value;
        return null;
    }

    private static string Trunc(string s) => s.Length > LabelTruncation ? s.Substring(0, LabelTruncation) : s;
}
