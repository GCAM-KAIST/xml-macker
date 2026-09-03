using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace XMLMacker.Editor;

/// <summary>
/// Chrome-style middle-click autoscroll (port of the Swift <c>HighlightingTextView</c> otherMouseDown logic). One
/// middle-click arms a ~60 Hz timer; a second click (middle or left) disarms. While armed, the vertical scroll
/// moves at <c>speed = (|dy| - 6) * 0.35</c> px/tick with a 6 px dead-zone, direction following the mouse relative
/// to the anchor. The cursor changes to a resize-up/down glyph while active.
/// </summary>
public sealed class AutoScroller
{
    private readonly IInputElement _host;
    private readonly Action<double> _scrollBy; // positive dy scrolls the content down
    private readonly Func<Point> _mousePos;    // current mouse position in host coordinates

    private readonly DispatcherTimer _timer;
    private Point _anchor;

    /// <summary>Whether autoscroll is currently armed.</summary>
    public bool IsActive { get; private set; }

    /// <param name="host">Element to capture/uncapture the mouse and set the cursor on.</param>
    /// <param name="scrollBy">Scrolls the content by a signed delta (positive = further down the document).</param>
    /// <param name="mousePos">Returns the current mouse position in <paramref name="host"/> coordinates.</param>
    public AutoScroller(IInputElement host, Action<double> scrollBy, Func<Point> mousePos)
    {
        _host = host;
        _scrollBy = scrollBy;
        _mousePos = mousePos;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.0 / 60.0) };
        _timer.Tick += (_, __) => Tick();
    }

    /// <summary>
    /// Handle a middle-button press: toggles autoscroll. Returns true if the event was consumed (so the caller
    /// swallows it). Anchor is the click position in host coordinates.
    /// </summary>
    public bool OnMiddleDown(Point positionInHost)
    {
        if (IsActive) { Stop(); return true; }
        Start(positionInHost);
        return true;
    }

    /// <summary>
    /// Handle any other (left) mouse press while armed: disarms and swallows the click (mirrors the Swift mouseDown
    /// guard). Returns true if it consumed the event.
    /// </summary>
    public bool OnOtherDownWhileActive()
    {
        if (!IsActive) return false;
        Stop();
        return true;
    }

    private void Start(Point anchor)
    {
        _anchor = anchor;
        IsActive = true;
        if (_host is FrameworkElement fe)
        {
            fe.CaptureMouse();
            fe.Cursor = Cursors.ScrollNS;
        }
        _timer.Start();
    }

    /// <summary>Disarms autoscroll and restores the cursor.</summary>
    public void Stop()
    {
        if (!IsActive) return;
        IsActive = false;
        _timer.Stop();
        if (_host is FrameworkElement fe)
        {
            fe.ReleaseMouseCapture();
            fe.Cursor = Cursors.IBeam;
        }
    }

    private void Tick()
    {
        Point p = _mousePos();
        double dy = p.Y - _anchor.Y;
        if (Math.Abs(dy) <= 6) return;                 // dead-zone
        double speed = (Math.Abs(dy) - 6) * 0.35;
        // In WPF top-left coords, mouse BELOW the anchor (dy > 0) scrolls the document DOWN.
        _scrollBy(dy > 0 ? speed : -speed);
    }
}
