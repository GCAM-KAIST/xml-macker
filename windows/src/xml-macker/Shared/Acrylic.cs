using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace XMLMacker.Shared;

/// <summary>
/// Applies the Win11 Mica/Acrylic backdrop + dark-mode window frame + rounded corners to a WPF
/// <see cref="Window"/>, the port of AppKit's <c>NSVisualEffectView</c>.
/// There is no live vibrancy in WPF, so a static backdrop is pinned (no focus-reactive recomposition,
/// reproducing the "colors are trash when active" wallpaper-bleed fix) and expose two fixed tint
/// presets, a dark one (maps to the macOS <c>.hudWindow</c> material) and a light one (maps to
/// <c>.contentBackground</c>), for the Win10 semi-opaque fallback where DWM backdrops are absent.
/// </summary>
public static class Acrylic
{
    /// <summary>Dark tint preset (≈ macOS <c>.hudWindow</c>). Semi-opaque fallback fill.</summary>
    public static readonly Color DarkTint = Color.FromArgb(0xF2, 0x1C, 0x1E, 0x24);

    /// <summary>Light tint preset (≈ macOS <c>.contentBackground</c>). Semi-opaque fallback fill.</summary>
    public static readonly Color LightTint = Color.FromArgb(0xF2, 0xF4, 0xF5, 0xF7);

    /// <summary>Returns the fallback tint for the current appearance.</summary>
    public static Color TintFor(bool isDark) => isDark ? DarkTint : LightTint;

    /// <summary>Applies the default Mica backdrop for the given appearance.</summary>
    public static void Apply(Window window, bool isDark)
        => Apply(window, isDark, SystemBackdropType.Mica);

    /// <summary>
    /// Applies <paramref name="backdrop"/> to <paramref name="window"/>. If the window's HWND is not
    /// yet realized, defers until <see cref="Window.SourceInitialized"/>. On Win10 (or any failure)
    /// this degrades to setting the dark frame where possible and is otherwise a no-op.
    /// </summary>
    public static void Apply(Window window, bool isDark, SystemBackdropType backdrop)
    {
        if (window is null) return;

        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
        {
            void Handler(object? s, EventArgs e)
            {
                window.SourceInitialized -= Handler;
                Apply(window, isDark, backdrop);
            }
            window.SourceInitialized += Handler;
            return;
        }

        // Dark/light window frame works on Win10 1809+ as well as Win11.
        NativeMethods.TrySetDarkMode(hwnd, isDark);

        if (NativeMethods.IsWindows11)
        {
            NativeMethods.TrySetCorner(hwnd, WindowCornerPreference.Round);
            NativeMethods.TrySetBackdrop(hwnd, backdrop);
        }
        // Win10: no DWM backdrop, callers that want the fallback use TintFor(isDark) as a
        // semi-opaque window background brush. This method itself no-ops the backdrop gracefully.
    }
}
