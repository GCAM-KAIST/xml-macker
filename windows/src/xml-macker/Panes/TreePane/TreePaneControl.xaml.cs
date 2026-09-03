using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The left XML tree pane (Swift <c>TreeViewController</c>). A flattened, UI-virtualized
/// <see cref="ListBox"/> over <see cref="FlatTreeModel"/> with the custom Aurora row template
/// (10×10 kind glyph, semibold name, quiet attribute preview) and custom accent selection fill that
/// never grays on focus loss.
/// The tree only REPORTS intent: <see cref="OnSelectNode"/> (the master selection event) and
/// <see cref="OnContextAction"/> (all right-click edits). The owning window performs every document edit.
/// </summary>
public partial class TreePaneControl : UserControl
{
    public Func<XmlTreeNode, string?>? ResolveLinkedFile { get; set; }

    /// <summary>Host supplies the XML text of a node dragged out of the tree (null when too big).</summary>
    public Func<XmlTreeNode, string?>? DragTextForNode { get; set; }
    private readonly FlatTreeModel _model = new();
    private int _zoomStep;

    /// <summary>The master selection event, cascades source highlight + inspector + subtags + hierarchy + breadcrumb + chart.</summary>
    public event Action<XmlTreeNode>? OnSelectNode;

    /// <summary>A right-click context action for the given node. The tree performs no edits itself.</summary>
    public event Action<ContextAction, XmlTreeNode>? OnContextAction;

    public TreePaneControl()
    {
        InitializeComponent();
        VisibleRows = _model.Rows;
        // The XAML ElementName binding evaluated before this property was assigned (and it has no
        // change notification), so bind the ItemsSource directly now that the model exists.
        List.ItemsSource = VisibleRows;

        List.SelectionChanged += List_SelectionChanged;
        List.MouseDoubleClick += List_MouseDoubleClick;
        List.PreviewMouseRightButtonDown += List_PreviewMouseRightButtonDown;
        List.PreviewMouseLeftButtonDown += List_PreviewMouseLeftButtonDown;
        List.PreviewMouseLeftButtonUp += (_, _) => _dragRow = null;
        List.PreviewMouseMove += List_PreviewMouseMove;

        Loaded += (_, _) =>
        {
            RebuildSelectionBrushes();
            ThemeManager.ThemeChanged += OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            ApplyZoom();
        };
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
        };

