using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

public partial class OrbitWindow : Window
{
    private const string PlacementKey = "xml-mackerOrbit";
    private static readonly HashSet<OrbitWindow> Live = new();
    private XmlTreeNode? _node;
    private bool _rendering;

    public event Action<XmlTreeNode>? NodeActivated;
    public event Action<XmlTreeNode>? NodeEditRequested;
    public Func<XmlTreeNode, string, string, bool>? AttributeEditRequested { get; set; }
    public Func<XmlTreeNode, string, bool>? TextEditRequested { get; set; }

    public OrbitWindow()
    {
        InitializeComponent();
        // Ctrl + wheel / Ctrl +/- make the drawing bigger or smaller in THIS window only; Ctrl 0 resets.
        ZoomGestures.Attach(this, () => ZoomOrbit(ZoomGestures.Step), () => ZoomOrbit(1 / ZoomGestures.Step), () => ZoomOrbit(0));
        View.NodeActivated += NavigateTo;
        View.NodeEditRequested += n => NodeEditRequested?.Invoke(n);
        StructureOnlyCheck.IsChecked = StructureFilter.Enabled;
        StructureFilter.Changed += OnStructureChanged;
        Acrylic.Apply(this, ThemeManager.Active.IsDark);
        SourceInitialized += (_, _) => WindowPlacement.Restore(this, PlacementKey);
        Closed += OnClosed;
        PreviewKeyDown += OnPreviewKeyDown;
        SizeChanged += (_, _) => UpdateChrome();
        Loaded += (_, _) => UpdateChrome();
    }

    /// <summary>
    /// Keeps the window's own controls out of the drawing's way.
    /// <para>Hides the Previous/Next page buttons when every child already fits the ring, they used to
    /// sit permanently over the bottom of the diagram even with nothing to page through. Publishes the
    /// measured width of the "Structure only" checkbox so the footer text reserves the real width instead
    /// of a guess. Sizes the details rail from the window width the way the Mac version does, instead of
    /// a fixed 336 pixels that starves the drawing on a small screen.</para>
    /// </summary>
    private void UpdateChrome()
    {
        bool crowded = View.RingIsCrowded();
        PreviousPageButton.Visibility = crowded ? Visibility.Visible : Visibility.Collapsed;
        NextPageButton.Visibility = crowded ? Visibility.Visible : Visibility.Collapsed;

        StructureOnlyCheck.UpdateLayout();
        double toggleWidth = StructureOnlyCheck.ActualWidth;
        if (toggleWidth > 0) View.StructureToggleWidth = toggleWidth;

        if (ActualWidth > 0 && RootGrid.ColumnDefinitions.Count > 1)
        {
            double rail = Math.Min(350, Math.Max(230, ActualWidth * 0.31));
            if (Math.Abs(RootGrid.ColumnDefinitions[1].Width.Value - rail) > 0.5)
                RootGrid.ColumnDefinitions[1].Width = new GridLength(rail);
        }

        View.InvalidateVisual();
    }

    public void Present(XmlTreeNode? node)
    {
        Live.Add(this);
        SetNode(node);
        Show();
        Activate();
        View.Focus();
    }

    public void SetNode(XmlTreeNode? node)
    {
        _node = node;
        View.SetNode(node);
        RenderDetails();
    }

    public void RebuildColors()
    {
        Background = XMColor.Brush(XMColor.BgDeep);
        View.InvalidateVisual();
    }

    private void RenderDetails()
    {
        _rendering = true;
        try
        {
            if (_node is null)
            {
                NodeTitle.Text = "No selection";
                NodeMetadata.Text = "Select an element to inspect it";
                AttributesGrid.ItemsSource = null;
                TextEditor.Text = string.Empty;
                TextEditor.IsReadOnly = true;
                ApplyTextButton.Visibility = Visibility.Collapsed;
                SetNavigation(false, false, false, false);
                return;
            }

            List<XmlTreeNode> children = ElementChildren(_node);
            List<XmlTreeNode> family = Family(_node);
            int index = family.FindIndex(n => ReferenceEquals(n, _node));
            NodeTitle.Text = _node.Kind == NodeKind.Document ? _node.DisplayLabel : $"<{_node.DisplayLabel}>";
            string attributeWord = _node.Attributes.Count == 1 ? "attribute" : "attributes";
            string childWord = children.Count == 1 ? "child" : "children";
            NodeMetadata.Text = $"lines {_node.StartLine}-{_node.EndLine}  ·  {_node.Attributes.Count} {attributeWord}  ·  {children.Count} {childWord}";
            AttributesGrid.ItemsSource = _node.Attributes.Select(a => new OrbitAttributeRow(a.Name, a.Value)).ToList();

            bool leaf = _node.Kind == NodeKind.Element && children.Count == 0;
            TextEditor.IsReadOnly = !leaf || TextEditRequested is null;
            TextEditor.Text = _node.TextValue;
            TextLabel.Text = leaf
                ? (_node.TextValue.Length == 0 ? "TEXT CONTENT  ·  empty, type to add" : "TEXT CONTENT  ·  editable")
                : "TEXT CONTENT  ·  inside child elements";
            ApplyTextButton.Visibility = leaf && TextEditRequested is not null ? Visibility.Visible : Visibility.Collapsed;
            ApplyTextButton.IsEnabled = false;
            bool hasSibling = index >= 0 && family.Count > 1;
            SetNavigation(_node.Parent?.Kind == NodeKind.Element, hasSibling,
                hasSibling, children.Count > 0);
        }
        finally { _rendering = false; }
    }

    private void SetNavigation(bool parent, bool previous, bool next, bool child)
    {
        ParentButton.IsEnabled = parent;
        PreviousButton.IsEnabled = previous;
        NextButton.IsEnabled = next;
        ChildButton.IsEnabled = child;
    }

