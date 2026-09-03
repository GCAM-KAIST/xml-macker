using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

public partial class DetailsRailControl : UserControl
{
    private const string PreferenceKey = "xml-macker.activeDetailSection";
    private readonly Dictionary<string, UIElement> _views;
    private readonly Dictionary<string, ToggleButton> _buttons = new();
    private readonly Border _badge;
    private string _selected = "Inspector";

    public UIElement HeaderAccessory { get; }
    public string SelectedSection => _selected;
    public event Action<string>? SectionChanged;

    public DetailsRailControl(UIElement inspector, UIElement chart, PreviewPaneControl preview, UIElement errors)
    {
        InitializeComponent();
        preview.SetFocusedRailMode(true);
        _views = new(StringComparer.Ordinal)
        {
            ["Inspector"] = inspector,
            ["Chart"] = chart,
            ["Preview"] = preview,
            ["Errors"] = errors,
        };

        var grid = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch };
        for (int i = 0; i < 4; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        string[] titles = { "Inspector", "Chart", "Preview", "Errors" };
        for (int i = 0; i < titles.Length; i++)
        {
            string key = titles[i];
            var button = new RadioButton
            {
                Content = key == "Chart" ? "Chart (beta)" : key,
                GroupName = "DetailsRail",
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
                Padding = new Thickness(5, 0, 5, 0),
                VerticalAlignment = VerticalAlignment.Center,
                FontSize = 11,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Cursor = System.Windows.Input.Cursors.Hand,
                Template = SegmentTemplate(),
            };
            button.Checked += (_, _) => ShowSection(key, true);
            Grid.SetColumn(button, i);
            grid.Children.Add(button);
            _buttons[key] = button;
        }

        _badge = new Border
        {
            Width = 8,
            Height = 8,
            CornerRadius = new CornerRadius(4),
            Background = XMColor.Brush(XMColor.Err),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -2, 3, 0),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        Grid.SetColumn(_badge, 3);
        grid.Children.Add(_badge);
        HeaderAccessory = grid;

        string saved = AppSettings.Instance.GetString(PreferenceKey, "Inspector");
        if (!_views.ContainsKey(saved)) saved = "Inspector";
        _buttons[saved].IsChecked = true;
        ShowSection(saved, false);
    }

    public void ShowSection(string title, bool persist = true)
    {
        if (!_views.TryGetValue(title, out UIElement? view)) return;
        _selected = title;
        if (_buttons.TryGetValue(title, out ToggleButton? button) && button.IsChecked != true)
            button.IsChecked = true;
        ContentHost.Content = view;
        if (persist) AppSettings.Instance.SetString(PreferenceKey, title);
        SectionChanged?.Invoke(title);
    }

    public void SetErrorCount(int count) => _badge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;

    private static ControlTemplate SegmentTemplate()
    {
        const string xaml = "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='RadioButton'><Border x:Name='b' CornerRadius='6' Padding='{TemplateBinding Padding}' Background='Transparent'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='b' Property='Background' Value='{DynamicResource XM.lineHighlight}'/><Setter Property='Foreground' Value='{DynamicResource XM.accent}'/><Setter Property='FontWeight' Value='SemiBold'/></Trigger><Trigger Property='IsChecked' Value='False'><Setter Property='Foreground' Value='{DynamicResource XM.text2}'/></Trigger><Trigger Property='IsMouseOver' Value='True'><Setter Property='Foreground' Value='{DynamicResource XM.text}'/></Trigger></ControlTemplate.Triggers></ControlTemplate>";
        return (ControlTemplate)System.Windows.Markup.XamlReader.Parse(xaml);
    }
}
