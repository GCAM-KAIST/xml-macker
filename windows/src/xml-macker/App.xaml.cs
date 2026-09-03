using System;
using System.IO;
using System.Windows;
using XMLMacker.Theme;

namespace XMLMacker.App;

/// <summary>
/// WPF <see cref="Application"/> entry point. Mirrors the macOS <c>main.swift</c> +
/// <c>AppDelegate.applicationDidFinishLaunching</c> bootstrap:
/// merges the active theme <see cref="ResourceDictionary"/>, restores the global zoom,
/// buffers a command-line file path (<see cref="PendingOpenPath"/>) for the main window to
/// pick up once it is constructed, and defers to <c>StartupUri</c> for window creation.
/// <para>
/// <c>ShutdownMode=OnMainWindowClose</c> reproduces
/// <c>applicationShouldTerminateAfterLastWindowClosed == true</c>.
/// </para>
/// </summary>
public partial class App : Application
{
    /// <summary>
    /// A file path passed on the command line (Finder/Explorer double-click, CLI, or file
    /// association) that arrived before the main window existed. The main window reads and
    /// clears this once it is ready. Analog of the Swift <c>pendingURL</c> buffer.
    /// </summary>
    public static string? PendingOpenPath { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        // Buffer the first existing file path from the command line (skip switches),
        // mirroring the AppDelegate's CommandLine.arguments.dropFirst() scan.
        foreach (string arg in e.Args)
        {
            if (!string.IsNullOrEmpty(arg) && File.Exists(arg))
            {
                PendingOpenPath = arg;
                break;
            }
        }

        // ── Last-resort error net ────────────────────────────────────────────────────────────────
        // Without these three handlers a single stray exception anywhere in the UI terminates the
        // whole editor with the bare Windows "has stopped working" box and no managed message, which
        // is exactly how the minimap-magnifier crash was able to destroy unsaved work silently.
        // Log everything (Diag writes to %TEMP%\xmleditorx.log and swallows its own failures), explain it
        // in plain words on screen, and keep the editor alive so the document can still be saved.
        DispatcherUnhandledException += (_, args) =>
        {
            Core.Diag.Log("UI exception: " + args.Exception);
            MessageBox.Show(
                args.Exception.Message,
                "xml-macker hit a problem, your file is still open",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            args.Handled = true;
        };

        AppDomain.CurrentDomain.UnhandledException +=
            (_, args) => Core.Diag.Log("Fatal: " + args.ExceptionObject);

        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Core.Diag.Log("Background task exception: " + args.Exception);
            args.SetObserved();
        };

        // Merge the persisted (or default aurora-dark) theme dictionary BEFORE the
        // StartupUri window is created so every DynamicResource resolves on first render.
        ThemeManager.Initialize();

        // Restore the global zoom multiplier (0.5..2.0) if one was persisted.
        MetricsScaleService.Instance.Load();

        base.OnStartup(e);
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        base.OnSessionEnding(e);

        // Windows requires this decision to return promptly. Dirty-document review is queued
        // after the operating-system request has been canceled, so no save or dialog runs inside
        // the shutdown notification itself.
        if (MainWindow is XMLMacker.App.MainWindow window && window.ProtectSessionEnding())
            e.Cancel = true;
    }
}
