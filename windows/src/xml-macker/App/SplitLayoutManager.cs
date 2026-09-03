using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Chrome;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.App;

/// <summary>Which axis a <see cref="SplitGroup"/> lays its panes along.</summary>
public enum SplitOrientation
{
    /// <summary>Panes side by side (an <c>isVertical=true</c> AppKit <c>NSSplitView</c> → WPF columns).</summary>
    Columns,
    /// <summary>Panes stacked top-to-bottom (an <c>isVertical=false</c> <c>NSSplitView</c> → WPF rows).</summary>
    Rows,
}

/// <summary>
/// A Windows-sized pane divider.  The stock WPF splitter is difficult to discover when its
/// background is transparent, especially on a high-DPI display, so this control keeps a generous
/// hit target, paints a crisp centre rule, and always advertises the correct resize cursor.
/// </summary>
internal sealed class PaneGridSplitter : Thumb
{
    private readonly SplitOrientation _orientation;
    private ColumnDefinition? _previousColumn;
    private ColumnDefinition? _nextColumn;
    private RowDefinition? _previousRow;
    private RowDefinition? _nextRow;
    private double _previousExtent;
    private double _nextExtent;

    public PaneGridSplitter(SplitOrientation orientation)
    {
        _orientation = orientation;
        Background = Brushes.Transparent; // a real brush makes the whole track hit-testable
        Cursor = orientation == SplitOrientation.Columns ? Cursors.SizeWE : Cursors.SizeNS;
        Focusable = false;
        IsTabStop = false;
        ToolTip = orientation == SplitOrientation.Columns
            ? "Drag left or right to resize panes"
            : "Drag up or down to resize panes";
        AutomationProperties.SetName(this, "Pane resize divider");
        DragStarted += OnDragStarted;
        DragDelta += OnDragDelta;
        DragCompleted += OnDragCompleted;
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        Brush rule = (TryFindResource(IsMouseOver ? XMColor.Accent : XMColor.HairlineS) as Brush)
                     ?? (IsMouseOver ? Brushes.DodgerBlue : Brushes.Gray);
        var pen = new Pen(rule, IsMouseOver ? 1.5 : 0.75);

        if (_orientation == SplitOrientation.Columns)
        {
            double x = Math.Round(ActualWidth / 2) + 0.5;
            drawingContext.DrawLine(pen, new Point(x, 1), new Point(x, Math.Max(1, ActualHeight - 1)));
        }
        else
        {
            double y = Math.Round(ActualHeight / 2) + 0.5;
            drawingContext.DrawLine(pen, new Point(1, y), new Point(Math.Max(1, ActualWidth - 1), y));
        }
    }

    private void OnDragStarted(object sender, DragStartedEventArgs e)
    {
        // WPF's stock row splitter can silently decline a drag in a nested star-sized grid. Keep
        // the familiar GridSplitter control, but take ownership of the adjacent definitions so
        // rows and columns use the same deterministic resize path.
        _previousColumn = null;
        _nextColumn = null;
        _previousRow = null;
        _nextRow = null;

        if (Parent is not Grid grid) return;
        if (_orientation == SplitOrientation.Columns)
        {
            int cell = Grid.GetColumn(this);
            if (cell <= 0 || cell + 1 >= grid.ColumnDefinitions.Count) return;
            _previousColumn = grid.ColumnDefinitions[cell - 1];
            _nextColumn = grid.ColumnDefinitions[cell + 1];
            _previousExtent = _previousColumn.ActualWidth;
            _nextExtent = _nextColumn.ActualWidth;
        }
        else
        {
            int cell = Grid.GetRow(this);
            if (cell <= 0 || cell + 1 >= grid.RowDefinitions.Count) return;
            _previousRow = grid.RowDefinitions[cell - 1];
            _nextRow = grid.RowDefinitions[cell + 1];
            _previousExtent = _previousRow.ActualHeight;
            _nextExtent = _nextRow.ActualHeight;
        }
    }

