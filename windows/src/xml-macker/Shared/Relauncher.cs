using System.Diagnostics;
using System.Windows;

namespace XMLMacker.Shared;

/// <summary>
/// Restarts the application, the Windows port of the AppKit "Reset All Settings" relaunch
///. Spawns a detached helper that waits ~1 s (the shortest reliable
/// <c>timeout</c>) then starts a fresh copy of the exe, and shuts the current process down, 
/// replacing the POSIX <c>/bin/sh -c "sleep 0.6; open …"</c> trick.
/// </summary>
public static class Relauncher
{
    /// <summary>Launches a delayed relaunch helper, then shuts down this application.</summary>
    public static void RelaunchAndExit()
    {
        try
        {
            string? exe = Process.GetCurrentProcess().MainModule?.FileName;
            if (!string.IsNullOrEmpty(exe))
            {
                // timeout waits, then start launches a new detached instance.
                var psi = new ProcessStartInfo("cmd.exe",
                    $"/c timeout /t 1 /nobreak >nul & start \"\" \"{exe}\"")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(psi);
            }
        }
        catch
        {
            // If the helper can't spawn, still shut down: a reset or restart was requested.
        }

        if (Application.Current is not null)
            Application.Current.Shutdown();
        else
            Environment.Exit(0);
    }
}
