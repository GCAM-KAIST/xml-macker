using System.Windows;
using XMLMacker.Shared;

namespace XMLMacker.Theme;

/// <summary>
/// The active-theme slot + persistence, and the runtime dictionary swap. 1:1 port of the Swift
/// <c>ThemeManager</c> semantics, adapted to WPF's <see cref="ResourceDictionary"/> merge model:
/// <see cref="Select(Theme)"/> removes the previous theme dictionary from
/// <see cref="Application.Resources"/>'s merged dictionaries and adds the new one, so every
/// <c>{DynamicResource XM.*}</c> brush updates automatically (this replaces BOTH the Swift
/// computed-property reads AND the manual <c>rebuildColors()</c> fan-out). Perf caches on the
/// editor hot path that cannot observe DynamicResource subscribe to <see cref="ThemeChanged"/>.
/// </summary>
public static class ThemeManager
{
    private const string PrefsKey = "xml-macker.themeID";

    private static ResourceDictionary? _mergedThemeDict;

    /// <summary>The currently active theme. Initialized by <see cref="Initialize"/>.</summary>
    public static Theme Active { get; private set; } = Theme.AuroraDark;

    /// <summary>
    /// Raised after a theme swap so perf-cached brushes/pens (viewport colorizer, highlight layer)
    /// invalidate. DynamicResource-bound brushes do NOT need this, they update on their own.
    /// </summary>
    public static event EventHandler? ThemeChanged;

    /// <summary>
    /// Resolve the persisted theme (default <c>aurora-dark</c>) and merge its dictionary. Call once
    /// at startup, before the first window is shown.
    /// </summary>
    public static void Initialize()
    {
        string id = AppSettings.Instance.GetString(PrefsKey, Theme.AuroraDark.Id);
        Theme theme = Theme.ById(id) ?? Theme.AuroraDark;
        Active = theme;
        MergeDictionary(theme);
    }

    /// <summary>
    /// Make <paramref name="theme"/> active: swap the merged dictionary, persist the id under
    /// <c>XMLMacker.themeID</c>, and raise <see cref="ThemeChanged"/>.
    /// </summary>
    public static void Select(Theme theme)
    {
        Active = theme;
        AppSettings.Instance.SetString(PrefsKey, theme.Id);
        MergeDictionary(theme);
        ThemeChanged?.Invoke(null, EventArgs.Empty);
    }

    private static void MergeDictionary(Theme theme)
    {
        Application? app = Application.Current;
        if (app is null) return;

        var dict = new ResourceDictionary { Source = ResourceUri(theme.Id) };
        if (_mergedThemeDict is not null)
            app.Resources.MergedDictionaries.Remove(_mergedThemeDict);
        app.Resources.MergedDictionaries.Add(dict);
        _mergedThemeDict = dict;
    }

    private static Uri ResourceUri(string id)
        => new($"/xml-macker;component/Theme/Themes/{FileStem(id)}.xaml", UriKind.Relative);

    private static string FileStem(string id) => id switch
    {
        "aurora-dark" => "AuroraDark",
        "light" => "Light",
        "one-dark" => "OneDark",
        "solarized-dark" => "SolarizedDark",
        "dracula" => "Dracula",
        "hacker-green" => "HackerGreen",
        _ => "AuroraDark",
    };
}
