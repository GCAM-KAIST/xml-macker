using System.Globalization;
using XMLMacker.Core;

namespace XMLMacker.Charts;

/// <summary>
/// Builds a chart query as a path of keyed XML containers. One repeating path level is the
/// horizontal axis; the remaining levels pin the walk to a particular branch.
/// </summary>
public sealed class ChartPathBuilder
{
    public sealed record Option(string Tag, string Key, XmlTreeNode Node)
    {
        public string Label => $"{Tag} · {Key}";
    }

    public sealed class Level
    {
        public required List<Option> Options { get; init; }
        public int Choice { get; set; }
        public bool IsAxis { get; set; }
        public Option Current => Options[Choice];
        public string Tag => Current.Tag;
        public List<Option> Members => Options.Where(o => o.Tag == Current.Tag).ToList();
        public bool Repeats => Members.Count >= 2;
        public bool MixedTags => Options.Select(o => o.Tag).Distinct(StringComparer.Ordinal).Skip(1).Any();
    }

    public const int ScanCap = 200_000;
    private const int PassThroughCap = 8;
    private const int DepthCap = 40;
    private static readonly string[] KeyAttributes = { "name", "year", "type", "id", "key" };
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public XmlTreeNode Root { get; }
    public List<Level> Levels { get; private set; } = new();
    public List<string> ValueNames { get; private set; } = new();
    public bool ValueScanTruncated { get; private set; }
    public string LastPathSummary { get; private set; } = "";
    public string? ValueName { get; set; }
    public int? AxisIndex
    {
        get
        {
            int index = Levels.FindIndex(l => l.IsAxis);
            return index < 0 ? null : index;
        }
    }
    public XmlTreeNode? BaseNode =>
        AxisIndex is int axis ? Levels[axis].Current.Node : Levels.LastOrDefault()?.Current.Node;
    public XmlTreeNode? DeepestPinnedNode => Levels.LastOrDefault()?.Current.Node;

    public ChartPathBuilder(XmlTreeNode root) => Root = root;

    public static string? KeyOf(XmlTreeNode node)
    {
        foreach (string key in KeyAttributes)
        {
            foreach (var attribute in node.Attributes)
            {
                if (attribute.Name == key && attribute.Value.Length > 0)
                    return attribute.Value;
            }
        }
        return null;
    }

    private static bool IsContainer(XmlTreeNode node) =>
        node.Children.Any(c => c.Kind == NodeKind.Element);

    private static List<Option> LevelOptions(XmlTreeNode node)
    {
        var result = new List<Option>();
        foreach (XmlTreeNode child in node.Children)
        {
            if (child.Kind != NodeKind.Element || !IsContainer(child)) continue;
            string? key = KeyOf(child);
            if (key is not null) result.Add(new Option(child.Name, key, child));
        }
        return result;
    }

    private static XmlTreeNode PassThrough(XmlTreeNode node)
    {
        XmlTreeNode current = node;
        for (int hop = 0; hop < PassThroughCap && LevelOptions(current).Count == 0; hop++)
        {
            List<XmlTreeNode> containers = current.Children
                .Where(c => c.Kind == NodeKind.Element && IsContainer(c)).ToList();
            if (containers.Count != 1) break;
            current = containers[0];
        }
        return current;
    }

    public void Rebuild(XmlTreeNode? seed)
    {
        var onPath = new HashSet<int>();
        for (XmlTreeNode? current = seed; current is not null && current.Kind == NodeKind.Element;
             current = current.Parent)
            onPath.Add(current.Id);

        Levels = BuildLevels(Root, new List<Level>(), onPath);
        int deepestSeeded = Levels.FindLastIndex(l => onPath.Contains(l.Current.Node.Id));
        int axis = Levels.FindIndex(deepestSeeded + 1, l => l.Repeats);
        if (axis < 0 && deepestSeeded >= 0 && Levels[deepestSeeded].Repeats) axis = deepestSeeded;
        if (axis < 0) axis = Levels.FindLastIndex(l => l.Repeats);
        SetAxisInternal(axis >= 0 ? axis : null);
        RefreshValues();
    }

    private static List<Level> BuildLevels(XmlTreeNode start, IReadOnlyList<Level> old,
        HashSet<int> onPath)
    {
        var result = new List<Level>();
        XmlTreeNode cursor = start;
        for (int depth = 0; depth < DepthCap; depth++)
        {
            List<Option> options = LevelOptions(PassThrough(cursor));
            if (options.Count == 0) break;
            Level? previous = result.Count < old.Count ? old[result.Count] : null;
            int choice = options.FindIndex(o => onPath.Contains(o.Node.Id));
            if (choice < 0 && previous is not null)
                choice = options.FindIndex(o => o.Tag == previous.Tag && o.Key == previous.Current.Key);
            if (choice < 0) choice = 0;
            result.Add(new Level
            {
                Options = options,
                Choice = choice,
                IsAxis = previous?.IsAxis ?? false
            });
            cursor = options[choice].Node;
        }
        return result;
    }

