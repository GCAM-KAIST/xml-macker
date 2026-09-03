namespace XMLMacker.Charts;

/// <summary>
/// The kind of trend to draw. 1:1 port of the Swift <c>TrendKind</c> enum.
/// </summary>
public enum TrendKind
{
    /// <summary>Time series / left→right progression (line + area).</summary>
    Line,

    /// <summary>Categorical comparison at a fixed moment (bars).</summary>
    Bar
}

/// <summary>
/// Immutable numeric series produced by <see cref="TrendComputer"/> and consumed by
/// <see cref="TrendView"/> and the pop-out table/CSV. 1:1 port of the Swift <c>TrendSeries</c>
/// value type.
/// Invariants (guaranteed by the builders): <see cref="XLabels"/>.Length ==
/// <see cref="Values"/>.Length ≥ 2; <see cref="Min"/> == min(<see cref="Values"/>);
/// <see cref="Max"/> == max(<see cref="Values"/>). <see cref="Min"/>/<see cref="Max"/> are stored
/// (never recomputed by the view).
/// </summary>
public sealed record TrendSeries(
    string Title,
    IReadOnlyList<string> XLabels,
    IReadOnlyList<double> Values,
    double Min,
    double Max,
    TrendKind Kind)
{
    public IReadOnlyList<double>? XPositions { get; init; }
}
