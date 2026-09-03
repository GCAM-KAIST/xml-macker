using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// Everything the Settings window can read or change. The main window implements it, so the window
/// itself holds no application state and every change is applied live and persisted by the host.
/// </summary>
internal interface ISettingsHost
{
    // General
    bool ReopenAtLaunch { get; set; }
    bool AskReopenOnClose { get; set; }
    /// <summary>"" = ask every time, "tab" = close the current tab, "all" = close all files.</summary>
    string CloseChoice { get; set; }
    void ShowTourAgain();
    void ResetEverything();

    // Appearance
    XMLMacker.Theme.Theme CurrentTheme { get; set; }
    double Zoom { get; set; }

    // Editor
    bool LineNumbers { get; set; }
    bool Minimap { get; set; }
    bool StructureOnly { get; set; }

    // Pop-outs
    bool PopoutsFloat { get; set; }

    // Learn
    IReadOnlyList<string> ChatSites { get; }
    int DefaultChatSite { get; set; }
}

/// <summary>
/// A simple, standard settings window: sections on the left, the options of the chosen section on the
/// right. Every option applies immediately, there is no OK/Apply, closing the window is enough.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly ISettingsHost _host;
    private static readonly string[] SectionNames = { "General", "Appearance", "Editor", "Pop-outs", "Learn" };

    internal SettingsWindow(ISettingsHost host)
    {
        InitializeComponent();
        _host = host;
        foreach (string s in SectionNames) Sections.Items.Add(s);
        Sections.SelectedIndex = 0;
    }

    private void Sections_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Body.Children.Clear();
        switch (Sections.SelectedItem as string)
        {
            case "General": BuildGeneral(); break;
            case "Appearance": BuildAppearance(); break;
            case "Editor": BuildEditor(); break;
            case "Pop-outs": BuildPopouts(); break;
            case "Learn": BuildLearn(); break;
        }
    }

    // ── sections ────────────────────────────────────────────────────────────────────────────────

    private void BuildGeneral()
    {
        Heading("Starting");
        Check("Reopen the files from the previous session when xml-macker starts",
              () => _host.ReopenAtLaunch, v => _host.ReopenAtLaunch = v);
        Note("Large files take a while to load, so you may prefer to start empty and open what you need.");
        Check("Ask me when I close the app whether to reopen those files next time",
              () => _host.AskReopenOnClose, v => _host.AskReopenOnClose = v);

        Heading("Closing the window with several files open");
        Combo(new[] { "Ask me every time", "Close only the current tab", "Close all files and quit" },
              _host.CloseChoice switch { "tab" => 1, "all" => 2, _ => 0 },
              i => _host.CloseChoice = i switch { 1 => "tab", 2 => "all", _ => "" });

        Heading("Help");
        ButtonRow("Show the guided tour again", _host.ShowTourAgain);

        Heading("Start over");
        Note("Forgets every setting: theme, zoom, layout, recent files, remembered choices. The app restarts.");
        ButtonRow("Reset all settings and restart…", _host.ResetEverything);
    }

    private void BuildAppearance()
    {
        Heading("Theme");
        IReadOnlyList<XMLMacker.Theme.Theme> themes = XMLMacker.Theme.Theme.All;
        int current = Math.Max(0, themes.ToList().FindIndex(t => ReferenceEquals(t, _host.CurrentTheme) || t.Id == _host.CurrentTheme.Id));
        Combo(themes.Select(t => t.DisplayName).ToArray(), current, i => _host.CurrentTheme = themes[i]);

        Heading("Zoom");
        Note("Scales the whole app, 50 % to 200 %. The slider at the bottom right of the main window does the same.");
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        var slider = new Slider { Minimum = 50, Maximum = 200, TickFrequency = 25, IsSnapToTickEnabled = false,
                                  Value = Math.Round(_host.Zoom * 100) };
        var label = new TextBlock { Text = $"{Math.Round(_host.Zoom * 100)} %", Margin = new Thickness(12, 0, 0, 0),
                                    VerticalAlignment = VerticalAlignment.Center, MinWidth = 44 };
        slider.ValueChanged += (_, e) => { label.Text = $"{Math.Round(e.NewValue)} %"; _host.Zoom = e.NewValue / 100.0; };
        row.Children.Add(slider); row.Children.Add(label);
        Body.Children.Add(row);
        ButtonRow("Back to 100 %", () => { slider.Value = 100; });
    }

    private void BuildEditor()
    {
        Heading("Source");
        Check("Show line numbers", () => _host.LineNumbers, v => _host.LineNumbers = v);
        Check("Show the minimap, the small map of the file on the right", () => _host.Minimap, v => _host.Minimap = v);

        Heading("Orbit and Hierarchy");
        Check("Structure only, hide plain value elements, show the structure", () => _host.StructureOnly, v => _host.StructureOnly = v);
    }

    private void BuildPopouts()
    {
        Heading("Panes popped out into their own window");
        Check("Pop-outs stay on top of other applications", () => _host.PopoutsFloat, v => _host.PopoutsFloat = v);
        Note("Off: a pop-out behaves like any other window. On: it floats above everything, including other programs.");
    }

    private void BuildLearn()
    {
        Heading("Chat site");
        Note("The site that opens in the Learn workspace, and where “Send Current Element to” types the element.");
        Combo(_host.ChatSites.ToArray(), Math.Clamp(_host.DefaultChatSite, 0, Math.Max(0, _host.ChatSites.Count - 1)),
              i => _host.DefaultChatSite = i);
    }

    // ── building blocks ─────────────────────────────────────────────────────────────────────────

    private void Heading(string text)
    {
        Body.Children.Add(new TextBlock
        {
            Text = text.ToUpperInvariant(),
            FontSize = 10.5,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, Body.Children.Count == 0 ? 0 : 18, 0, 6),
            Foreground = XMColor.Brush(XMColor.Text3),
        });
    }

    private void Note(string text)
    {
        Body.Children.Add(new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 11.5,
            Margin = new Thickness(0, 0, 0, 4), Foreground = XMColor.Brush(XMColor.Text2),
        });
    }

    private void Check(string text, Func<bool> get, Action<bool> set)
    {
        var cb = new CheckBox { Content = text, IsChecked = get() };
        cb.Checked += (_, _) => set(true);
        cb.Unchecked += (_, _) => set(false);
        Body.Children.Add(cb);
    }

    private void Combo(string[] items, int selected, Action<int> onChange)
    {
        var combo = new ComboBox();
        foreach (string s in items) combo.Items.Add(s);
        combo.SelectedIndex = Math.Clamp(selected, 0, Math.Max(0, items.Length - 1));
        combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) onChange(combo.SelectedIndex); };
        Body.Children.Add(combo);
    }

    private void ButtonRow(string text, Action action)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => action();
        Body.Children.Add(b);
    }
}