    private static List<XmlTreeNode> ElementChildren(XmlTreeNode node)
        => StructureFilter.Apply(node.Children.Where(c => c.Kind == NodeKind.Element)).ToList();

    private static List<XmlTreeNode> Family(XmlTreeNode node)
    {
        List<XmlTreeNode> all = node.Parent?.Children
            .Where(c => c.Kind == NodeKind.Element).ToList() ?? new List<XmlTreeNode>();
        return StructureFilter.IsContainer(node) ? StructureFilter.Apply(all).ToList() : all;
    }

    private void NavigateTo(XmlTreeNode node)
    {
        SetNode(node);
        NodeActivated?.Invoke(node);
    }

    private void Parent_Click(object sender, RoutedEventArgs e)
    {
        if (_node?.Parent is { Kind: NodeKind.Element } parent) NavigateTo(parent);
    }

    private void Previous_Click(object sender, RoutedEventArgs e) => NavigateSibling(-1);
    private void Next_Click(object sender, RoutedEventArgs e) => NavigateSibling(1);

    private void Child_Click(object sender, RoutedEventArgs e)
    {
        if (_node is not null && ElementChildren(_node).FirstOrDefault() is { } child) NavigateTo(child);
    }

    private void NavigateSibling(int delta)
    {
        if (_node is null) return;
        List<XmlTreeNode> family = Family(_node);
        int index = family.FindIndex(n => ReferenceEquals(n, _node));
        if (index < 0 || family.Count < 2) return;
        int next = ((index + delta) % family.Count + family.Count) % family.Count;
        NavigateTo(family[next]);
    }

    private void PreviousPage_Click(object sender, RoutedEventArgs e) => View.PageChildren(-1);
    private void NextPage_Click(object sender, RoutedEventArgs e) => View.PageChildren(1);

    private void StructureOnly_Changed(object sender, RoutedEventArgs e)
    {
        if (IsLoaded) StructureFilter.Enabled = StructureOnlyCheck.IsChecked == true;
    }

    private void OnStructureChanged(object? sender, EventArgs e)
    {
        StructureOnlyCheck.IsChecked = StructureFilter.Enabled;
        RenderDetails();
    }

    private void AttributesGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
    {
        if (_rendering || _node is null || e.EditAction != DataGridEditAction.Commit ||
            e.Row.Item is not OrbitAttributeRow row || e.EditingElement is not TextBox box) return;
        if (box.Text == row.Value) return;
        AttributeEditRequested?.Invoke(_node, row.Name, box.Text);
        Dispatcher.BeginInvoke(RenderDetails);
    }

    private void AttributesGrid_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        DependencyObject? current = e.OriginalSource as DependencyObject;
        while (current is not null and not DataGridRow)
            current = VisualTreeHelper.GetParent(current);
        if (current is DataGridRow row)
            AttributesGrid.SelectedItem = row.Item;
    }

    private void AttributeContextMenu_Opened(object sender, RoutedEventArgs e)
    {
        bool enabled = AttributesGrid.SelectedItem is OrbitAttributeRow;
        if (sender is ContextMenu menu)
            foreach (object item in menu.Items)
                if (item is MenuItem command) command.IsEnabled = enabled;
    }

    private void CopyAttributeName_Click(object sender, RoutedEventArgs e)
        => CopySelectedAttribute(row => row.Name);

    private void CopyAttributeValue_Click(object sender, RoutedEventArgs e)
        => CopySelectedAttribute(row => row.Value);

    private void CopyAttributeAssignment_Click(object sender, RoutedEventArgs e)
        => CopySelectedAttribute(row => $"{row.Name}=\"{row.Value}\"");

    private void CopySelectedAttribute(Func<OrbitAttributeRow, string> text)
    {
        if (AttributesGrid.SelectedItem is not OrbitAttributeRow row) return;
        try { Clipboard.SetText(text(row)); }
        catch { NativeMethods.Beep(); }
    }

    private void TextEditor_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_rendering && _node is not null) ApplyTextButton.IsEnabled = TextEditor.Text != _node.TextValue;
    }

    private void ApplyText_Click(object sender, RoutedEventArgs e)
    {
        if (_node is not null && TextEditRequested?.Invoke(_node, TextEditor.Text) == true) RenderDetails();
    }

    private double _orbitZoom = 1;

    /// <summary>
    /// Zoom of the drawing: a layout scale on the view, so the rings, chips and text all grow together
    /// and the picture still fills the window (the view lays itself out in a smaller box, then is drawn
    /// enlarged). Mouse hit-testing follows the scale automatically.
    /// </summary>
    private void ZoomOrbit(double factor)
    {
        _orbitZoom = factor <= 0 ? 1 : Math.Clamp(_orbitZoom * factor, 0.5, 3.0);
        View.LayoutTransform = _orbitZoom == 1
            ? System.Windows.Media.Transform.Identity
            : new System.Windows.Media.ScaleTransform(_orbitZoom, _orbitZoom);
        UpdateChrome();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { Close(); return; }
        if (Keyboard.FocusedElement is TextBox) return;
        if (e.Key == Key.Left) { NavigateSibling(-1); e.Handled = true; }
        else if (e.Key == Key.Right) { NavigateSibling(1); e.Handled = true; }
        else if (e.Key == Key.Up) { Parent_Click(sender, e); e.Handled = true; }
        else if (e.Key == Key.Down) { Child_Click(sender, e); e.Handled = true; }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        StructureFilter.Changed -= OnStructureChanged;
        WindowPlacement.Save(this, PlacementKey);
        Live.Remove(this);
    }

    private sealed record OrbitAttributeRow(string Name, string Value);
}