    private void OnDragDelta(object sender, DragDeltaEventArgs e)
    {
        double requested = _orientation == SplitOrientation.Columns
            ? e.HorizontalChange
            : e.VerticalChange;
        if (double.IsNaN(requested) || double.IsInfinity(requested)) return;

        double previousMin;
        double nextMin;
        double previousMax;
        double nextMax;
        if (_orientation == SplitOrientation.Columns)
        {
            if (_previousColumn is null || _nextColumn is null) return;
            previousMin = _previousColumn.MinWidth;
            nextMin = _nextColumn.MinWidth;
            previousMax = _previousColumn.MaxWidth;
            nextMax = _nextColumn.MaxWidth;
        }
        else
        {
            if (_previousRow is null || _nextRow is null) return;
            previousMin = _previousRow.MinHeight;
            nextMin = _nextRow.MinHeight;
            previousMax = _previousRow.MaxHeight;
            nextMax = _nextRow.MaxHeight;
        }

        double minimumChange = previousMin - _previousExtent;
        double maximumChange = _nextExtent - nextMin;
        if (!double.IsPositiveInfinity(previousMax))
            maximumChange = Math.Min(maximumChange, previousMax - _previousExtent);
        if (!double.IsPositiveInfinity(nextMax))
            minimumChange = Math.Max(minimumChange, _nextExtent - nextMax);
        if (minimumChange > maximumChange) return;

        double change = Math.Clamp(requested, minimumChange, maximumChange);
        _previousExtent += change;
        _nextExtent -= change;

        if (_orientation == SplitOrientation.Columns)
        {
            _previousColumn!.Width = new GridLength(Math.Max(0.0001, _previousExtent), GridUnitType.Star);
            _nextColumn!.Width = new GridLength(Math.Max(0.0001, _nextExtent), GridUnitType.Star);
        }
        else
        {
            _previousRow!.Height = new GridLength(Math.Max(0.0001, _previousExtent), GridUnitType.Star);
            _nextRow!.Height = new GridLength(Math.Max(0.0001, _nextExtent), GridUnitType.Star);
        }

        e.Handled = true;
    }

    private void OnDragCompleted(object sender, DragCompletedEventArgs e)
    {
        _previousColumn = null;
        _nextColumn = null;
        _previousRow = null;
        _nextRow = null;
    }

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        InvalidateVisual();
    }
}

/// <summary>
/// One pane registered with the layout engine. Mirrors the AppKit pairing of a wrapped glass card
/// (<see cref="Glass"/>) and its title strip (<see cref="Chrome"/>), plus every bit of per-pane
/// bookkeeping <c>MainWindowController</c> kept in its many dictionaries
/// (<c>minimizeSaved</c>, <c>closedPanes</c>, <c>expandSaved</c>, <c>popouts</c>): the collapse
/// floor, the default star thickness, the saved extent before a state change, and the four
/// AppKit chrome states.
/// </summary>
public sealed class PaneSlot
{
    internal PaneSlot(string key, SplitGroup group, int orderIndex,
        FrameworkElement glass, PaneChrome chrome, double floor, double defaultThickness)
    {
        Key = key;
        Group = group;
        OrderIndex = orderIndex;
        Glass = glass;
        Chrome = chrome;
        Floor = floor;
        DefaultThickness = defaultThickness;
        SavedThickness = defaultThickness;
    }

    /// <summary>The pane title (also the registry key and the string a View menu item carries).</summary>
    public string Key { get; }

    /// <summary>The split this pane lives in.</summary>
    public SplitGroup Group { get; internal set; }

    /// <summary>
    /// Stable canonical ordering rank within the group. Present panes are always laid out in
    /// ascending <see cref="OrderIndex"/> order, so a docked or re-shown pane returns to its
    /// canonical slot (the Swift <c>canonicalDockIndex</c> contract).
    /// </summary>
    public int OrderIndex { get; internal set; }

    /// <summary>The wrapped glass card (the element added to / removed from the grid).</summary>
    public FrameworkElement Glass { get; }

    /// <summary>The pane's title strip; state flags are mirrored onto it.</summary>
    public PaneChrome Chrome { get; }

    /// <summary>Usability floor (px, base), Inspector 210 / Chart 110 / Preview 120 / default 90.</summary>
    public double Floor { get; }

    /// <summary>Initial star weight, used before the grid has a real size and as the un-minimize fallback.</summary>
    public double DefaultThickness { get; }

    /// <summary>Extent captured just before a minimize / hide / pop-out so the pane restores to its old size.</summary>
    internal double SavedThickness { get; set; }

    /// <summary>Whole-column extents snapshot captured when this pane maximizes in place.</summary>
    internal Dictionary<string, double>? ExpandSnapshot { get; set; }

    /// <summary>Closed via the removal model, contributes ZERO and has no divider.</summary>
    public bool IsHidden { get; internal set; }

    /// <summary>Floated into its own window, removed from the split until docked.</summary>
    public bool IsPoppedOut { get; internal set; }

    /// <summary>Collapsed to header-only (26 pt scaled).</summary>
    public bool IsMinimized { get; internal set; }

    /// <summary>Maximized in place (given all spare room in its column).</summary>
    public bool IsMaximized { get; internal set; }

    /// <summary>True while the pane occupies a cell in its grid (not hidden, not popped out).</summary>
    public bool IsPresent => !IsHidden && !IsPoppedOut;

    // The live grid definition backing this pane (set on each RebuildStructure).
    internal ColumnDefinition? ColDef { get; set; }
    internal RowDefinition? RowDef { get; set; }
}