    public void SetChoice(int levelIndex, int optionIndex)
    {
        if (levelIndex < 0 || levelIndex >= Levels.Count) return;
        Level level = Levels[levelIndex];
        if (optionIndex < 0 || optionIndex >= level.Options.Count) return;

        bool wasAxis = level.IsAxis;
        level.Choice = optionIndex;
        level.IsAxis = false;
        List<Level> oldBelow = Levels.Skip(levelIndex + 1).ToList();
        List<Level> below = BuildLevels(level.Current.Node, oldBelow, new HashSet<int>());
        Levels = Levels.Take(levelIndex + 1).Concat(below).ToList();

        if (wasAxis || AxisIndex is null)
        {
            int next = Levels.FindIndex(levelIndex + 1, l => l.Repeats);
            if (next < 0) next = Levels.FindLastIndex(levelIndex - 1, l => l.Repeats);
            SetAxisInternal(next >= 0 ? next : null);
        }
        RefreshValues();
    }

    public void SetAxis(int levelIndex)
    {
        if (levelIndex < 0 || levelIndex >= Levels.Count || !Levels[levelIndex].Repeats) return;
        SetAxisInternal(levelIndex);
        RefreshValues();
    }

    private void SetAxisInternal(int? index)
    {
        for (int i = 0; i < Levels.Count; i++) Levels[i].IsAxis = i == index;
    }

    public void RefreshValues()
    {
        ValueNames = new List<string>();
        ValueScanTruncated = false;
        XmlTreeNode? root = BaseNode;
        if (root is null) { ValueName = null; return; }

        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        var stack = new Stack<XmlTreeNode>();
        stack.Push(root);
        int visited = 0;
        while (stack.Count > 0)
        {
            XmlTreeNode node = stack.Pop();
            if (++visited > ScanCap) { ValueScanTruncated = true; break; }
            List<XmlTreeNode> children = node.Children.Where(c => c.Kind == NodeKind.Element).ToList();
            if (children.Count == 0)
            {
                if (!ReferenceEquals(node, root) && TryNumber(node.TextValue, out _))
                    counts[node.Name] = counts.GetValueOrDefault(node.Name) + 1;
                continue;
            }
            for (int i = children.Count - 1; i >= 0; i--) stack.Push(children[i]);
        }

        ValueNames = counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key,
            StringComparer.Ordinal).Select(pair => pair.Key).ToList();
        if (ValueName is not null && !ValueNames.Contains(ValueName, StringComparer.Ordinal))
            ValueName = null;
        ValueName ??= ValueNames.FirstOrDefault();
    }

    public TrendSeries? Compute()
    {
        if (ValueName is not string value || AxisIndex is not int axis) return null;
        Level axisLevel = Levels[axis];
        var filters = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int i = axis + 1; i < Levels.Count; i++)
            filters[Levels[i].Tag] = Levels[i].Current.Key;

        var points = new List<(string Label, double Value)>();
        foreach (Option member in axisLevel.Members)
        {
            double? found = FirstValue(value, member.Node, filters);
            if (found is not null) points.Add((member.Key, found.Value));
        }
        if (points.Count < 2) return null;

        bool numeric = points.All(point => TryNumber(point.Label, out _));
        if (numeric) points.Sort((left, right) => ParseNumber(left.Label).CompareTo(ParseNumber(right.Label)));
        List<string> labels = points.Select(point => point.Label).ToList();
        List<double> values = points.Select(point => point.Value).ToList();

        var summary = new List<string>();
        for (int i = 0; i < Levels.Count; i++)
        {
            if (i == axis) continue;
            summary.Add($"{Levels[i].Tag} {Levels[i].Current.Key}");
        }
        LastPathSummary = string.Join(" › ", summary);
        return new TrendSeries($"{value} across {axisLevel.Tag}", labels, values,
            values.Min(), values.Max(), numeric ? TrendKind.Line : TrendKind.Bar)
        {
            XPositions = numeric ? labels.Select(ParseNumber).ToList() : null
        };
    }

    private static double? FirstValue(string name, XmlTreeNode root,
        IReadOnlyDictionary<string, string> filters)
    {
        var stack = new Stack<XmlTreeNode>();
        stack.Push(root);
        int visited = 0;
        while (stack.Count > 0)
        {
            XmlTreeNode node = stack.Pop();
            if (++visited > ScanCap) return null;
            List<XmlTreeNode> children = node.Children.Where(c => c.Kind == NodeKind.Element).ToList();
            if (children.Count == 0)
            {
                if (node.Name == name && TryNumber(node.TextValue, out double value) && double.IsFinite(value))
                    return value;
                continue;
            }
            if (!ReferenceEquals(node, root) && filters.TryGetValue(node.Name, out string? wanted) &&
                KeyOf(node) is string actual && actual != wanted)
                continue;
            for (int i = children.Count - 1; i >= 0; i--) stack.Push(children[i]);
        }
        return null;
    }

    private static bool TryNumber(string text, out double value) =>
        double.TryParse(text.Trim(), NumberStyles.Float, Inv, out value);

    private static double ParseNumber(string text) =>
        double.Parse(text.Trim(), NumberStyles.Float, Inv);
}
