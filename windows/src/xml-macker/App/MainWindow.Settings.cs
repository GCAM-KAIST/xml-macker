using System;
using System.Collections.Generic;
using System.Windows;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;
using XMLMacker.Windows;

namespace XMLMacker.App;

/// <summary>
/// The main window as the Settings window's host: every option is read from and written to the same
/// places the menus already use, and applied live, so the menus, the status bar and the window agree.
/// </summary>
public partial class MainWindow : ISettingsHost
{
    private const string ReopenRememberedKey = "xml-macker.reopenChoiceRemembered";
    private const string LearnChatKey = "xml-macker.learnChat";

    private SettingsWindow? _settingsWindow;

    private void OpenSettings()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(this) { Owner = this };
        _settingsWindow.Closed += (_, _) => { _settingsWindow = null; ValidateMenus(); };
        _settingsWindow.Show();
    }

    /// <summary>
    /// Asked once, at the real quit, when files are open and no preference has been remembered:
    /// reopen these files next time, or start empty? Never shown while Windows is logging off.
    /// </summary>
    private void AskReopenPreferenceIfNeeded()
    {
        if (_sessions.Count == 0) return;
        if (_sessionEndingReviewScheduled) return;
        if (_singleInstance is { IsFirstInstance: false }) return;
        if (AppSettings.Instance.GetBool(ReopenRememberedKey, false)) return;

        int n = _sessions.Count;
        string what = n == 1 ? "this file" : $"these {n} files";
        (int index, bool remember) = ShowAlert("Next time xml-macker starts",
            $"Open {what} again at the next start? Large files take a while to load, so you can also start empty "
            + "and open what you need.",
            new[] { "Reopen them", "Start empty", "Decide later" },
            suppressionText: "Remember my choice (change it later in Edit › Settings)");
        if (index == 2) return;

        AppSettings.Instance.SetBool(ReopenLastFilesKey, index == 0);
        if (remember) AppSettings.Instance.SetBool(ReopenRememberedKey, true);
    }

    // ── ISettingsHost ───────────────────────────────────────────────────────────────────────────

    bool ISettingsHost.ReopenAtLaunch
    {
        get => ReopenFilesAtLaunch;
        set { AppSettings.Instance.SetBool(ReopenLastFilesKey, value); ValidateMenus(); }
    }

    bool ISettingsHost.AskReopenOnClose
    {
        get => !AppSettings.Instance.GetBool(ReopenRememberedKey, false);
        set => AppSettings.Instance.SetBool(ReopenRememberedKey, !value);
    }

    string ISettingsHost.CloseChoice
    {
        get => AppSettings.Instance.GetString(CloseChoiceKey, "");
        set => AppSettings.Instance.SetString(CloseChoiceKey, value);
    }

    void ISettingsHost.ShowTourAgain() => ShowTour();

    void ISettingsHost.ResetEverything()
    {
        (int index, _) = ShowAlert("Reset xml-macker to a fresh start?",
            "Every setting will be forgotten and the app will restart. Your XML files are not touched.",
            new[] { "Reset and restart", "Cancel" });
        if (index == 0) _appDelegate.ResetAllSettingsAndRelaunch();
    }

    XMLMacker.Theme.Theme ISettingsHost.CurrentTheme
    {
        get => ThemeManager.Active;
        set { ThemeManager.Select(value); ValidateMenus(); }
    }

    double ISettingsHost.Zoom
    {
        get => XMFont.GlobalScale;
        set
        {
            ApplyGlobalScale(value);
            _suppressZoom = true;
            ZoomSlider.Value = SliderValueForScale(XMFont.GlobalScale);
            _suppressZoom = false;
        }
    }

    bool ISettingsHost.LineNumbers
    {
        get => _source.IsLineNumbersVisible;
        set { _source.SetLineNumbersVisible(value); ValidateMenus(); }
    }

    bool ISettingsHost.Minimap
    {
        get => _source.IsMinimapVisible;
        set { _source.SetMinimapVisible(value); ValidateMenus(); }
    }

    bool ISettingsHost.StructureOnly
    {
        get => StructureFilter.Enabled;
        set => StructureFilter.Enabled = value;
    }

    bool ISettingsHost.PopoutsFloat
    {
        get => PopoutsFloat;
        set => SetPopoutsFloat(value);
    }

    IReadOnlyList<string> ISettingsHost.ChatSites => LearnPane.ChatTitles;

    int ISettingsHost.DefaultChatSite
    {
        get => AppSettings.Instance.GetInt(LearnChatKey, 0);
        set { AppSettings.Instance.SetInt(LearnChatKey, value); _learn?.SelectChat(value); }
    }
}