/// <summary>
/// One split container: a dedicated WPF <see cref="Grid"/> whose star-sized rows or columns
/// reproduce a single AppKit <c>NSSplitView</c>. Panes occupy the even cells; a
/// <see cref="GridSplitter"/> occupies each odd cell between two present panes, so a removed pane
/// leaves NO cell and therefore NO ghost divider (the v0.24.0 removal fix). Structural changes
/// (hide/show/pop-out/dock/reorder) call <see cref="RebuildStructure"/>; sizing changes
/// (minimize/expand/proportions) call <see cref="LayoutSplit"/>, the deterministic single-pass solve.
/// </summary>
public sealed class SplitGroup
{
    /// <summary>Divider track thickness in device-independent pixels.  The visible rule is thin, but
    /// the Windows mouse target is deliberately wider so pane borders remain easy to drag.</summary>
    public const double DividerThickness = 10.0;

    private readonly SplitLayoutManager _owner;
    private readonly List<PaneGridSplitter> _splitters = new();
    private bool _sizeHooked;

    internal SplitGroup(SplitLayoutManager owner, string id, Grid grid,
        SplitOrientation orientation, bool autoCollapsible)
    {
        _owner = owner;
        Id = id;
        Grid = grid;
        Orientation = orientation;
        AutoCollapsible = autoCollapsible;
    }

    /// <summary>Stable identifier (e.g. "main", "topH", "rootV", "inspectorCol").</summary>
    public string Id { get; }

    /// <summary>The dedicated grid, the engine owns every child and definition in it.</summary>
    public Grid Grid { get; }

    /// <summary>Column vs row layout.</summary>
    public SplitOrientation Orientation { get; }

    /// <summary>Whether this split auto-minimizes panes bottom-up when squeezed below floors.</summary>
    public bool AutoCollapsible { get; }

    /// <summary>Panes in canonical order.</summary>
    internal List<PaneSlot> Panes { get; } = new();

    /// <summary>Present (non-hidden, non-popped-out) panes in canonical order.</summary>
    internal List<PaneSlot> PresentPanes =>
        Panes.Where(p => p.IsPresent).OrderBy(p => p.OrderIndex).ToList();

    private bool IsColumns => Orientation == SplitOrientation.Columns;

    private double TotalPx => IsColumns ? Grid.ActualWidth : Grid.ActualHeight;

    /// <summary>
    /// Rebuild the grid's definitions and children from the current set of present panes. Every hide,
    /// show, pop-out, dock, and reorder funnels here, the analog of <c>adjustSubviews()</c> after an
    /// <c>insert/removeArrangedSubview</c>. Sizes are then refined by <see cref="LayoutSplit"/>.
    /// </summary>
    internal void RebuildStructure()
    {
        // Detach everything owned here; the grid is dedicated to this split.
        // A pane that is currently POPPED OUT is not ours to touch: its glass lives in the Border of a
        // floating window, and DetachFromParent's Decorator arm matches that Border, so detaching it
        // here would empty a window that is still on screen and leave a grey shell behind.
        // The definition fields are still cleared for every pane, or CurrentThickness reads a stale one.
        foreach (var p in Panes)
        {
            if (!p.IsPoppedOut) SplitLayoutManager.DetachFromParent(p.Glass);
            p.ColDef = null;
            p.RowDef = null;
        }
        _splitters.Clear();
        Grid.Children.Clear();
        Grid.ColumnDefinitions.Clear();
        Grid.RowDefinitions.Clear();

        var present = PresentPanes;
        if (present.Count == 0) return;

        int cell = 0;
        for (int i = 0; i < present.Count; i++)
        {
            if (i > 0)
            {
                AddDividerCell();          // splitter between the previous present pane and this one
                AddSplitter(cell);
                cell++;
            }

            var p = present[i];
            AddPaneCell(p);                 // star cell, MinWidth/Height = scaled floor
            PlacePane(p, cell);
            cell++;
        }
    }

