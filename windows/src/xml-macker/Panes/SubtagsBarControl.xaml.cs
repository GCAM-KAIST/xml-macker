using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// One row of the SUBTAGS table. Exposes a string indexer keyed by column id
/// (<c>#</c>, <c>go</c>, <c>tag</c>, <c>text</c>, <c>attr:&lt;name&gt;</c>) so the dynamically-built
/// <see cref="DataGrid"/> columns can bind two-way. Edits route through <see cref="Commit"/> (guarded
/// against no-op commits) to the owning control's callbacks.
/// </summary>
public sealed class SubtagRow : INotifyPropertyChanged
{
    public XmlTreeNode Node { get; }
    public int Index { get; }
    public bool IsSelfLeaf { get; }
    public Action<SubtagRow, string, string>? Commit { get; set; }

    public SubtagRow(XmlTreeNode node, int index, bool isSelfLeaf)
    {
        Node = node;
        Index = index;
        IsSelfLeaf = isSelfLeaf;
    }

    private string AttrVal(string name)
    {
        foreach ((string Name, string Value) a in Node.Attributes)
            if (a.Name == name) return a.Value;
        return "";
    }

    public string this[string id]
    {
        get => id switch
        {
            "#" => (Index + 1).ToString(CultureInfo.InvariantCulture),
            "go" => "↗",
            "tag" => Node.Name,
            "text" => Node.TextValue,
            _ when id.StartsWith("attr:", StringComparison.Ordinal) => AttrVal(id[5..]),
            _ => ""
        };
        set
        {
            switch (id)
            {
                case "text":
                    if (value != Node.TextValue) Commit?.Invoke(this, "text", value);
                    break;
                case "tag":
                    // No-op commits from focus loss must NOT trigger a rename + tree rebuild.
                    if (value != Node.Name) Commit?.Invoke(this, "tag", value);
                    break;
                default:
                    if (id.StartsWith("attr:", StringComparison.Ordinal))
                    {
                        string n = id[5..];
                        if (value != AttrVal(n)) Commit?.Invoke(this, id, value);
                    }
                    break;
            }
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? n = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

/// <summary>
/// The bottom child-element table (Swift <c>SubtagsBarViewController</c>). Columns are rebuilt
/// programmatically each selection: <c># | ↑Go | Tag | Text | attr:&lt;name&gt;…</c> (ordered union of
/// attribute names with dedup). Three distinct gestures:
/// <list type="bullet">
/// <item><b>Single-click a row</b> = PREVIEW (<see cref="OnSubtagPreview"/>, no tree change).</item>
/// <item><b>Click the ↗ Go button</b> = NAVIGATE (<see cref="OnSubtagSelected"/>).</item>
/// <item><b>Double-click a cell</b> = EDIT in place → <see cref="OnTextEdit"/>/<see cref="OnAttributeEdit"/>/<see cref="OnTagRename"/>.</item>
/// </list>
/// The header ↑ climbs to the parent (<see cref="OnGoUp"/>). Column widths auto-fit content, capped 360.
/// </summary>
public partial class SubtagsBarControl : UserControl
{
    private readonly List<(DataGridColumn col, string id, double min)> _cols = new();
    private List<SubtagRow> _rows = new();
    private XmlTreeNode? _node;
    private int _zoomStep;
    private bool _suppress;
    private bool _editing;
    private SolidColorBrush _frameBrush = new(Colors.Transparent);

    public event Action? OnGoUp;
    public event Action<XmlTreeNode>? OnSubtagPreview;
    public event Action<XmlTreeNode>? OnSubtagSelected;
    public event Action<XmlTreeNode, string, string>? OnAttributeEdit;
    public event Action<XmlTreeNode, string>? OnTextEdit;
    public event Action<XmlTreeNode, string>? OnTagRename;

    public SubtagsBarControl()
    {
        InitializeComponent();

        Grid.SelectionChanged += Grid_SelectionChanged;
        Grid.BeginningEdit += (_, _) => _editing = true;
        Grid.CellEditEnding += (_, _) => _editing = false;
        Grid.MouseDoubleClick += Grid_MouseDoubleClick;
        Grid.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnAnyButtonClick));

        Frame.Background = _frameBrush;

        Loaded += (_, _) =>
        {
            ThemeManager.ThemeChanged += OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            RebuildFrameBrush();
            ApplyZoom();
        };
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
        };

        ApplyZoom();
    }

    /// <summary>True while a cell is being edited (guards background refreshes).</summary>
    public bool IsEditingCell => _editing;

    // ── Row model ─────────────────────────────────────────────────────────────────────────────
    private static List<XmlTreeNode> ElementKids(XmlTreeNode node)
    {
        var kids = new List<XmlTreeNode>();
        foreach (XmlTreeNode c in node.Children)
            if (c.Kind == NodeKind.Element) kids.Add(c);
        return kids;
    }

