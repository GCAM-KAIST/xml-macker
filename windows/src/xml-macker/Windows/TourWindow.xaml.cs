using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace XMLMacker.Windows;

public sealed record TourPage(string Title, IReadOnlyList<string> Lines, IReadOnlyList<string> Anchors);

public partial class TourWindow : Window
{
    public static readonly IReadOnlyList<TourPage> Pages = new[]
    {
        new TourPage("Four layouts", new[]
        {
            "Simple: the tree, the source editor and the Subtags table.",
            "Inspect: adds the details rail with Inspector, Chart, Preview, and Errors.",
            "Full: every pane at once.",
            "Learn: an AI chat beside your file. Select source text or right-click an element and choose Define in Learn.",
            "In Learn, Folder shows the file in File Explorer to drag it into the chat, and Copy File copies the whole file.",
            "Drag what you select in the source, or a row of the tree, straight into the chat box, into the file itself, or into any other program.",
        }, new[] { "workspace" }),
        new TourPage("The map beside the source", new[]
        {
            "The left half snaps to elements at the current level, so a click hops element by element.",
            "The right half moves freely by line. Hover for a magnifier; click or drag to go there.",
            "The small x above the map hides it, and View, Show Minimap (Ctrl+Shift+M) brings it back.",
        }, new[] { "minimap" }),
        new TourPage("Diff", new[]
        {
            "Compare any two files side by side (browse for either one), walk the differences by block or line by line, and copy either way. Undo Copy puts things back.",
            "Click the file name at the top of the Diff tree to switch to the other file's tree.",
        }, new[] { "diff" }),
        new TourPage("Search", new[]
        {
            "Type in the search box and press Enter to jump to the next match.",
            "The magnifier opens Find and Replace with Find All, Replace All, whole word, and element scope.",
        }, new[] { "search", "find" }),
        new TourPage("The highlighter", new[]
        {
            "Click the highlighter (or Ctrl+H) and the pointer becomes a marker: drag over words to mark them, click a line to mark the whole line, drag again to erase. Esc or the button stops.",
            "The small chevron picks the colour or the eraser and can remove every mark; the down arrow jumps from mark to mark. Marks are remembered per file and follow your edits.",
        }, new[] { "highlight" }),
        new TourPage("Orbit", new[] { "The selected element sits in the centre, its children orbit around it, and siblings arc above. Use the right panel to move or edit, and Structure only to hide plain values." }, new[] { "orbit" }),
        new TourPage("The details rail", new[]
        {
            "Inspector: editable attributes and text.",
            "Chart: repeated numbers drawn over years or across siblings.",
            "Preview: the element's raw XML.",
            "Errors: XML problems with one-click fixes; a red badge shows the count.",
        }, new[] { "details" }),
        new TourPage("Zoom", new[]
        {
            "The bottom-right slider scales the whole app from fifty percent to two hundred percent.",
            "Ctrl + mouse wheel, or Ctrl with + and \u2212, zoom only the pane under the pointer; Ctrl 0 puts it back. Diff, Orbit and chart windows zoom on their own the same way.",
        }, new[] { "zoom" }),
        new TourPage("You're set", new[]
        {
            "Drop any XML file onto the window to open it. Right-click almost anything.",
            "Every option lives in Edit \u203a Settings\u2026, and this tour is always available from Help.",
        }, Array.Empty<string>()),
    };

    private readonly Window _host;
    private readonly Func<string, IReadOnlyList<FrameworkElement>> _anchors;
    private int _index;

    public TourWindow(Window host, Func<string, IReadOnlyList<FrameworkElement>> anchors)
    {
        InitializeComponent();
        _host = host;
        _anchors = anchors;
        Owner = host;
        Loaded += (_, _) => { PositionOverHost(); RenderPage(); Overlay.Focus(); };
        host.LocationChanged += HostChanged;
        host.SizeChanged += HostChanged;
        PreviewKeyDown += OnPreviewKeyDown;
        Closed += (_, _) =>
        {
            host.LocationChanged -= HostChanged;
            host.SizeChanged -= HostChanged;
            host.Activate();
        };
    }

    private void HostChanged(object? sender, EventArgs e)
    {
        PositionOverHost();
        RenderPage();
    }

    private void PositionOverHost()
    {
        // Cover the host's CLIENT area exactly, wherever it really is on screen.
        //
        // The old code used _host.Left / _host.Top. For a MAXIMIZED window WPF keeps the *restored*
        // position in those two properties, so the overlay was laid over where the window would be if it
        // were not maximized, partly off screen, and every card measured from that wrong origin drifted
        // toward the middle of the monitor. Going through screen coordinates avoids both that and the
        // title-bar offset, and PointFromScreen/PointToScreen handle the 125 % display scaling.
        try
        {
            PresentationSource? src = PresentationSource.FromVisual(_host);
            Point deviceOrigin = _host.PointToScreen(new Point(0, 0));
            Point dipOrigin = src?.CompositionTarget is not null
                ? src.CompositionTarget.TransformFromDevice.Transform(deviceOrigin)
                : deviceOrigin;
            Left = dipOrigin.X;
            Top = dipOrigin.Y;
        }
        catch
        {
            Left = _host.Left;
            Top = _host.Top;
        }
        Width = Math.Max(1, _host.ActualWidth);
        Height = Math.Max(1, _host.ActualHeight);
    }