    private void AddDividerCell()
    {
        if (IsColumns)
            Grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(DividerThickness) });
        else
            Grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(DividerThickness) });
    }

    private void AddPaneCell(PaneSlot p)
    {
        double floor = _owner.ScaledFloor(p.Floor);
        if (IsColumns)
        {
            var def = new ColumnDefinition
            {
                Width = new GridLength(p.DefaultThickness, GridUnitType.Star),
                MinWidth = floor,
            };
            Grid.ColumnDefinitions.Add(def);
            p.ColDef = def;
        }
        else
        {
            var def = new RowDefinition
            {
                Height = new GridLength(p.DefaultThickness, GridUnitType.Star),
                MinHeight = floor,
            };
            Grid.RowDefinitions.Add(def);
            p.RowDef = def;
        }
    }

    private void AddSplitter(int cellIndex)
    {
        var sp = new PaneGridSplitter(Orientation)
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        if (IsColumns)
        {
            sp.Width = DividerThickness;
            Grid.SetColumn(sp, cellIndex);
            Grid.SetRow(sp, 0);
        }
        else
        {
            sp.Height = DividerThickness;
            Grid.SetRow(sp, cellIndex);
            Grid.SetColumn(sp, 0);
        }
        Panel.SetZIndex(sp, int.MaxValue);
        sp.DragCompleted += (_, _) => _owner.OnSplitterDragged(this);
        _splitters.Add(sp);
        Grid.Children.Add(sp);
    }

    private void PlacePane(PaneSlot p, int cellIndex)
    {
        if (IsColumns) { Grid.SetColumn(p.Glass, cellIndex); Grid.SetRow(p.Glass, 0); }
        else { Grid.SetRow(p.Glass, cellIndex); Grid.SetColumn(p.Glass, 0); }
        Grid.Children.Add(p.Glass);

        if (!_sizeHooked)
        {
            Grid.SizeChanged += (_, _) => _owner.OnGroupResized(this);
            _sizeHooked = true;
        }
    }

    internal double CurrentThickness(PaneSlot p)
        => IsColumns ? (p.ColDef?.ActualWidth ?? 0) : (p.RowDef?.ActualHeight ?? 0);

    private void SetSize(PaneSlot p, GridLength g)
    {
        if (IsColumns) { if (p.ColDef != null) p.ColDef.Width = g; }
        else { if (p.RowDef != null) p.RowDef.Height = g; }
    }

    private void SetMin(PaneSlot p, double min)
    {
        if (IsColumns) { if (p.ColDef != null) p.ColDef.MinWidth = min; }
        else { if (p.RowDef != null) p.RowDef.MinHeight = min; }
    }

    /// <summary>
    /// The deterministic single-pass proportion solve (<c>layoutSplit</c>). Minimized panes take
    /// the fixed header extent; flexible panes split the remainder in proportion to their current
    /// (or overridden) size; when more than one pane is flexible a usability-floor pass shifts slack
    /// from the largest flexible pane to any pane that fell below its floor. All-minimized dumps the
    /// leftover onto the last pane so it reads as clean glass.
    /// </summary>
    /// <param name="overrides">Optional per-pane target extents keyed by pane title (e.g. a huge value
    /// to maximize, or a restored extent to un-minimize).</param>
    internal void LayoutSplit(IReadOnlyDictionary<string, double>? overrides = null)
    {
        var present = PresentPanes;
        if (present.Count == 0) return;
        if (present.Count == 1)
        {
            SetSize(present[0], new GridLength(1, GridUnitType.Star));
            SetMin(present[0], present[0].IsMinimized ? _owner.MinimizedExtent : _owner.ScaledFloor(present[0].Floor));
            return;
        }

        double total = TotalPx;
        double dividers = (present.Count - 1) * DividerThickness;
        double avail = total - dividers;
        if (avail <= 40) return;   // grid not yet sized (or too small), retry on next SizeChanged

        int n = present.Count;
        var desired = new double[n];
        var isFlex = new bool[n];
        double extent = _owner.MinimizedExtent;
        double fixedSum = 0, flexTotal = 0;
        int flexCount = 0;

        for (int i = 0; i < n; i++)
        {
            var p = present[i];
            if (p.IsMinimized)
            {
                desired[i] = extent;
                fixedSum += extent;
                isFlex[i] = false;
            }
            else
            {
                double want;
                if (overrides != null && overrides.TryGetValue(p.Key, out double ov))
                    want = ov;
                else
                {
                    double cur = CurrentThickness(p);
                    want = cur >= 1 ? cur : p.DefaultThickness;   // DefaultThickness seeds the first paint
                }
                desired[i] = Math.Max(want, 1);
                isFlex[i] = true;
                flexTotal += desired[i];
                flexCount++;
            }
        }

        double flexAvail = Math.Max(0, avail - fixedSum);

        if (flexCount > 0 && flexTotal > 0)
        {
            for (int i = 0; i < n; i++)
                if (isFlex[i]) desired[i] = desired[i] / flexTotal * flexAvail;

            if (flexCount > 1)
            {
                for (int i = 0; i < n; i++)
                {
                    if (!isFlex[i]) continue;
                    double floorH = _owner.ScaledFloor(present[i].Floor);
                    if (desired[i] >= floorH) continue;

                    double need = floorH - desired[i];
                    int largest = -1;
                    double largestVal = double.NegativeInfinity;
                    for (int j = 0; j < n; j++)
                    {
                        if (!isFlex[j] || j == i) continue;
                        if (desired[j] > largestVal) { largestVal = desired[j]; largest = j; }
                    }
                    if (largest < 0) continue;

                    double largestFloor = _owner.ScaledFloor(present[largest].Floor);
                    if (desired[largest] - need >= largestFloor)
                    {
                        desired[largest] -= need;
                        desired[i] = floorH;
                    }
                }
            }
        }
        else if (flexCount == 0)
        {
            desired[n - 1] += flexAvail;   // all minimized → last pane soaks the slack
        }

        for (int i = 0; i < n; i++)
        {
            var p = present[i];
            if (isFlex[i])
            {
                SetMin(p, _owner.ScaledFloor(p.Floor));
                SetSize(p, new GridLength(Math.Max(desired[i], 0.0001), GridUnitType.Star));
            }
            else
            {
                SetMin(p, 0);
                SetSize(p, new GridLength(desired[i]));
            }
        }
    }
}

