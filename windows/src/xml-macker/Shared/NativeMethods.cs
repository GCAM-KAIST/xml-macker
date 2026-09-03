using System.Diagnostics;
using System.Media;
using System.Runtime.InteropServices;

namespace XMLMacker.Shared;

/// <summary>DWM system-backdrop material types (Win11).</summary>
public enum SystemBackdropType
{
    Auto = 0,
    None = 1,
    Mica = 2,          // DWMSBT_MAINWINDOW
    Acrylic = 3,       // DWMSBT_TRANSIENTWINDOW
    Tabbed = 4         // DWMSBT_TABBEDWINDOW
}

/// <summary>DWM window-corner rounding preference (Win11).</summary>
public enum WindowCornerPreference
{
    Default = 0,
    DoNotRound = 1,
    Round = 2,
    RoundSmall = 3
}

/// <summary>
/// Win32 interop for window backdrop styling (DWM), Explorer reveal, and the system beep.
/// All DWM calls are wrapped so they no-op gracefully on OS versions that lack the attribute.
/// </summary>
public static class NativeMethods
{
    // ---- DWM attribute ids ----------------------------------------------
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;   // BOOL
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;  // WindowCornerPreference
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;       // SystemBackdropType

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Sets a DWM integer window attribute; returns false (no throw) on any failure.</summary>
    public static bool TrySetWindowAttribute(IntPtr hwnd, int attribute, int value)
    {
        if (hwnd == IntPtr.Zero) return false;
        try
        {
            int v = value;
            int hr = DwmSetWindowAttribute(hwnd, attribute, ref v, sizeof(int));
            return hr == 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Enables/disables the dark-mode window frame (title bar + border).</summary>
    public static bool TrySetDarkMode(IntPtr hwnd, bool isDark)
        => TrySetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, isDark ? 1 : 0);

    /// <summary>Sets the Win11 backdrop material (Mica/Acrylic/…).</summary>
    public static bool TrySetBackdrop(IntPtr hwnd, SystemBackdropType type)
        => TrySetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, (int)type);

    /// <summary>Sets the Win11 corner rounding preference.</summary>
    public static bool TrySetCorner(IntPtr hwnd, WindowCornerPreference pref)
        => TrySetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, (int)pref);

    /// <summary>True on Windows 11 (build ≥ 22000), where the backdrop/corner attributes exist.</summary>
    public static bool IsWindows11 =>
        Environment.OSVersion.Platform == PlatformID.Win32NT
        && Environment.OSVersion.Version.Build >= 22000;

    /// <summary>
    /// "Show in Explorer", opens Explorer with <paramref name="path"/> selected
    /// (replaces macOS <c>NSWorkspace.activateFileViewerSelecting</c>).
    /// </summary>
    public static void RevealInExplorer(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
            {
                UseShellExecute = true
            });
        }
        catch
        {
            // Reveal is best-effort.
        }
    }

    /// <summary>The system beep, signals a refused action (replaces <c>NSSound.beep()</c>).</summary>
    public static void Beep() => SystemSounds.Beep.Play();
}
