using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// Preview/Errors tabbed pane. A segmented Preview|Errors toggle over a no-wrap read-only
/// preview text box (dedented, caller-capped to 1 MB) and an errors table (with the shared Fix cell).
/// The Errors tab label badges the error count. Per-pane zoom mirrors the Swift <c>zoomStep</c> clamps
/// (−3…+16 → font 8…27 pt).
/// </summary>
public partial class PreviewPaneControl : UserControl
{
    private List<ParseError> _errors = new();
    private string _validationScope = "";
    private int _zoomStep;

    /// <summary>Row click / Enter → host jumps the source editor.</summary>
    public event Action<int, int>? ErrorClicked;

    /// <summary>Fix button → host applies the fix + revalidates.</summary>
    public event Action<ParseError>? FixClicked;

    public PreviewPaneControl()
    {
        InitializeComponent();

        PreviewTab.Checked += (_, _) => TabSwitched();
        ErrorsTab.Checked += (_, _) => TabSwitched();
        ErrorsList.ItemActivated += (_, item) => ErrorRowClicked(item as ParseError);
        ErrorsList.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnFixButtonClick));

        ApplyZoom();
    }

    public void SetFocusedRailMode(bool enabled)
    {
        PreviewTabStrip.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        ErrorsScroll.Visibility = Visibility.Collapsed;
        PreviewScroll.Visibility = Visibility.Visible;
        HeaderNote.Margin = enabled ? new Thickness(0) : new Thickness(184, 0, 10, 0);
    }

    private bool ErrorsActive => ErrorsTab.IsChecked == true;

    // ================= public API =================

    /// <summary>
    /// Sets the preview text (already dedented internally) and the truncation note. The 1 MB cap is
    /// applied by the caller, this only shows the "large element" note when told.
    /// </summary>
    public void SetPreviewText(string text, bool truncated)
    {
        PreviewView.Text = Dedent(text);
        if (!ErrorsActive)
            HeaderNote.Text = truncated
                ? "large element, preview shows its first 1 MB (file is fully loaded)"
                : "";
    }

    /// <summary>Stores the errors, refreshes the table and (if visible) the Errors header, and badges the tab.</summary>
    public void SetErrors(IEnumerable<ParseError> errors)
    {
        _errors = new List<ParseError>(errors);
        ErrorsList.ItemsSource = null;
        ErrorsList.ItemsSource = _errors;

        if (ErrorsActive)
        {
            HeaderNote.Text = ErrorsHeaderText();
            HeaderNote.Foreground = _errors.Count == 0 ? XMColor.Brush(XMColor.Ok) : XMColor.Brush(XMColor.Err);
        }
        ErrorsTab.Content = _errors.Count == 0 ? "Errors" : $"Errors ({_errors.Count})";
    }

    /// <summary>Sets the validation scope label; refreshes the Errors header when that tab is active.</summary>
    public void SetValidationScope(string label)
    {
        _validationScope = label ?? "";
        if (ErrorsActive)
        {
            HeaderNote.Text = ErrorsHeaderText();
            HeaderNote.Foreground = _errors.Count == 0 ? XMColor.Brush(XMColor.Ok) : XMColor.Brush(XMColor.Err);
        }
    }

    private string ErrorsHeaderText()
    {
        string scope = string.IsNullOrEmpty(_validationScope) ? "" : "  ·  scope " + _validationScope;
        if (_errors.Count == 0) return "No errors, XML is well-formed" + scope;
        string s = _errors.Count == 1 ? "" : "s";
        return $"{_errors.Count} error{s}" + scope;
    }

    private void TabSwitched()
    {
        bool errors = ErrorsActive;
        ErrorsScroll.Visibility = errors ? Visibility.Visible : Visibility.Collapsed;
        PreviewScroll.Visibility = errors ? Visibility.Collapsed : Visibility.Visible;
        if (errors)
        {
            HeaderNote.Text = ErrorsHeaderText();
            HeaderNote.Foreground = _errors.Count == 0 ? XMColor.Brush(XMColor.Ok) : XMColor.Brush(XMColor.Err);
        }
        else
        {
            HeaderNote.Text = "";
            HeaderNote.Foreground = XMColor.Brush(XMColor.Text3);
        }
    }

    // ================= zoom / theme =================

    /// <summary>Per-pane zoom in (clamped +16).</summary>
    public void ZoomIn() { _zoomStep = Math.Min(_zoomStep + 1, 16); ApplyZoom(); }

    /// <summary>Per-pane zoom out (clamped −3).</summary>
    public void ZoomOut() { _zoomStep = Math.Max(_zoomStep - 1, -3); ApplyZoom(); }

    /// <summary>Resets per-pane zoom.</summary>
    public void ZoomReset() { _zoomStep = 0; ApplyZoom(); }

    private void ApplyZoom()
    {
        var spec = XMFont.Mono(11 + _zoomStep);
        PreviewView.FontFamily = spec.Family;
        PreviewView.FontSize = spec.Size;
    }

    /// <summary>Global zoom-slider hook: reset the header font, re-apply the preview zoom, refresh the table.</summary>
    public void RebuildFonts()
    {
        HeaderNote.FontSize = XMFont.Scaled(10);
        ApplyZoom();
        var src = ErrorsList.ItemsSource;
        ErrorsList.ItemsSource = null;
        ErrorsList.ItemsSource = src;
    }

    /// <summary>Theme hook: DynamicResource brushes update on their own; re-apply the header colour.</summary>
    public void RebuildColors()
    {
        if (ErrorsActive)
            HeaderNote.Foreground = _errors.Count == 0 ? XMColor.Brush(XMColor.Ok) : XMColor.Brush(XMColor.Err);
        else
            HeaderNote.Foreground = XMColor.Brush(XMColor.Text3);
    }

    // ================= row actions =================

    private void ErrorRowClicked(ParseError? e)
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

    // ================= dedent =================

    /// <summary>
    /// Strip the longest common leading-whitespace prefix so nested XML reads flush-left.
    /// </summary>
    public static string Dedent(string s)
    {
        if (string.IsNullOrEmpty(s)) return s;
        string[] lines = s.Split('\n');
        int minIndent = int.MaxValue;
        foreach (var line in lines)
        {
            if (line.Length == 0) continue;
            int count = 0;
            while (count < line.Length && (line[count] == ' ' || line[count] == '\t')) count++;
            if (count < line.Length)   // line has non-whitespace content
            {
                if (count < minIndent) minIndent = count;
                if (minIndent == 0) break;
            }
        }
        if (minIndent <= 0 || minIndent == int.MaxValue) return s;

        var sb = new StringBuilder(s.Length);
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i];
            if (line.Length == 0) sb.Append("");
            else sb.Append(line.Substring(Math.Min(minIndent, line.Length)));
            if (i < lines.Length - 1) sb.Append('\n');
        }
        return sb.ToString();
    }
}