    /// <summary>Populate the table for <paramref name="node"/> (rebuilds columns + rows + widths).</summary>
    public void SetNode(XmlTreeNode? node)
    {
        _suppress = true;
        try
        {
            _node = node;
            if (node is null)
            {
                Grid.Columns.Clear();
                _cols.Clear();
                _rows = new List<SubtagRow>();
                Grid.ItemsSource = null;
                Title.Text = "";
                return;
            }

            List<XmlTreeNode> kids = ElementKids(node);
            bool selfLeaf = kids.Count == 0 && !string.IsNullOrEmpty(node.TextValue);
            List<XmlTreeNode> displayed = selfLeaf ? new List<XmlTreeNode> { node } : kids;

            // The pane header bar already says SUBTAGS; keep only the information: the count, or "leaf".
            Title.Text = selfLeaf ? "leaf value, no subtags" : $"{kids.Count} subtag{(kids.Count == 1 ? "" : "s")}";

            // Ordered union of attribute names (first-occurrence order, dedup).
            var attrNames = new List<string>();
            var seen = new HashSet<string>();
            foreach (XmlTreeNode d in displayed)
                foreach ((string Name, string Value) a in d.Attributes)
                    if (seen.Add(a.Name)) attrNames.Add(a.Name);

            bool anyHasText = displayed.Exists(d => !string.IsNullOrEmpty(d.TextValue));

            BuildColumns(attrNames, anyHasText);

            _rows = new List<SubtagRow>(displayed.Count);
            for (int i = 0; i < displayed.Count; i++)
            {
                var row = new SubtagRow(displayed[i], i, selfLeaf) { Commit = OnRowCommit };
                _rows.Add(row);
            }
            Grid.ItemsSource = _rows;

            AutoSizeColumns(displayed, attrNames);
        }
        finally
        {
            _suppress = false;
        }
    }

    /// <summary>Re-run <see cref="SetNode"/> only when a node is set and no cell is being edited.</summary>
    public void RefreshValuesOnly()
    {
        if (_node is not null && !_editing)
            SetNode(_node);
    }

    // ── Columns ───────────────────────────────────────────────────────────────────────────────
    private void BuildColumns(List<string> attrNames, bool anyHasText)
    {
        Grid.Columns.Clear();
        _cols.Clear();

        AddTextColumn("#", "#", XMColor.Text3, editable: false, width: 28, min: 24);
        AddGoColumn();
        AddTextColumn("Tag", "tag", XMColor.SyntaxTag, editable: true, width: 160, min: 80);
        if (anyHasText)
            AddTextColumn("Text", "text", XMColor.SyntaxText, editable: true, width: 200, min: 80);
        foreach (string name in attrNames)
            AddTextColumn(name, "attr:" + name, XMColor.SyntaxVal, editable: true, width: 140, min: 60);
    }

    private void AddTextColumn(string header, string id, string fgKey, bool editable, double width, double min)
    {
        var col = new DataGridTextColumn
        {
            Header = header,
            IsReadOnly = !editable,
            MinWidth = min,
            Width = new DataGridLength(width),
            Binding = new Binding($"[{id}]")
            {
                Mode = editable ? BindingMode.TwoWay : BindingMode.OneWay,
                UpdateSourceTrigger = UpdateSourceTrigger.LostFocus,
            },
            ElementStyle = CellStyle(fgKey),
        };
        if (editable) col.EditingElementStyle = EditStyle(fgKey);
        Grid.Columns.Add(col);
        _cols.Add((col, id, min));
    }

    private void AddGoColumn()
    {
        var headerBtn = new Button
        {
            Content = "↑",
            Tag = "goUp",
            Cursor = Cursors.Hand,
            Focusable = false,
            ToolTip = "Go up to the parent element",
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            FontWeight = FontWeights.SemiBold,
        };
        headerBtn.SetResourceReference(ForegroundProperty, XMColor.Accent);

        var col = new DataGridTemplateColumn
        {
            Header = headerBtn,
            CellTemplate = (DataTemplate)Resources["GoCellTemplate"],
            IsReadOnly = true,
            CanUserSort = false,
            MinWidth = 28,
            Width = new DataGridLength(32),
        };
        Grid.Columns.Add(col);
        _cols.Add((col, "go", 28));
    }

