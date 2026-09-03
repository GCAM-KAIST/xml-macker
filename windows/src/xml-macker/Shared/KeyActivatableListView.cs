using System.Windows.Controls;
using System.Windows.Input;

namespace XMLMacker.Shared;

/// <summary>
/// A <see cref="ListView"/> that raises <see cref="ItemActivated"/> when Enter is pressed on
/// the selected row or double-clicks a row. Shared by the Validation window,
/// Find results table, and the Preview pane's error list.
/// </summary>
public class KeyActivatableListView : ListView
{
    /// <summary>Raised with the activated item (the current <see cref="Selector.SelectedItem"/>).</summary>
    public event EventHandler<object?>? ItemActivated;

    public KeyActivatableListView()
    {
        MouseDoubleClick += OnMouseDoubleClick;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Enter && SelectedItem is not null)
        {
            RaiseItemActivated(SelectedItem);
            e.Handled = true;
            return;
        }
        base.OnKeyDown(e);
    }

    private void OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (SelectedItem is not null)
            RaiseItemActivated(SelectedItem);
    }

    /// <summary>Raises <see cref="ItemActivated"/> for <paramref name="item"/>.</summary>
    protected void RaiseItemActivated(object? item) => ItemActivated?.Invoke(this, item);
}