/// <summary>
/// The NSSplitView-replacement engine. Reproduces, over WPF <see cref="Grid"/> star sizing plus
/// <see cref="GridSplitter"/>, the deterministic <c>MainWindowController</c> pane machinery:
/// the single-pass <c>layoutSplit</c> with per-pane floors and <c>effectiveMin</c>, removal-based
/// hide (the pane's cell and divider both vanish, no ghost), minimize-to-header / expand,
/// maximize-within-column, auto-collapse-under-pressure with most-recent-first restore, and
/// persistence of the minimized set to <c>XMLMacker.minimizedPaneTitles</c>. MainWindow registers
/// its panes, wires the pane-chrome callbacks to these methods, and subscribes to
/// <see cref="PaneStateChanged"/> to refresh View-menu enable/checkmark state.
/// </summary>
public sealed class SplitLayoutManager
{
    /// <summary>Persistence key for the set of minimized pane titles.</summary>
    public const string MinimizedPanesKey = "xml-macker.minimizedPaneTitles";

    private readonly List<SplitGroup> _groups = new();
    private readonly Dictionary<string, PaneSlot> _panes = new();

    // Auto-collapse stack: pane keys minimized by pressure, restored most-recent-first.
    private readonly List<string> _autoMinimized = new();
    private bool _autoCollapsing;

    /// <summary>Raised whenever a pane's visibility / minimize / maximize / pop-out state changes,
    /// so the window can refresh menu <c>CanExecute</c> and checkmarks. Argument = pane key.</summary>
    public event EventHandler<string>? PaneStateChanged;

    /// <summary>Header-only extent (26 pt) scaled by the global zoom, matching the rest of the chrome.</summary>
    public double MinimizedExtent => XMMetric.S(XMMetric.MinimizedExtent);

    /// <summary>A pane floor scaled by the global zoom, so effective minimums track the zoomed UI.</summary>
    internal double ScaledFloor(double baseFloor) => XMMetric.S(baseFloor);

    // ── Registration ─────────────────────────────────────────────────────────────────────

    /// <summary>Create a split backed by a dedicated grid.</summary>
    public SplitGroup AddGroup(string id, Grid grid, SplitOrientation orientation, bool autoCollapsible = false)
    {
        var g = new SplitGroup(this, id, grid, orientation, autoCollapsible);
        _groups.Add(g);
        return g;
    }

    /// <summary>
    /// Register a pane into a split at a canonical grid position. <paramref name="floor"/> and
    /// <paramref name="defaultThickness"/> are the layout inputs; <paramref name="glass"/> and
    /// <paramref name="chrome"/> are the views the engine manipulates.
    /// </summary>
    public PaneSlot Register(string paneKey, SplitGroup group, int index,
        FrameworkElement glass, PaneChrome chrome, double floor, double defaultThickness)
    {
        var slot = new PaneSlot(paneKey, group, index, glass, chrome, floor, defaultThickness);
        _panes[paneKey] = slot;
        group.Panes.Add(slot);
        group.Panes.Sort((a, b) => a.OrderIndex.CompareTo(b.OrderIndex));
        return slot;
    }

    /// <summary>Build every group's structure. Call after all panes are registered. The first real
    /// proportion solve happens lazily on the grids' first non-zero size.</summary>
    public void Build()
    {
        foreach (var g in _groups) g.RebuildStructure();
    }

    /// <summary>Re-run the proportion solve on every group (e.g. after a global zoom change).</summary>
    public void LayoutAll()
    {
        foreach (var g in _groups) g.LayoutSplit();
    }

    /// <summary>Re-run the proportion solve on one group with optional per-pane target extents.</summary>
    public void LayoutGroup(SplitGroup group, IReadOnlyDictionary<string, double>? overrides = null)
        => group.LayoutSplit(overrides);

    // ── Queries (for menu validation) ───────────────────────────────────────────────────

