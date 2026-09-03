using System.Windows;

namespace XMLMacker.Shared;

/// <summary>
/// Manual save/restore of a window's <c>Left/Top/Width/Height</c> per window key, the WPF
/// replacement for macOS <c>setFrameAutosaveName</c>. Persisted into <see cref="AppSettings"/>
/// under <c>&lt;key&gt;.Left/.Top/.Width/.Height</c>.
///
/// Keys per spec, e.g. main window, per-pane pop-outs (<c>xml-mackerPopout-&lt;title&gt;</c>),
/// diff/orbit/find/validation. Restore applies an off-screen guard so a window saved on a
/// now-disconnected monitor is clamped back into the virtual screen.
/// </summary>
public static class WindowPlacement
{
    /// <summary>Composes the per-pane pop-out key used by the spec (<c>xml-mackerPopout-&lt;title&gt;</c>).</summary>
    public static string PopoutKey(string title) => "xml-mackerPopout-" + title;

    /// <summary>Saves the window's bounds under <paramref name="key"/>. Uses restore bounds when maximized/minimized.</summary>
    public static void Save(Window window, string key)
    {
        if (window is null || string.IsNullOrEmpty(key)) return;

        double left, top, width, height;
        var rb = window.RestoreBounds;
        if (window.WindowState != WindowState.Normal && !rb.IsEmpty)
        {
            left = rb.Left; top = rb.Top; width = rb.Width; height = rb.Height;
        }
        else
        {
            left = window.Left; top = window.Top; width = window.Width; height = window.Height;
        }

        if (double.IsNaN(left) || double.IsNaN(top) || width <= 0 || height <= 0)
            return;

        var s = AppSettings.Instance;
        s.SetDouble(key + ".Left", left);
        s.SetDouble(key + ".Top", top);
        s.SetDouble(key + ".Width", width);
        s.SetDouble(key + ".Height", height);
    }

    /// <summary>
    /// Restores previously-saved bounds for <paramref name="key"/>, clamped into the virtual
    /// screen. Returns <c>true</c> if a saved placement was found and applied.
    /// </summary>
    public static bool Restore(Window window, string key)
    {
        if (window is null || string.IsNullOrEmpty(key)) return false;

        var s = AppSettings.Instance;
        double left = s.GetDouble(key + ".Left", double.NaN);
        double top = s.GetDouble(key + ".Top", double.NaN);
        double width = s.GetDouble(key + ".Width", double.NaN);
        double height = s.GetDouble(key + ".Height", double.NaN);

        if (double.IsNaN(left) || double.IsNaN(top) || double.IsNaN(width) || double.IsNaN(height))
            return false;
        if (width <= 0 || height <= 0)
            return false;

        double vLeft = SystemParameters.VirtualScreenLeft;
        double vTop = SystemParameters.VirtualScreenTop;
        double vWidth = SystemParameters.VirtualScreenWidth;
        double vHeight = SystemParameters.VirtualScreenHeight;
        double vRight = vLeft + vWidth;
        double vBottom = vTop + vHeight;

        // Never let a restored window be larger than the virtual desktop.
        width = Math.Min(width, vWidth);
        height = Math.Min(height, vHeight);

        // Clamp so the whole window is inside the virtual screen.
        if (left + width > vRight) left = vRight - width;
        if (top + height > vBottom) top = vBottom - height;
        if (left < vLeft) left = vLeft;
        if (top < vTop) top = vTop;

        window.Left = left;
        window.Top = top;
        window.Width = width;
        window.Height = height;
        return true;
    }
}
