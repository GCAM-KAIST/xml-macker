using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>One editable attribute row bound into the ATTRIBUTES <see cref="DataGrid"/>.</summary>
public sealed class AttrRow : INotifyPropertyChanged
{
    public string Name { get; }

    private string _value;
    public string Value
    {
        get => _value;
        set { if (_value != value) { _value = value; OnPropertyChanged(); } }
    }

    public AttrRow(string name, string value) { Name = name; _value = value; }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? n = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

/// <summary>
/// The ATTRIBUTES table + single-line TEXT CONTENT editor (Swift <c>AttributesBarViewController</c>).
/// Name cells are read-only in <c>syntaxAttr</c>; Value cells are editable in <c>syntaxVal</c>. The
/// text field collapses to height 0 when the element contains element children (its text lives inside
/// those children, edit via source). An <see cref="IsEditingCell"/> guard prevents a background
/// refresh from clobbering an in-progress edit.
/// </summary>
public partial class AttributesBarControl : UserControl
{
    private readonly ObservableCollection<AttrRow> _rows = new();
    private XmlTreeNode? _node;
    private int _zoomStep;
    private bool _gridEditing;
    private string _lastCommittedText = "";

    /// <summary>Fired on a Value-column commit: (node, attrName, newValue).</summary>
    public event Action<XmlTreeNode, string, string>? OnAttributeEdit;

    /// <summary>Fired on a text-field commit: (node, newText).</summary>
    public event Action<XmlTreeNode, string>? OnTextEdit;

    public AttributesBarControl()
    {
        InitializeComponent();
        Grid.ItemsSource = _rows;

        Grid.BeginningEdit += (_, _) => _gridEditing = true;
        Grid.CellEditEnding += Grid_CellEditEnding;

        TextField.LostFocus += (_, _) => CommitText();
        TextField.KeyDown += TextField_KeyDown;
        TextField.TextChanged += (_, _) => UpdatePlaceholder();

        Loaded += (_, _) =>
        {
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            ApplyZoom();
        };
        Unloaded += (_, _) => MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;

        ApplyZoom();
    }

    /// <summary>True while a table cell is being edited OR the text field holds keyboard focus.</summary>
    public bool IsEditingCell => _gridEditing || TextField.IsKeyboardFocusWithin;

    /// <summary>Populate for <paramref name="node"/> (or clear if null).</summary>
    public void SetNode(XmlTreeNode? node)
    {
        _node = node;
        int attrCount = node?.Attributes.Count ?? 0;
        AttrTitle.Text = $"ATTRIBUTES  ({attrCount})";

        _rows.Clear();
        if (node is not null)
            foreach ((string Name, string Value) a in node.Attributes)
                _rows.Add(new AttrRow(a.Name, a.Value));

        bool hasElementChildren = node is not null && HasElementChildren(node);
        if (hasElementChildren)
        {
            // The text lives inside child elements: nothing to edit here, so the row says nothing at all.
            TextHeader.Visibility = Visibility.Collapsed;
            TextField.IsEnabled = false;
            _lastCommittedText = "";
            TextField.Text = "";
            TextRow.Visibility = Visibility.Collapsed;
            TextRow.Height = 0;
        }
        else
        {
            TextHeader.Text = "TEXT CONTENT";
            TextHeader.Visibility = Visibility.Visible;
            TextField.IsEnabled = true;
            TextRow.Visibility = Visibility.Visible;
            TextRow.Height = double.NaN; // auto (22 via TextField)
            _lastCommittedText = node?.TextValue ?? "";
            TextField.Text = _lastCommittedText;
        }
        UpdatePlaceholder();
    }

    /// <summary>Re-run <see cref="SetNode"/> only when a node is set and no cell is being edited.</summary>
    public void RefreshValuesOnly()
    {
        if (_node is not null && !IsEditingCell)
            SetNode(_node);
    }

    private static bool HasElementChildren(XmlTreeNode node)
    {
        foreach (XmlTreeNode c in node.Children)
            if (c.Kind == NodeKind.Element) return true;
        return false;
    }

    private void UpdatePlaceholder()
        => TextPlaceholder.Visibility = (TextField.IsEnabled && TextField.Text.Length == 0)
            ? Visibility.Visible : Visibility.Collapsed;

    // ── Commit routing ────────────────────────────────────────────────────────────────────────
    private void Grid_CellEditEnding(object? sender, DataGridCellEditEndingEventArgs e)
    {
        _gridEditing = false;
        if (e.EditAction != DataGridEditAction.Commit) return;
        if (!ReferenceEquals(e.Column, ColValue)) return;
        if (_node is null) return;
        if (e.Row.Item is not AttrRow row) return;
        if (e.EditingElement is not TextBox tb) return;

        string newValue = tb.Text;
        if (newValue == row.Value) return; // no-op edit
        row.Value = newValue;
        OnAttributeEdit?.Invoke(_node, row.Name, newValue);
    }

    private void TextField_KeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitText();
            e.Handled = true;
        }
    }

    private void CommitText()
    {
        if (_node is null || !TextField.IsEnabled) return;
        string text = TextField.Text;
        if (text == _lastCommittedText) return;
        _lastCommittedText = text;
        OnTextEdit?.Invoke(_node, text);
    }

    // ── Zoom ──────────────────────────────────────────────────────────────────────────────────
    public void ZoomIn() { _zoomStep = Math.Min(_zoomStep + 1, 16); ApplyZoom(); }
    public void ZoomOut() { _zoomStep = Math.Max(_zoomStep - 1, -3); ApplyZoom(); }
    public void ZoomReset() { _zoomStep = 0; ApplyZoom(); }

    private void ApplyZoom()
    {
        Grid.RowHeight = Math.Max(14, XMMetric.S(20) + _zoomStep * 2);
        Grid.FontSize = XMFont.Scaled(11.5 + _zoomStep);
        TextField.FontSize = XMFont.Scaled(12 + _zoomStep);
        TextPlaceholder.FontSize = XMFont.Scaled(12 + _zoomStep);
    }

    private void OnRebuildFonts(object? sender, EventArgs e) => ApplyZoom();
}