    /// <summary>True if a pane with this key was registered.</summary>
    public bool HasPane(string key) => _panes.ContainsKey(key);

    /// <summary>True if the pane currently occupies a cell (not hidden, not popped out).</summary>
    public bool IsPresent(string key) => _panes.TryGetValue(key, out var p) && p.IsPresent;

    /// <summary>True if the pane is closed via the removal model.</summary>
    public bool IsHidden(string key) => _panes.TryGetValue(key, out var p) && p.IsHidden;

    /// <summary>True if the pane is collapsed to header-only.</summary>
    public bool IsMinimized(string key) => _panes.TryGetValue(key, out var p) && p.IsMinimized;

    /// <summary>True if the pane is maximized in place.</summary>
    public bool IsMaximized(string key) => _panes.TryGetValue(key, out var p) && p.IsMaximized;

    /// <summary>True if the pane floats in its own window.</summary>
    public bool IsPoppedOut(string key) => _panes.TryGetValue(key, out var p) && p.IsPoppedOut;

    /// <summary>Show-menu enable rule: a pane can be "shown" only when it is closed OR minimized.</summary>
    public bool IsClosedOrMinimized(string key)
        => _panes.TryGetValue(key, out var p) && (p.IsHidden || p.IsMinimized);

    private PaneSlot? Get(string key) => _panes.TryGetValue(key, out var p) ? p : null;

    // ── Hide / show (removal model) ─────────────────────────────────────────────────

    /// <summary>Close a pane by removing its cell and divider entirely (nothing left to resurrect).</summary>
    public void Hide(string key)
    {
        var p = Get(key);
        // Refuse to hide a pane that is living in a floating window (macOS guards the same way in
        // setVisible). Otherwise IsHidden is set on a floating pane, DockFromPopOut clears IsPoppedOut
        // but not IsHidden, IsPresent stays false, and the pane never comes home.
        if (p is null || p.IsHidden || p.IsPoppedOut) return;
        if (p.IsPresent) p.SavedThickness = p.Group.CurrentThickness(p);
        p.IsHidden = true;
        p.Group.RebuildStructure();
        p.Group.LayoutSplit();
        RaiseChanged(key);
    }

    /// <summary>Re-show a pane. A minimized pane is expanded; a closed pane is re-inserted at its
    /// canonical slot and given back a sensible extent (<c>menuShowPane</c>).</summary>
    public void Show(string key)
    {
        var p = Get(key);
        if (p is null) return;
        if (p.IsMinimized) { Expand(key); return; }
        if (!p.IsHidden) return;
        p.IsHidden = false;
        p.Group.RebuildStructure();
        p.Group.LayoutSplit(One(key, Math.Max(p.SavedThickness, 80)));
        RaiseChanged(key);
    }

    /// <summary>View-menu toggle: hide if visible, show if closed.</summary>
    public void TogglePane(string key)
    {
        var p = Get(key);
        if (p is null) return;
        if (p.IsHidden) Show(key); else Hide(key);
    }

    /// <summary>Workspace helper (<c>setVisible</c>): drive to a target visibility via the removal model.</summary>
    public void SetVisible(string key, bool visible)
    {
        var p = Get(key);
        if (p is null) return;
        if (visible) { if (p.IsHidden) Show(key); }
        else { if (!p.IsHidden) Hide(key); }
    }

    // ── Minimize / expand ──────────────────────────────────────────────────────────

    /// <summary>Collapse a pane to its header strip only (fixed 26 pt scaled). Persists the minimized set.</summary>
    public void MinimizeToHeader(string key)
    {
        var p = Get(key);
        if (p is null || p.IsMinimized || !p.IsPresent) return;
        p.SavedThickness = p.Group.CurrentThickness(p);
        p.IsMinimized = true;
        p.Chrome.IsMinimized = true;
        p.Group.LayoutSplit();
        PersistMinimized(key, true);
        RaiseChanged(key);
    }

    /// <summary>Un-minimize a header-only pane, restoring its saved extent. Persists the set.</summary>
    public void Expand(string key)
    {
        var p = Get(key);
        if (p is null || !p.IsMinimized) return;
        p.IsMinimized = false;
        p.Chrome.IsMinimized = false;
        double prior = p.SavedThickness > 0 ? p.SavedThickness : 200;
        p.Group.LayoutSplit(One(key, Math.Max(prior, 80)));
        PersistMinimized(key, false);
        _autoMinimized.RemoveAll(k => k == key);
        RaiseChanged(key);
    }

    /// <summary>Toggle minimize / un-minimize.</summary>
    public void ToggleMinimize(string key)
    {
        var p = Get(key);
        if (p is null) return;
        if (p.IsMinimized) Expand(key); else MinimizeToHeader(key);
    }

