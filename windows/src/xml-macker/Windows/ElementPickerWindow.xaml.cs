using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using XMLMacker.Core;

namespace XMLMacker.Windows;

/// <summary>
/// A 440×520 element-only virtualized tree picker. Choose (default /
/// Enter) + Cancel (Esc); double-click picks. Returns the chosen <see cref="XmlTreeNode"/> via
/// <see cref="ChosenNode"/> after a <c>true</c> dialog result.
/// </summary>
public partial class ElementPickerWindow : Window
{
    private readonly ObservableCollection<DiffTreeRow> _rows = new();
    private readonly HashSet<int> _expanded = new();
    private XmlTreeNode? _root;
    private bool _updating;

    /// <summary>The chosen element (valid only when the dialog returned <c>true</c>).</summary>
    public XmlTreeNode? ChosenNode { get; private set; }

    public ElementPickerWindow(XmlTreeNode root)
    {
        InitializeComponent();
        _root = root;

        TreeList.ItemsSource = _rows;
        TreeList.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnTreeButtonClick));
        TreeList.MouseDoubleClick += (_, _) => TryChoose();

        ChooseBtn.Click += (_, _) => TryChoose();

        // Expand the root and its direct element children initially.
        if (_root != null)
        {
            _expanded.Add(_root.Id);
            foreach (var c in _root.Children)
                if (c.Kind == NodeKind.Element) _expanded.Add(c.Id);
        }
        RebuildRows();
        if (_rows.Count > 0) TreeList.SelectedIndex = 0;
    }

    private static bool HasElementChild(XmlTreeNode n)
    {
        foreach (var c in n.Children) if (c.Kind == NodeKind.Element) return true;
        return false;
    }

    private void RebuildRows()
    {
        _updating = true;
        var selectedId = (TreeList.SelectedItem as DiffTreeRow)?.Node.Id;
        _rows.Clear();
        if (_root != null) Add(_root, 0);
        _updating = false;
        if (selectedId is int id)
        {
            for (int i = 0; i < _rows.Count; i++)
                if (_rows[i].Node.Id == id) { TreeList.SelectedIndex = i; break; }
        }
    }

    private void Add(XmlTreeNode node, int depth)
    {
        bool hasKids = HasElementChild(node);
        bool expanded = _expanded.Contains(node.Id);
        _rows.Add(new DiffTreeRow(node, depth, hasKids, expanded));
        if (expanded && hasKids)
            foreach (var c in node.Children)
                if (c.Kind == NodeKind.Element) Add(c, depth + 1);
    }

    private void OnTreeButtonClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is Button b && (b.Tag as string) == "disc" && b.DataContext is DiffTreeRow row)
        {
            if (!row.HasChildren) return;
            if (_expanded.Contains(row.Node.Id)) _expanded.Remove(row.Node.Id);
            else _expanded.Add(row.Node.Id);
            RebuildRows();
            e.Handled = true;
        }
    }

    private void TryChoose()
    {
        if (_updating) return;
        if (TreeList.SelectedItem is not DiffTreeRow row) return;
        ChosenNode = row.Node;
        DialogResult = true;
        Close();
    }
}
