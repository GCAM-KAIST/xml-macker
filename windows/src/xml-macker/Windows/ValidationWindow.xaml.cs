using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// Standalone window listing XML parse errors + warnings from the most recent parse.
/// Each row is click / Enter-to-jump; some rows carry a one-click Fix. Includes Re-validate and a
/// static explainer of what the syntax checker covers.
/// </summary>
public partial class ValidationWindow : Window
{
    private const string PlacementKey = "xml-mackerValidation";

    private const string HintText =
        "Live check is scoped to the selected element's parent: mismatched or missing closing tags, "
        + "stray closes, unquoted or duplicate attributes, unescaped '&', malformed tags. Click or press "
        + "Enter on a row to jump to its line; rows with a Fix button can be repaired in one click "
        + "(Ctrl+Z undoes). Tag-name typos that are still valid XML (<peiod> vs <period>) need schema "
        + "(XSD/DTD) validation, point the app at a GCAM schema to enable that someday.";

    private List<ParseError> _errors = new();

    /// <summary>Row clicked / Enter → host scrolls source editor + selects the containing node.</summary>
    public event Action<int, int>? ErrorClicked;

    /// <summary>Fix button → host applies <c>error.Fix</c> and re-validates.</summary>
    public event Action<ParseError>? FixClicked;

    /// <summary>Re-validate button.</summary>
    public event Action? RevalidateRequested;

    /// <summary>Window closed.</summary>
    public event Action? Closed2;

    public ValidationWindow()
    {
        InitializeComponent();
        ZoomGestures.AttachContentZoom(this);   // Ctrl + wheel / Ctrl +/- zoom this window only   // Ctrl + wheel, Ctrl +/-, Ctrl 0
        HintLabel.Text = HintText;

        RevalidateBtn.Click += (_, _) => RevalidateRequested?.Invoke();
        ErrorsList.ItemActivated += (_, item) => FireRow(item as ParseError);
        ErrorsList.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnFixButtonClick));

        SourceInitialized += (_, _) => WindowPlacement.Restore(this, PlacementKey);
        Closed += (_, _) => { WindowPlacement.Save(this, PlacementKey); Closed2?.Invoke(); };

        SetErrors(new List<ParseError>());
    }

    /// <summary>Store the errors, refresh the table and the status line.</summary>
    public void SetErrors(IEnumerable<ParseError> errors)
    {
        _errors = new List<ParseError>(errors);
        ErrorsList.ItemsSource = null;
        ErrorsList.ItemsSource = _errors;

        if (_errors.Count == 0)
        {
            StatusLabel.Text = "No errors, XML is well-formed.";
            StatusLabel.Foreground = XMColor.Brush(XMColor.Ok);
        }
        else
        {
            string s = _errors.Count == 1 ? "" : "s";
            StatusLabel.Text = $"{_errors.Count} error{s}";
            StatusLabel.Foreground = XMColor.Brush(XMColor.Err);
        }
    }

    private void FireRow(ParseError? e)
    {
        if (e == null) return;
        ErrorClicked?.Invoke(e.Line, e.Column);
    }

    private void OnFixButtonClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is Button b && b.DataContext is ParseError pe && pe.Fix != null)
        {
            FixClicked?.Invoke(pe);
            e.Handled = true;
        }
    }
}