    private static Style CellStyle(string fgKey)
    {
        var s = new Style(typeof(TextBlock));
        s.Setters.Add(new Setter(TextBlock.ForegroundProperty, new DynamicResourceExtension(fgKey)));
        s.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(4, 0, 4, 0)));
        s.Setters.Add(new Setter(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis));
        s.Setters.Add(new Setter(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center));
        return s;
    }

    private static Style EditStyle(string fgKey)
    {
        var s = new Style(typeof(TextBox));
        s.Setters.Add(new Setter(Control.ForegroundProperty, new DynamicResourceExtension(fgKey)));
        s.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(2, 0, 2, 0)));
        return s;
    }

    private double PixelsPerDip()
    {
        try { return VisualTreeHelper.GetDpi(this).PixelsPerDip; }
        catch { return 1.0; }
    }

    private double TextWidth(string s, Typeface tf, double size, double ppd)
    {
        var ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            tf, size, Brushes.Black, ppd);
        return ft.WidthIncludingTrailingWhitespace;
    }

    /// <summary>Fit each column to content: header + widest cell + 16pt padding, clamped [min, 360].</summary>
    private void AutoSizeColumns(List<XmlTreeNode> displayed, List<string> attrNames)
    {
        var cellTf = new Typeface(new FontFamily("Cascadia Mono, Consolas"),
            FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);
        var headTf = new Typeface(new FontFamily("Segoe UI"),
            FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
        double cellSize = Grid.FontSize > 0 ? Grid.FontSize : XMFont.Scaled(11.5);
        double headSize = XMFont.Scaled(10);
        double ppd = PixelsPerDip();
        const double padding = 16;

        foreach ((DataGridColumn col, string id, double min) in _cols)
        {
            string headerText = id switch
            {
                "#" => "#",
                "go" => "↑",
                "tag" => "Tag",
                "text" => "Text",
                _ => id.StartsWith("attr:", StringComparison.Ordinal) ? id[5..] : ""
            };
            double max = TextWidth(headerText, headTf, headSize, ppd) + padding;

            for (int i = 0; i < displayed.Count; i++)
            {
                XmlTreeNode child = displayed[i];
                string text = id switch
                {
                    "#" => (i + 1).ToString(CultureInfo.InvariantCulture),
                    "go" => "↗",
                    "tag" => child.Name,
                    "text" => child.TextValue,
                    _ when id.StartsWith("attr:", StringComparison.Ordinal) => AttrValue(child, id[5..]),
                    _ => ""
                };
                if (text.Length == 0) continue;
                double w = TextWidth(text, cellTf, cellSize, ppd) + padding;
                if (w > max) max = w;
            }

            col.Width = new DataGridLength(Math.Clamp(max, min, 360));
        }
    }

    private static string AttrValue(XmlTreeNode node, string name)
    {
        foreach ((string Name, string Value) a in node.Attributes)
            if (a.Name == name) return a.Value;
        return "";
    }

    // ── Commit routing ────────────────────────────────────────────────────────────────────────
    private void OnRowCommit(SubtagRow row, string id, string value)
    {
        // target == row.Node in both cases: displayedRows returns [node] for the self-leaf,
        // or the child otherwise, so the row's node is always the correct edit target.
        if (id == "text") OnTextEdit?.Invoke(row.Node, value);
        else if (id == "tag") OnTagRename?.Invoke(row.Node, value);
        else if (id.StartsWith("attr:", StringComparison.Ordinal))
            OnAttributeEdit?.Invoke(row.Node, id[5..], value);
    }

    // ── Gestures ──────────────────────────────────────────────────────────────────────────────
    private void Grid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (Grid.SelectedItem is not SubtagRow r) return;
        if (r.IsSelfLeaf) return; // already on this node
        OnSubtagPreview?.Invoke(r.Node);
    }

    private void Grid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        // Double-click a cell → open it for editing (read-only #/go columns ignore BeginEdit).
        if (e.OriginalSource is DependencyObject d && FindAncestor<Button>(d) is not null) return;
        Grid.BeginEdit();
    }

    private void OnAnyButtonClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject src) return;
        Button? btn = src as Button ?? FindAncestor<Button>(src);
        if (btn is null) return;

        switch (btn.Tag as string)
        {
            case "goUp":
                OnGoUp?.Invoke();
                e.Handled = true;
                break;
            case "go":
                if (btn.DataContext is SubtagRow r && !r.IsSelfLeaf)
                {
                    _suppress = true;
                    try { OnSubtagSelected?.Invoke(r.Node); }
                    finally { _suppress = false; }
                }
                e.Handled = true;
                break;
        }
    }

    private static T? FindAncestor<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d is not null and not T)
            d = VisualTreeHelper.GetParent(d);
        return d as T;
    }

    // ── Zoom / theme ──────────────────────────────────────────────────────────────────────────
    public void ZoomIn() { _zoomStep = Math.Min(_zoomStep + 1, 16); ApplyZoom(); }
    public void ZoomOut() { _zoomStep = Math.Max(_zoomStep - 1, -3); ApplyZoom(); }
    public void ZoomReset() { _zoomStep = 0; ApplyZoom(); }

    private void ApplyZoom()
    {
        Grid.RowHeight = Math.Max(14, XMMetric.S(22) + _zoomStep * 2);
        Grid.FontSize = XMFont.Scaled(11.5 + _zoomStep);
    }

    private void OnRebuildFonts(object? sender, EventArgs e)
    {
        ApplyZoom();
        if (_node is not null) SetNode(_node); // re-fit columns at the new scale
    }

    private void OnThemeChanged(object? sender, EventArgs e) => RebuildFrameBrush();

    private void RebuildFrameBrush()
    {
        Color deep = XMColor.Color(XMColor.BgDeep);
        _frameBrush.Color = Color.FromArgb((byte)Math.Round(0.35 * 255), deep.R, deep.G, deep.B);
    }
}