    // ── Maximize within column (green button) ────────────────────────────────────────

    /// <summary>The green-dot behaviour: expand a pane to fill its column in place; a second click
    /// restores the whole-column snapshot; on a minimized pane it just un-minimizes.</summary>
    public void ToggleMaximize(string key)
    {
        var p = Get(key);
        if (p is null || !p.IsPresent) return;

        if (p.IsMinimized) { ToggleMinimize(key); return; }

        if (p.IsMaximized)
        {
            p.IsMaximized = false;
            p.Chrome.IsMaximized = false;
            var snapshot = p.ExpandSnapshot;
            p.ExpandSnapshot = null;
            p.Group.LayoutSplit(snapshot);
        }
        else
        {
            var snap = new Dictionary<string, double>();
            foreach (var q in p.Group.PresentPanes)
                snap[q.Key] = p.Group.CurrentThickness(q);
            p.ExpandSnapshot = snap;
            p.IsMaximized = true;
            p.Chrome.IsMaximized = true;
            p.Group.LayoutSplit(One(key, 100_000));
        }
        RaiseChanged(key);
    }

    // ── Pop-out / dock ────────────────────────────────────────────────────────

    /// <summary>
    /// Detach a pane for floating in its own window: mark it popped out, hide its chrome header
    /// (the window's own title bar takes over), remove it from the split, and return the glass so the
    /// window can host it. Window creation and frame persistence stay with MainWindow.
    /// </summary>
    public FrameworkElement? DetachForPopOut(string key)
    {
        var p = Get(key);
        if (p is null || p.IsPoppedOut) return null;
        if (p.IsPresent) p.SavedThickness = p.Group.CurrentThickness(p);
        p.IsPoppedOut = true;
        p.Chrome.IsPoppedOut = true;
        p.Chrome.HeaderHidden = true;
        p.Group.RebuildStructure();
        p.Group.LayoutSplit();
        RaiseChanged(key);
        return p.Glass;
    }

    /// <summary>
    /// Dock a popped-out pane back to its canonical slot, fully open (clears stale minimize/auto
    /// flags). The caller must first remove the glass from its window host; the engine also
    /// defensively detaches it before re-inserting.
    /// </summary>
    public void DockFromPopOut(string key)
    {
        var p = Get(key);
        if (p is null || !p.IsPoppedOut) return;

        // Make good on this method's promise: the glass may still be parented to the closing window's
        // Border. Re-adding a child that already has a logical parent throws
        // "Specified element is already the logical child of another element", which used to kill the app.
        SplitLayoutManager.DetachFromParent(p.Glass);

        p.IsPoppedOut = false;
        p.Chrome.IsPoppedOut = false;
        p.Chrome.HeaderHidden = false;
        p.IsMinimized = false;
        p.Chrome.IsMinimized = false;
        p.IsHidden = false;          // a pane hidden while floating must not be lost on the way home.
        _autoMinimized.RemoveAll(k => k == key);
        p.Group.RebuildStructure();
        p.Group.LayoutSplit(One(key, Math.Max(p.SavedThickness, 80)));
        RaiseChanged(key);
    }

    // ── Reorder (RStudio layout) ────────────────────────────────────────────────────

    /// <summary>Reassign canonical order within a group without recreating panes (selection/scroll
    /// survive), then rebuild and re-solve. Keys not in <paramref name="orderedKeys"/> keep their
    /// relative order after the listed ones.</summary>
    public void SetOrder(SplitGroup group, IReadOnlyList<string> orderedKeys)
    {
        int rank = 0;
        foreach (var key in orderedKeys)
            if (_panes.TryGetValue(key, out var p) && p.Group == group)
                p.OrderIndex = rank++;
        foreach (var p in group.Panes.OrderBy(x => x.OrderIndex).ToList())
            if (!orderedKeys.Contains(p.Key))
                p.OrderIndex = rank++;
        group.Panes.Sort((a, b) => a.OrderIndex.CompareTo(b.OrderIndex));
        group.RebuildStructure();
        group.LayoutSplit();
    }

    /// <summary>Give every present pane in a group an equal share (<c>resetInspectorColumn</c>).</summary>
    public void ResetColumn(SplitGroup group)
    {
        var present = group.PresentPanes;
        if (present.Count == 0) return;
        double total = group.Orientation == SplitOrientation.Columns ? group.Grid.ActualWidth : group.Grid.ActualHeight;
        double share = Math.Max(120, total / present.Count);
        var overrides = present.ToDictionary(p => p.Key, _ => share);
        group.LayoutSplit(overrides);
    }

