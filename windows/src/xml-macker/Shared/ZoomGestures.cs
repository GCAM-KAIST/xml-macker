using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace XMLMacker.Shared;

/// <summary>
/// The two zoom gestures every window understands, Ctrl + mouse wheel, and Ctrl with + / − / 0, each
/// driving the zoom of THE WINDOW THEY ARE USED IN, handed in by that window (a pane's own zoom, the
/// Diff text, the chart, the Orbit drawing). The whole-application zoom is the slider at the bottom
/// right of the main window (and Settings › Appearance); the gestures never touch it.
/// </summary>
public static class ZoomGestures
{
    /// <summary>One wheel notch or one key press: 10 % bigger or smaller.</summary>
    public const double Step = 1.1;

    /// <summary>
    /// The simplest window-local zoom, for windows made of ordinary controls (lists, text boxes,
    /// buttons): a layout scale on the window content, so everything inside grows or shrinks together.
    /// </summary>
    public static void AttachContentZoom(Window window)
    {
        double zoom = 1;
        void Apply(double factor)
        {
            zoom = factor <= 0 ? 1 : Math.Clamp(zoom * factor, 0.5, 3.0);
            if (window.Content is FrameworkElement root)
                root.LayoutTransform = zoom == 1 ? Transform.Identity : new ScaleTransform(zoom, zoom);
        }
        Attach(window, () => Apply(Step), () => Apply(1 / Step), () => Apply(0));
    }

    /// <summary>Wheel and keys, all three driving one window-local zoom.</summary>
    public static void Attach(Window window, Action zoomIn, Action zoomOut, Action reset)
    {
        AttachWheel(window, _ => zoomIn(), _ => zoomOut());
        AttachKeys(window, zoomIn, zoomOut, reset);
    }

    /// <summary>
    /// Ctrl + wheel up = larger, Ctrl + wheel down = smaller; wheel without Ctrl is untouched. The
    /// element under the pointer is passed along so a window with several panes can zoom just that pane.
    /// </summary>
    public static void AttachWheel(Window window, Action<object?> zoomIn, Action<object?> zoomOut)
    {
        window.PreviewMouseWheel += (_, e) =>
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) == 0 || e.Delta == 0) return;
            if (e.Delta > 0) zoomIn(e.OriginalSource); else zoomOut(e.OriginalSource);
            e.Handled = true;
        };
    }

    /// <summary>Ctrl + / Ctrl − (main row or keypad) and Ctrl 0 back to normal.</summary>
    public static void AttachKeys(Window window, Action zoomIn, Action zoomOut, Action reset)
    {
        window.PreviewKeyDown += (_, e) =>
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
            switch (e.Key)
            {
                case Key.OemPlus: case Key.Add: zoomIn(); e.Handled = true; break;
                case Key.OemMinus: case Key.Subtract: zoomOut(); e.Handled = true; break;
                case Key.D0: case Key.NumPad0: reset(); e.Handled = true; break;
            }
        };
    }
}
