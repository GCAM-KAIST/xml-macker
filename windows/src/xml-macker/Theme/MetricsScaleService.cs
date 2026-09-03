using System.ComponentModel;
using System.Runtime.CompilerServices;
using XMLMacker.Shared;

namespace XMLMacker.Theme;

/// <summary>
/// The global-zoom nerve center. One observable <see cref="Scale"/> multiplier (0.5..2.0) that
/// writes through to <see cref="XMFont.GlobalScale"/> so both typography and layout metrics
/// (<see cref="XMMetric.S(double)"/>) rescale together. Value converters bind to <see cref="Scale"/>
/// via <see cref="PropertyChanged"/>; caches and custom-drawn views that cannot bind subscribe to
/// <see cref="RebuildFonts"/>. Persists to <c>XMLMacker.globalZoom</c>.
/// </summary>
public sealed class MetricsScaleService : INotifyPropertyChanged
{
    public const string PrefsKey = "xml-macker.globalZoom";

    public static MetricsScaleService Instance { get; } = new();

    private MetricsScaleService() { }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Raised after <see cref="Scale"/> changes so font/metric caches and custom-drawn views that
    /// cannot observe <see cref="PropertyChanged"/> re-query <see cref="XMFont"/>/<see cref="XMMetric"/>.
    /// WPF analog of the Swift <c>rebuildFonts()</c> broadcast.
    /// </summary>
    public event EventHandler? RebuildFonts;

    /// <summary>The standard application zoom (75 %): the size the app is designed for; Reset returns to it.</summary>
    public const double DefaultScale = 0.75;

    private double _scale = DefaultScale;

    /// <summary>
    /// The global zoom multiplier. Clamped 0.5..2.0. Assignment updates
    /// <see cref="XMFont.GlobalScale"/>, persists to <c>XMLMacker.globalZoom</c>, and fires both
    /// <see cref="PropertyChanged"/> and <see cref="RebuildFonts"/>.
    /// </summary>
    public double Scale
    {
        get => _scale;
        set
        {
            double clamped = Math.Clamp(value, 0.5, 2.0);
            if (Math.Abs(clamped - _scale) < 1e-9) return;
            _scale = clamped;
            XMFont.GlobalScale = clamped;
            AppSettings.Instance.SetDouble(PrefsKey, clamped);
            OnPropertyChanged();
            RebuildFonts?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Restore the persisted zoom on launch (only if in [0.5, 2.0]). Always syncs
    /// <see cref="XMFont.GlobalScale"/> to the resolved value.
    /// </summary>
    public void Load()
    {
        double z = AppSettings.Instance.GetDouble(PrefsKey, DefaultScale);
        _scale = (z is >= 0.5 and <= 2.0) ? z : DefaultScale;
        XMFont.GlobalScale = _scale;
        OnPropertyChanged(nameof(Scale));
        RebuildFonts?.Invoke(this, EventArgs.Empty);
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