        ApplyZoom();
    }

    /// <summary>The visible-rows collection bound by the ListBox.</summary>
    public RangeObservableCollection<TreeRow> VisibleRows { get; }

    // ── Zoom-scaled presentation (bound in XAML) ──────────────────────────────────────────────
    public static readonly DependencyProperty RowPixelHeightProperty = DependencyProperty.Register(
        nameof(RowPixelHeight), typeof(double), typeof(TreePaneControl), new PropertyMetadata(22.0));
    public double RowPixelHeight { get => (double)GetValue(RowPixelHeightProperty); set => SetValue(RowPixelHeightProperty, value); }

    public static readonly DependencyProperty NameFontSizeProperty = DependencyProperty.Register(
        nameof(NameFontSize), typeof(double), typeof(TreePaneControl), new PropertyMetadata(12.0));
    public double NameFontSize { get => (double)GetValue(NameFontSizeProperty); set => SetValue(NameFontSizeProperty, value); }

    public static readonly DependencyProperty DetailFontSizeProperty = DependencyProperty.Register(
        nameof(DetailFontSize), typeof(double), typeof(TreePaneControl), new PropertyMetadata(10.5));
    public double DetailFontSize { get => (double)GetValue(DetailFontSizeProperty); set => SetValue(DetailFontSizeProperty, value); }

    // ── Public navigation surface ─────────────────────────────────────────────────────────────

    /// <summary>Load a new root: reset the model, auto-expand the root and its first element child.</summary>
    public void SetRoot(XmlTreeNode? root)
    {
        _model.SetRoot(root);
        if (root is null) return;

        _model.Expand(0); // expand the (single) root row
        XmlTreeNode? firstEl = null;
        foreach (XmlTreeNode c in root.Children)
            if (c.Kind == NodeKind.Element) { firstEl = c; break; }
        if (firstEl is not null)
        {
            int idx = _model.RowIndexForNode(firstEl);
            if (idx >= 0) _model.Expand(idx);
        }
    }

    /// <summary>
    /// Select <paramref name="node"/> (optionally expanding its ancestors first) and scroll it into
    /// view. Setting the selection fires the normal selection-changed path → <see cref="OnSelectNode"/>.
    /// </summary>
    public void Select(XmlTreeNode node, bool expandAncestors = false)
    {
        if (expandAncestors) _model.ExpandAncestors(node);
        int idx = _model.RowIndexForNode(node);
        if (idx < 0) return;
        TreeRow row = _model.Rows[idx];
        List.SelectedItem = row;
        List.ScrollIntoView(row);
    }

    /// <summary>From the selected node, select its parent (expanding ancestors so it is visible).</summary>
    public void DrillUp()
    {
        if (List.SelectedItem is TreeRow r && r.Node.Parent is not null)
            Select(r.Node.Parent, expandAncestors: true);
    }

    /// <summary>From the selected node, expand it and select its first child.</summary>
    public void DrillDown()
    {
        if (List.SelectedItem is not TreeRow r) return;
        int idx = _model.Rows.IndexOf(r);
        if (idx >= 0) _model.Expand(idx);
        if (r.Node.Children.Count > 0)
            Select(r.Node.Children[0], expandAncestors: false);
    }

    /// <summary>Reload a single row after an in-place edit (no whole-tree rebuild).</summary>
    public void RefreshNode(XmlTreeNode node) => _model.RowForNode(node)?.Refresh();

    // ── Per-pane zoom ─────────────────────────────────────────────────────────────────────────
    public void ZoomIn() { _zoomStep = Math.Min(_zoomStep + 1, 16); ApplyZoom(); }
    public void ZoomOut() { _zoomStep = Math.Max(_zoomStep - 1, -4); ApplyZoom(); }
    public void ZoomReset() { _zoomStep = 0; ApplyZoom(); }

    private void ApplyZoom()
    {
        NameFontSize = XMFont.Scaled(12 + _zoomStep);
        DetailFontSize = XMFont.Scaled(10.5 + _zoomStep);
        double baseH = XMMetric.S(22) + _zoomStep * 2;
        RowPixelHeight = Math.Max(14, baseH);
    }

    private void OnRebuildFonts(object? sender, EventArgs e) => ApplyZoom();

    // ── Theme (selection wash brushes) ────────────────────────────────────────────────────────
    private void OnThemeChanged(object? sender, EventArgs e) => RebuildSelectionBrushes();

    private void RebuildSelectionBrushes()
    {
        // REPLACE the two brushes; never edit them in place. Once a row's style has been applied, WPF
        // seals that style and freezes every brush its setters reference, so the old
        // `fill.Color = ...` threw "Cannot set a property on object ... because it is in a read-only
        // state" the second time Loaded fired, which is exactly what happens when this pane is popped
        // out and docked back. The setters use DynamicResource, so a fresh brush is picked up at once.
        Color accent = XMColor.Color(XMColor.Accent);
        var fill = new SolidColorBrush(Color.FromArgb((byte)Math.Round(0.18 * 255), accent.R, accent.G, accent.B));
        var stroke = new SolidColorBrush(Color.FromArgb((byte)Math.Round(0.55 * 255), accent.R, accent.G, accent.B));
        fill.Freeze();
        stroke.Freeze();
        Resources["Tree.SelFill"] = fill;
        Resources["Tree.SelStroke"] = stroke;
    }

    // ── Interaction ───────────────────────────────────────────────────────────────────────────
    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (List.SelectedItem is TreeRow r)
            OnSelectNode?.Invoke(r.Node);
    }

    private void List_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        TreeRow? row = HitTestRow(e.OriginalSource as DependencyObject);
        if (row is null || !row.HasChildren) return;
        int idx = _model.Rows.IndexOf(row);
        if (idx >= 0) _model.Toggle(idx);
        e.Handled = true;
    }

    // Dragging a row out of the tree hands its XML to any drop target: the source pane, the LEARN
    // chat page, or another program. The press is only remembered here; the drag starts on a real move.
    private Point _dragOrigin;
    private TreeRow? _dragRow;

    private void List_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragOrigin = e.GetPosition(List);
        _dragRow = HitTestRow(e.OriginalSource as DependencyObject);
    }

    private void List_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (_dragRow is null) return;
        if (e.LeftButton != MouseButtonState.Pressed) { _dragRow = null; return; }

        Point now = e.GetPosition(List);
        if (Math.Abs(now.X - _dragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance
         && Math.Abs(now.Y - _dragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance) return;

        TreeRow row = _dragRow;
        _dragRow = null;
        if (DragTextForNode?.Invoke(row.Node) is not { Length: > 0 } text) return;

        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, text);
        data.SetData(DataFormats.Text, text);
        try { DragDrop.DoDragDrop(List, data, DragDropEffects.Copy); }
        catch { /* the target refused the drop */ }
    }

    private void List_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        TreeRow? row = HitTestRow(e.OriginalSource as DependencyObject);
        if (row is null) return;

        // Right-click moves selection (full sync) so the highlight "follows me".
        List.SelectedItem = row;

        // Only elements get a menu; text/comment/document rows clear the context node (no menu).
        if (row.Node.Kind != NodeKind.Element)
        {
            e.Handled = true;
            return;
        }

        ContextMenu menu = BuildContextMenu(row.Node);
        menu.PlacementTarget = List;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private TreeRow? HitTestRow(DependencyObject? src)
    {
        while (src is not null and not ListBoxItem)
            src = VisualTreeHelper.GetParent(src);
        return (src as ListBoxItem)?.DataContext as TreeRow;
    }

    // ── Context menu (exact items and order from the macOS version) ────────────────────────
    private ContextMenu BuildContextMenu(XmlTreeNode node)
    {
        var menu = new ContextMenu();

        void Add(string header, ContextAction action)
        {
            var item = new MenuItem { Header = header };
            item.Click += (_, _) => OnContextAction?.Invoke(action, node);
            menu.Items.Add(item);
        }
        void Sep() => menu.Items.Add(new Separator());

        if (ResolveLinkedFile?.Invoke(node) is { } linkedPath)
        {
            Add($"Open Linked File: {System.IO.Path.GetFileName(linkedPath)}", new ContextAction.OpenLinkedFile(linkedPath));
            Sep();
        }
        Add("✨ Define in Learn", new ContextAction.DefineInLearn());
        Sep();
        Add("Copy Element XML", new ContextAction.CopyXml());
        Add("Copy Path", new ContextAction.CopyPath());
        Sep();
        Add("Duplicate Above", new ContextAction.DuplicateAbove());
        Add("Duplicate Below", new ContextAction.DuplicateBelow());
        Sep();
        Add("Cut Element", new ContextAction.Cut());
        Add("Delete Element", new ContextAction.Delete());
        Add("Delete Others (keep only this)", new ContextAction.DeleteOthers());
        Sep();

        // Share ▸ submenu.
        var share = new MenuItem { Header = "Share" };
        foreach (LLMTarget target in LLMTargets.All)
        {
            var t = target;
            var send = new MenuItem { Header = $"Send to {t.DisplayName()}" };
            send.Click += (_, _) => OnContextAction?.Invoke(new ContextAction.ShareToLlm(t), node);
            share.Items.Add(send);
        }
        share.Items.Add(new Separator());
        var define = new MenuItem { Header = "✨ Define in Learn" };
        define.Click += (_, _) => OnContextAction?.Invoke(new ContextAction.DefineInLearn(), node);
        share.Items.Add(define);
        var print = new MenuItem { Header = "Print Element…" };
        print.Click += (_, _) => OnContextAction?.Invoke(new ContextAction.PrintElement(), node);
        share.Items.Add(print);
        var export = new MenuItem { Header = "Export as XML…" };
        export.Click += (_, _) => OnContextAction?.Invoke(new ContextAction.ExportElement(), node);
        share.Items.Add(export);
        menu.Items.Add(share);

        Sep();
        Add($"Find & Replace in {node.DisplayLabel}…", new ContextAction.FindReplace());

        return menu;
    }
}
