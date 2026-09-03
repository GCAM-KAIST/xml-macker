using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.App;

/// <summary>
/// The non-UI half of the AppKit <c>AppDelegate</c>: the
/// <b>Open…</b> file dialog, the self-managed <b>Open Recent</b> submenu glue over
/// <see cref="RecentFiles"/>, <b>Reset All Settings</b> (the confirm dialog with the exact spec
/// strings, then <see cref="AppSettings.ResetAll"/> + <see cref="Relauncher"/>), the
/// <c>pendingURL</c> hand-off from <see cref="App.PendingOpenPath"/>, and the single-instance
/// path-forwarding hook. The actual file open funnels through the <c>loadFile</c> callback the
/// window supplies (the Swift <c>mainWindowController.loadFile(url:)</c>). The menu bar itself lives
/// in <c>MainWindow.xaml</c>; this service only fills the Open Recent submenu.
/// </summary>
public sealed class AppDelegateService
{
    // Exact on-screen strings. Note the deliberate
    // "xml-macker" spelling in the reset alert vs "XML Marker" elsewhere, reproduced verbatim.
    private const string OpenDialogTitle = "Choose an XML file";
    private const string NoRecentFiles = "No Recent Files";
    private const string ClearMenu = "Clear Menu";
    private const string ResetTitle = "Reset xml-macker to a fresh start?";
    private const string ResetBody =
        "Theme, layout, workspace mode, remembered choices, recent files and window positions all "
        + "return to defaults, and the app restarts. Your XML files are not touched.";
    private const string ResetConfirmButton = "Reset and Restart";
    private const string CancelButton = "Cancel";

    private readonly Action<string> _loadFile;
    private MenuItem? _recentMenu;
    private bool _pendingConsumed;

    /// <param name="loadFile">The window's single file-open funnel (Swift
    /// <c>mainWindowController.loadFile(url:)</c>). Called with an absolute path on the UI thread.</param>
    public AppDelegateService(Action<string> loadFile)
        => _loadFile = loadFile ?? throw new ArgumentNullException(nameof(loadFile));

    // ── Open… ───────────────────────────────────────────────────────────────────────────

    /// <summary>Show the base Open panel (any file, message "Choose an XML file") and, on OK, load
    /// the chosen file. Recording into Open Recent happens inside <c>loadFile</c>, per spec.</summary>
    public void OpenFile(Window? owner = null)
    {
        var dlg = new OpenFileDialog
        {
            Title = OpenDialogTitle,
            Multiselect = true,
            CheckFileExists = true,
            Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*",
            FilterIndex = 2,   // default to any file, the AppKit panel used allowedContentTypes = []
        };

        bool ok = owner is not null ? dlg.ShowDialog(owner) == true : dlg.ShowDialog() == true;
        if (ok)
            foreach (string file in dlg.FileNames)
                if (!string.IsNullOrEmpty(file)) _loadFile(file);
    }

    // ── Open Recent (self-managed) ────────────────────────────────────────────────────────

    /// <summary>Fill (and remember) the Open Recent submenu. Call once at build, or on each
    /// <c>SubmenuOpened</c> to refresh. Empty ⇒ a single disabled "No Recent Files"; otherwise one
    /// item per path (title = file name, tooltip = full path) then a separator and "Clear Menu".</summary>
    public void PopulateRecentMenu(MenuItem openRecentMenu)
    {
        _recentMenu = openRecentMenu ?? throw new ArgumentNullException(nameof(openRecentMenu));
        RebuildRecentMenu();
    }

    private void RebuildRecentMenu()
    {
        if (_recentMenu is null) return;
        _recentMenu.Items.Clear();

        var paths = RecentFiles.All;
        if (paths.Count == 0)
        {
            _recentMenu.Items.Add(new MenuItem { Header = NoRecentFiles, IsEnabled = false });
            return;
        }

        foreach (string path in paths)
        {
            string capture = path;
            var item = new MenuItem
            {
                Header = Path.GetFileName(path),
                ToolTip = path,          // full path disambiguates same-named files
                Tag = path,
            };
            item.Click += (_, _) => OpenRecentItem(capture);
            _recentMenu.Items.Add(item);
        }

        _recentMenu.Items.Add(new Separator());
        var clear = new MenuItem { Header = ClearMenu };
        clear.Click += (_, _) => { RecentFiles.Clear(); RebuildRecentMenu(); };
        _recentMenu.Items.Add(clear);
    }

