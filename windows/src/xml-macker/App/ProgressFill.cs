using System;
using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace XMLMacker.App;

/// <summary>
/// The status-bar progress "swipe" driver. 1:1 port of the <c>MainWindowController</c> progress-fill
/// timer: a 30 fps <see cref="DispatcherTimer"/> polls the live parser line count and a
/// total-lines denominator, computing a fraction that is capped at <b>0.98</b> when the real total is
/// known and at <b>0.92</b> when it isn't (a time-based asymptote instead). That fraction drives the
/// width of an accent <see cref="Rectangle"/>, implicit animations disabled, the width is set
/// directly each tick. <see cref="Finish"/> snaps to full and fades; <see cref="Flash"/> is the
/// "saved" cue that fills, holds, and fades.
/// </summary>
public sealed class ProgressFill
{
    private const double FpsInterval = 1.0 / 30.0;
    private const double RealCap = 0.98;
    private const double TimeCap = 0.92;

    private readonly Rectangle _fill;
    private readonly Func<double> _fullWidth;
    private readonly DispatcherTimer _timer;

    private Func<int>? _currentLine;
    private Func<int>? _totalLines;
    private double _estimatedSeconds = 1.0;
    private DateTime _start;

    /// <param name="fill">The accent rectangle whose <see cref="FrameworkElement.Width"/> is driven.</param>
    /// <param name="fullWidth">Supplies the current full track width (e.g. the status bar's
    /// <c>ActualWidth</c>), read fresh each tick so the fill tracks window resizes.</param>
    public ProgressFill(Rectangle fill, Func<double> fullWidth)
    {
        _fill = fill ?? throw new ArgumentNullException(nameof(fill));
        _fullWidth = fullWidth ?? throw new ArgumentNullException(nameof(fullWidth));
        _timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromSeconds(FpsInterval),
        };
        _timer.Tick += OnTick;
        _fill.Width = 0;
    }

    /// <summary>
    /// Begin a run. <paramref name="currentLine"/> / <paramref name="totalLines"/> are polled
    /// lock-free every tick (the parser's <c>volatile</c> line counter and the mmap newline total);
    /// while the total is 0 the fraction falls back to a time asymptote using
    /// <paramref name="estimatedSeconds"/> (= <c>max(1, sizeMB * 0.03)</c>).
    /// </summary>
    public void Start(Func<int> currentLine, Func<int> totalLines, double estimatedSeconds)
    {
        _currentLine = currentLine;
        _totalLines = totalLines;
        _estimatedSeconds = Math.Max(0.001, estimatedSeconds);
        _start = DateTime.UtcNow;

        StopFade();
        _fill.Opacity = 1;
        _fill.Width = 0;          // no animation, direct set
        _timer.Start();
    }

    private void OnTick(object? sender, EventArgs e)
    {
        double elapsed = (DateTime.UtcNow - _start).TotalSeconds;
        int total = _totalLines?.Invoke() ?? 0;

        double fraction;
        if (total > 0 && _currentLine is not null)
            fraction = Math.Min(RealCap, _currentLine() / (double)Math.Max(1, total));
        else
            fraction = Math.Min(TimeCap, elapsed / (elapsed + _estimatedSeconds));

        _fill.Width = Math.Max(0, _fullWidth() * fraction);
    }

    /// <summary>
    /// End the run: stop polling, snap the fill to the full width, then after 0.4 s fade its opacity
    /// to 0 over 0.5 s and reset the width to 0 (<c>finishProgressFill</c>).
    /// </summary>
    public void Finish()
    {
        _timer.Stop();
        _currentLine = null;
        _totalLines = null;

        StopFade();
        _fill.Opacity = 1;
        _fill.Width = _fullWidth();

        FadeThenReset(holdSeconds: 0.4, fadeSeconds: 0.5);
    }

    /// <summary>
    /// The "saved" cue: the fill is already full, hold it, then fade out. Snaps to full width,
    /// holds 0.4 s, fades over 0.4 s, and resets.
    /// </summary>
    public void Flash()
    {
        _timer.Stop();
        StopFade();
        _fill.Opacity = 1;
        _fill.Width = _fullWidth();
        FadeThenReset(holdSeconds: 0.4, fadeSeconds: 0.4);
    }

    private void FadeThenReset(double holdSeconds, double fadeSeconds)
    {
        var fade = new DoubleAnimation(1.0, 0.0, TimeSpan.FromSeconds(fadeSeconds))
        {
            BeginTime = TimeSpan.FromSeconds(holdSeconds),
        };
        fade.Completed += (_, _) =>
        {
            _fill.BeginAnimation(UIElement.OpacityProperty, null);   // release the animation hold
            _fill.Opacity = 1;
            _fill.Width = 0;
        };
        _fill.BeginAnimation(UIElement.OpacityProperty, fade);
    }

    private void StopFade() => _fill.BeginAnimation(UIElement.OpacityProperty, null);
}
