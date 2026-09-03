using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

public partial class ErrorsPaneControl : UserControl
{
    private List<ParseError> _errors = new();
    private string _scope = string.Empty;

    public event Action<int, int>? ErrorClicked;
    public event Action<ParseError>? FixClicked;
    public event Action<int>? ErrorCountChanged;

    public ErrorsPaneControl()
    {
        InitializeComponent();
        ErrorsList.ItemActivated += (_, item) => Activate(item as ParseError);
        ErrorsList.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnFixClicked));
        RefreshHeader();
    }

    public void SetErrors(IEnumerable<ParseError> errors)
    {
        _errors = new List<ParseError>(errors);
        ErrorsList.ItemsSource = null;
        ErrorsList.ItemsSource = _errors;
        RefreshHeader();
        ErrorCountChanged?.Invoke(_errors.Count);
    }

    public void SetValidationScope(string label)
    {
        _scope = label ?? string.Empty;
        RefreshHeader();
    }

    private void RefreshHeader()
    {
        string scope = _scope.Length == 0 ? string.Empty : $"  ·  scope {_scope}";
        HeaderNote.Text = _errors.Count == 0
            ? "No errors, XML is well-formed" + scope
            : $"{_errors.Count} error{(_errors.Count == 1 ? string.Empty : "s")}, click a row to jump to it" + scope;
        HeaderNote.Foreground = XMColor.Brush(_errors.Count == 0 ? XMColor.Ok : XMColor.Err);
    }

    private void Activate(ParseError? error)
    {
        if (error is not null) ErrorClicked?.Invoke(error.Line, error.Column);
    }

    private void OnFixClicked(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is Button button && button.DataContext is ParseError error && error.Fix is not null)
        {
            FixClicked?.Invoke(error);
            e.Handled = true;
        }
    }
}