    private void OpenRecentItem(string path)
    {
        // Missing file → beep + prune + rebuild (Swift openRecentItem), and do NOT try to open it.
        if (!RecentFiles.PruneMissing(path))
        {
            RebuildRecentMenu();
            return;
        }
        _loadFile(path);
    }

    // ── Reset All Settings ────────────────────────────────────────────────────────────────

    /// <summary>Ask for confirmation before the main window reviews unsaved documents.</summary>
    public bool ConfirmResetAllSettings(Window? owner = null)
        => ConfirmReset(owner);

    /// <summary>Wipe persisted settings and relaunch after the main window has finished its
    /// unsaved-document review.</summary>
    public void ResetAllSettingsAndRelaunch()
    {
        AppSettings.Instance.ResetAll();
        Relauncher.RelaunchAndExit();
    }

    private static bool ConfirmReset(Window? owner)
    {
        var dialog = new Window
        {
            Title = ResetTitle,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner is not null
                ? WindowStartupLocation.CenterOwner
                : WindowStartupLocation.CenterScreen,
            Owner = owner,
            ShowInTaskbar = false,
            MinWidth = 420,
        };
        dialog.SetResourceReference(Control.BackgroundProperty, XMColor.Bg);
        dialog.SetResourceReference(Control.ForegroundProperty, XMColor.Text);

        var root = new StackPanel { Margin = new Thickness(20) };

        var heading = new TextBlock
        {
            Text = ResetTitle,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10),
        };
        XMFont.UiHeader.ApplyTo(heading);
        heading.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text);

        var body = new TextBlock
        {
            Text = ResetBody,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420,
            Margin = new Thickness(0, 0, 0, 18),
        };
        XMFont.UiBody.ApplyTo(body);
        body.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text2);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };

        var cancel = new Button
        {
            Content = CancelButton,
            IsCancel = true,
            MinWidth = 90,
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(0, 0, 8, 0),
        };
        var confirm = new Button
        {
            Content = ResetConfirmButton,
            IsDefault = true,
            MinWidth = 130,
            Padding = new Thickness(12, 4, 12, 4),
        };

        bool result = false;
        cancel.Click += (_, _) => { result = false; dialog.Close(); };
        confirm.Click += (_, _) => { result = true; dialog.Close(); };

        buttons.Children.Add(cancel);
        buttons.Children.Add(confirm);
        root.Children.Add(heading);
        root.Children.Add(body);
        root.Children.Add(buttons);
        dialog.Content = root;

        dialog.ShowDialog();
        return result;
    }

    // ── Pending open path (pre-window file hand-off) ─────────────────────────────────────

    /// <summary>Return (once) the command-line file path buffered before the window existed
    /// (<see cref="App.PendingOpenPath"/>). Subsequent calls return <c>null</c>.</summary>
    public string? ConsumePendingOpenPath()
    {
        if (_pendingConsumed) return null;
        _pendingConsumed = true;
        string? path = App.PendingOpenPath;
        return !string.IsNullOrEmpty(path) && File.Exists(path) ? path : null;
    }

    // ── Single-instance forwarding ────────────────────────────────────────────────────────

    /// <summary>Wire a second launch's forwarded file path to <c>loadFile</c>, marshalled onto the UI
    /// thread. <see cref="SingleInstance.PathReceived"/> fires on a pipe thread, so it is dispatched.</summary>
    public void WireSingleInstance(SingleInstance instance, Dispatcher dispatcher)
    {
        if (instance is null || dispatcher is null) return;
        instance.PathReceived += path =>
        {
            if (string.IsNullOrEmpty(path)) return;
            dispatcher.InvokeAsync(() =>
            {
                if (File.Exists(path)) _loadFile(path);
            });
        };
    }
}