    private void RenderPage()
    {
        if (!IsLoaded) return;
        TourPage page = Pages[_index];
        TourTitle.Text = page.Title;
        TourBody.Text = page.Lines.Count == 1 ? page.Lines[0] : string.Join("\n\n", page.Lines.Select(line => "•  " + line));
        Counter.Text = $"{_index + 1}/{Pages.Count}";
        BackButton.IsEnabled = _index > 0;
        NextButton.Content = _index == Pages.Count - 1 ? "Done" : "Next";

        Rings.Children.Clear();
        var geometry = new GeometryGroup { FillRule = FillRule.EvenOdd };
        geometry.Children.Add(new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight)));
        var holes = new List<Rect>();
        // One frame around the whole group (the four layout buttons, the rail with its tab strip, the
        // search box with its button), never one frame per control: overlapping frames looked messy.
        Rect? group = null;
        foreach (string anchor in page.Anchors)
        foreach (FrameworkElement element in _anchors(anchor))
        {
            if (!element.IsVisible || element.ActualWidth <= 0 || element.ActualHeight <= 0) continue;
            try
            {
                // Convert through screen coordinates because the tour is a borderless window while its
                // owner has a normal Windows title bar (a direct ancestor transform misses that offset).
                Point p = Overlay.PointFromScreen(element.PointToScreen(new Point(0, 0)));
                var r = new Rect(p.X, p.Y, element.ActualWidth, element.ActualHeight);
                group = group is { } g ? Rect.Union(g, r) : r;
            }
            catch { }
        }
        if (group is { } box)
        {
            var hole = new Rect(box.X - 7, box.Y - 7, box.Width + 14, box.Height + 14);
            holes.Add(hole);
            geometry.Children.Add(new RectangleGeometry(hole, 9, 9));
            var ring = new Border { Width = hole.Width, Height = hole.Height, CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(2) };
            ring.SetResourceReference(Border.BorderBrushProperty, "XM.accent");
            Canvas.SetLeft(ring, hole.X); Canvas.SetTop(ring, hole.Y); Rings.Children.Add(ring);
        }
        DimPath.Data = geometry;
        DimPath.Width = ActualWidth;
        DimPath.Height = ActualHeight;

        // Keep the card inside the part of the window that is really visible: the host window may
        // reach under the taskbar, and a card centred on the whole window then hid its buttons there.
        (double visTop, double visBottom) = VisibleBand();
        double avail = Math.Max(160, visBottom - visTop - 24);
        Card.MaxHeight = avail;                       // taller pages scroll instead of growing
        Card.Measure(new Size(CardWidth, double.PositiveInfinity));
        double cardHeight = Math.Min(Card.DesiredSize.Height, avail);
        double x = (ActualWidth - CardWidth) / 2;
        double y = visTop + (visBottom - visTop - cardHeight) / 2;
        if (holes.Count > 0)
        {
            Rect union = holes.Aggregate(Rect.Union);
            double sideY = Math.Max(visTop + 12, Math.Min(union.Top, visBottom - cardHeight - 12));
            if (union.Bottom + 18 + cardHeight <= visBottom - 12)
            {
                x = union.Left + (union.Width - CardWidth) / 2;          // under the group, centred on it
                y = union.Bottom + 18;
            }
            else if (union.Left - CardWidth - 18 >= 12)
            {
                x = union.Left - CardWidth - 18;                          // a tall group (the rail): beside it, on the left
                y = sideY;
            }
            else if (union.Right + CardWidth + 18 <= ActualWidth - 12)
            {
                x = union.Right + 18;                                     // or on its right
                y = sideY;
            }
            else
            {
                x = union.Left + (union.Width - CardWidth) / 2;          // last resort: above it
                y = union.Top - cardHeight - 18;
            }
            x = Math.Clamp(x, 12, Math.Max(12, ActualWidth - CardWidth - 12));
        }
        y = Math.Clamp(y, visTop + 12, Math.Max(visTop + 12, visBottom - cardHeight - 12));
        Canvas.SetLeft(Card, x);
        Canvas.SetTop(Card, y);
    }

    private const double CardWidth = 400;

    /// <summary>The vertical band of this overlay that lies inside the monitor's working area (no taskbar), in overlay coordinates.</summary>
    private (double Top, double Bottom) VisibleBand()
    {
        try
        {
            IntPtr hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            IntPtr monitor = MonitorFromWindow(hwnd, 2 /* nearest */);
            var info = new MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFO>() };
            if (monitor != IntPtr.Zero && GetMonitorInfoW(monitor, ref info))
            {
                Point top = PointFromScreen(new Point(info.rcWork.Left, info.rcWork.Top));
                Point bottom = PointFromScreen(new Point(info.rcWork.Right, info.rcWork.Bottom));
                double t = Math.Max(0, top.Y), b = Math.Min(ActualHeight, bottom.Y);
                if (b - t > 80) return (t, b);
            }
        }
        catch
        {
            // fall through: the whole overlay
        }
        return (0, ActualHeight);
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO info);

    private void Step(int delta)
    {
        int next = _index + delta;
        if (next >= Pages.Count) { Close(); return; }
        _index = Math.Max(0, next);
        RenderPage();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
        else if (e.Key == Key.Left) Step(-1);
        else if (e.Key is Key.Right or Key.Enter or Key.Space) Step(1);
    }

    private void Overlay_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (!Card.IsMouseOver) Step(1);
    }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Back_Click(object sender, RoutedEventArgs e) => Step(-1);
    private void Next_Click(object sender, RoutedEventArgs e) => Step(1);
}