    /// <summary>Un-minimize every minimized pane and clear the auto-collapse stack (Full mode).</summary>
    public void UnminimizeAll()
    {
        var affected = new HashSet<SplitGroup>();
        foreach (var p in _panes.Values)
        {
            if (!p.IsMinimized) continue;
            p.IsMinimized = false;
            p.Chrome.IsMinimized = false;
            PersistMinimized(p.Key, false);
            affected.Add(p.Group);
        }
        _autoMinimized.Clear();
        foreach (var g in affected) g.LayoutSplit();
        foreach (var p in _panes.Values) RaiseChanged(p.Key);
    }

    // ── Persistence ────────────────────────────────────────────────────────────────

    private void PersistMinimized(string title, bool minimized)
    {
        var set = new SortedSet<string>(AppSettings.Instance.GetStringList(MinimizedPanesKey));
        if (minimized) set.Add(title); else set.Remove(title);
        AppSettings.Instance.SetStringList(MinimizedPanesKey, set);
    }

    /// <summary>Re-apply the persisted minimized set at launch. Each still-open, un-minimized, present
    /// pane in the set is minimized (saving its extent); each affected group is solved once.</summary>
    public void ApplySavedMinimizedPanes()
    {
        var saved = AppSettings.Instance.GetStringList(MinimizedPanesKey);
        var affected = new HashSet<SplitGroup>();
        foreach (var title in saved)
        {
            var p = Get(title);
            if (p is null || p.IsMinimized || !p.IsPresent) continue;
            p.SavedThickness = p.Group.CurrentThickness(p);
            p.IsMinimized = true;
            p.Chrome.IsMinimized = true;
            affected.Add(p.Group);
        }
        foreach (var g in affected) g.LayoutSplit();
        foreach (var title in saved) RaiseChanged(title);
    }

    // ── Auto-collapse under pressure ───────────────────────────────────────────────

    internal void OnGroupResized(SplitGroup group)
    {
        if (_autoCollapsing) return;
        if (group.AutoCollapsible) AutoCollapse(group);
    }

    internal void OnSplitterDragged(SplitGroup group)
    {
        // After a manual drag the auto-collapse stack may need to grow or shrink.
        if (group.AutoCollapsible) AutoCollapse(group);
    }

    private void AutoCollapse(SplitGroup group)
    {
        var present = group.PresentPanes;
        if (present.Count <= 1) return;
        double h = group.Orientation == SplitOrientation.Columns ? group.Grid.ActualWidth : group.Grid.ActualHeight;
        if (h <= 50) return;

        _autoCollapsing = true;
        try
        {
            double extent = MinimizedExtent;
            double dividers = (present.Count - 1) * SplitGroup.DividerThickness;
            double Needed() => dividers + present.Sum(p => p.IsMinimized ? extent : ScaledFloor(p.Floor));

            bool changed = false;

            // Squeeze bottom-up: minimize the last non-minimized pane while the column can't fit.
            while (Needed() > h)
            {
                PaneSlot? victim = null;
                for (int i = present.Count - 1; i >= 0; i--)
                    if (!present[i].IsMinimized) { victim = present[i]; break; }
                if (victim is null) break;

                victim.SavedThickness = group.CurrentThickness(victim);
                victim.IsMinimized = true;
                victim.Chrome.IsMinimized = true;
                _autoMinimized.Add(victim.Key);
                changed = true;
            }

            // Relax most-recent-first: restore the top of the stack if it now fits.
            while (_autoMinimized.Count > 0)
            {
                string topKey = _autoMinimized[^1];
                var top = Get(topKey);
                if (top is null || top.Group != group || !top.IsMinimized)
                {
                    _autoMinimized.RemoveAt(_autoMinimized.Count - 1);
                    continue;
                }
                if (Needed() - extent + ScaledFloor(top.Floor) <= h)
                {
                    top.IsMinimized = false;
                    top.Chrome.IsMinimized = false;
                    _autoMinimized.RemoveAt(_autoMinimized.Count - 1);
                    changed = true;
                }
                else break;
            }

            if (changed)
            {
                group.LayoutSplit();
                foreach (var p in present) RaiseChanged(p.Key);
            }
        }
        finally
        {
            _autoCollapsing = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────

    private void RaiseChanged(string key) => PaneStateChanged?.Invoke(this, key);

    private static Dictionary<string, double> One(string key, double value) => new() { [key] = value };

    /// <summary>Remove an element from whatever parent currently hosts it, so it can be re-parented
    /// (WPF forbids two parents). Handles the container kinds a pane glass can land in.</summary>
    internal static void DetachFromParent(FrameworkElement element)
    {
        switch (element.Parent)
        {
            case Panel panel: panel.Children.Remove(element); break;
            case ContentControl cc when ReferenceEquals(cc.Content, element): cc.Content = null; break;
            case Decorator dec when ReferenceEquals(dec.Child, element): dec.Child = null; break;   // covers Border
        }
    }
}
