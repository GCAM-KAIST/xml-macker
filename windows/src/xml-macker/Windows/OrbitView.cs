using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// The radial "current position" element map. A single owner-drawn
/// <see cref="OnRender"/> pass paints the whole scene AND rebuilds an ordered hit list each frame, 
/// there is no retained sub-view tree. The centered element is a 160-px glass "sun" ringed by a
/// concentric orbit of element-child chips, with sibling dots arcing across the top, a clickable
/// breadcrumb, a footer hint and a bottom-left hover info card.
/// AppKit draws this view in a <b>bottom-left origin</b> (<c>isFlipped == false</c>); WPF is
/// top-left. Every hand-computed <c>y</c> from the Swift is therefore flipped
/// (<c>y_wpf = height − y_appkit</c>) and the polar <c>sin</c> term's sign is flipped
/// (<c>pt = center + (dist·cos θ, −dist·sin θ)</c>)
/// </summary>
public sealed class OrbitView : FrameworkElement
{
    // ---- geometry constants ----
    private const double SunRadius = 96;              // 160-px glass disc (r = 96 → Ø 192 incl. glow reach)
    private const double RingRadiusFactor = 0.325;
    private const double DenseMinPitch = 13;
    private const double SiblingRadiusFactor = 0.47;
    private const int SiblingMax = 36;
    private const double SiblingArcDeg = 100;
    private const double AppearStep = 0.09;
    private const double SpinDecay = 0.62;
    private const double SpinStop = 0.02;
    private const double ScrollNotch = 12;
    private const double WheelDeltaDivisor = 10;      // Windows Delta 120/notch → macOS scrollingDeltaY (risk 20)

    private static readonly string[] KeyAttrOrder = { "name", "year", "type", "id", "key" };

    /// <summary>One rebuilt-each-paint hit target: a rect, the node it maps to and a stable hover key.</summary>
    private readonly struct HitRegion
    {
        public readonly Rect Rect;
        public readonly XmlTreeNode Node;
        public readonly string Key;
        public HitRegion(Rect rect, XmlTreeNode node, string key) { Rect = rect; Node = node; Key = key; }
    }

    private readonly List<HitRegion> _hits = new();

    private XmlTreeNode? _node;
    private string _hoverKey = "";
    private XmlTreeNode? _hoverNode;

    // ring rotation state
    private int _ringStart;
    private double _spinPhase;
    private double _scrollAccum;
    private DispatcherTimer? _spinTimer;

    // appear animation state
    private double _appearProgress = 1;
    private DispatcherTimer? _appearTimer;
    private HitRegion? _pendingClick;
    private Point _mouseDownPoint;
    private double? _ringDragLastAngle;
    private double _ringDragRemainder;
    private bool _ringDragged;

    private double _dpi = 1;

    /// <summary>Left click on any node → host navigates (selects it everywhere, then re-presents orbit).</summary>
    public event Action<XmlTreeNode>? NodeActivated;

    /// <summary>Right click on any node → host opens the quick value editor.</summary>
    public event Action<XmlTreeNode>? NodeEditRequested;

    /// <summary>Measured width of the window's "Structure only" checkbox, so the footer can reserve it.</summary>
    public double StructureToggleWidth { get; set; } = 110;

    /// <summary>The widest a child pill may be, one formula, shared by the spacing maths and the drawing.</summary>
    private static double MaxChipWidth(double w) => Math.Min(174, Math.Max(112, w * 0.26));

    public OrbitView()
    {
        Focusable = true;
        FocusVisualStyle = null;

        // The three render options every other owner-drawn view here already sets. ClipToBounds is the one
        // that stops an over-wide chip painting into the Details rail, whose panel brush is translucent.
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        ClipToBounds = true;
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        ToolTip = "Click a node to navigate · hover for details · ←/→ moves through siblings";
        ThemeManager.ThemeChanged += OnThemeChanged;
        StructureFilter.Changed += OnStructureFilterChanged;
        Unloaded += (_, _) => ThemeManager.ThemeChanged -= OnThemeChanged;
        Unloaded += (_, _) => StructureFilter.Changed -= OnStructureFilterChanged;
    }

    private void OnThemeChanged(object? sender, EventArgs e) => InvalidateVisual();
    private void OnStructureFilterChanged(object? sender, EventArgs e)
    {
        _ringStart = 0;
        InvalidateVisual();
    }

    // ================= public API =================

    /// <summary>
    /// Sets (or clears) the centered element. If the node changed by reference identity, resets the
    /// ring window + spin, clears hover and starts the appear animation. Always repaints.
    /// </summary>
    public void SetNode(XmlTreeNode? node)
    {
        bool changed = !ReferenceEquals(node, _node);
        _node = node;
        if (changed)
        {
            _ringStart = 0;
            _spinPhase = 0;
            _scrollAccum = 0;
            _hoverKey = "";
            _hoverNode = null;
            StartAppear();
        }
        InvalidateVisual();
    }

    // ================= model helpers =================

    private static List<XmlTreeNode> RingChildren(XmlTreeNode n)
        => StructureFilter.Apply(n.Children.Where(c => c.Kind == NodeKind.Element)).ToList();

    public void PageChildren(int direction)
    {
        if (_node is null) return;
        List<XmlTreeNode> children = RingChildren(_node);
        if (children.Count == 0) return;
        int capacity = RingCapacity(Math.Max(1, ActualWidth), Math.Max(1, ActualHeight));
        _ringStart = ((_ringStart + direction * capacity) % children.Count + children.Count) % children.Count;
        StartSpin(direction > 0 ? 0.8 : -0.8);
        InvalidateVisual();
    }

    private static List<XmlTreeNode> Siblings(XmlTreeNode n)
        => SiblingGroup(n).Where(c => !ReferenceEquals(c, n)).ToList();

    private static List<XmlTreeNode> SiblingGroup(XmlTreeNode n)
    {
        if (n.Parent == null) return new List<XmlTreeNode>();
        List<XmlTreeNode> all = n.Parent.Children.Where(c => c.Kind == NodeKind.Element).ToList();
        return StructureFilter.IsContainer(n) ? StructureFilter.Apply(all).ToList() : all;
    }

    private static List<XmlTreeNode> SiblingArcNodes(XmlTreeNode node, int limit)
    {
        List<XmlTreeNode> family = SiblingGroup(node);
        if (family.Count == 0) return new List<XmlTreeNode>();
        int centerIndex = family.FindIndex(candidate => ReferenceEquals(candidate, node));
        if (centerIndex < 0) return Siblings(node).Take(limit).ToList();
        if (family.Count - 1 <= limit) return family.Where(candidate => !ReferenceEquals(candidate, node)).ToList();

        var result = new List<XmlTreeNode>(limit);
        int firstOffset = -(limit / 2);
        for (int offset = firstOffset; offset <= firstOffset + limit; offset++)
        {
            if (offset == 0) continue;
            int index = ((centerIndex + offset) % family.Count + family.Count) % family.Count;
            result.Add(family[index]);
        }
        return result;
    }

    private static List<XmlTreeNode> BreadcrumbChain(XmlTreeNode n)
    {
        var chain = new List<XmlTreeNode>();
        XmlTreeNode? c = n;
        while (c != null && (c.Kind == NodeKind.Element || c.Kind == NodeKind.Document))
        {
            chain.Insert(0, c);
            c = c.Parent;
        }
        return chain;
    }

    private double RingRadius(double w, double h) => Math.Min(w, h) * RingRadiusFactor;

    /// <summary>How many child pills fit the ring at this view's live size, used by the window to decide
    /// whether the Previous/Next page buttons are needed at all.</summary>
    public bool RingIsCrowded()
        => _node is not null
           && RingChildren(_node).Count > RingCapacity(Math.Max(1, ActualWidth), Math.Max(1, ActualHeight));

    private int RingCapacity(double w, double h)
    {
        if (_node is null) return 6;
        List<XmlTreeNode> children = RingChildren(_node);
        int chips = ChipCapacity(children, w, h);
        if (children.Count <= chips) return chips;
        double laneHeight = Math.Max(1, h - 116);
        return Math.Max(chips, Math.Max(2, (int)(laneHeight / DenseMinPitch) * 2));
    }

    private int ChipCapacity(IReadOnlyList<XmlTreeNode> children, double w, double h)
    {
        if (children.Count == 0) return 6;
        double maximum = Math.Min(174, Math.Max(112, w * 0.26));
        double widest = 96;
        foreach (XmlTreeNode child in children)
        {
            string detail = KeyAttr(child) ?? Prefix(child.TextValue, 80);
            double label = FT(Prefix(child.DisplayLabel, 100), XMFont.MonoFamily, 11,
                FontWeights.Medium, Brushes.White).Width;
            double value = FT(Prefix(detail, 100), XMFont.UiFamily, 9.5,
                FontWeights.Normal, Brushes.White).Width;
            widest = Math.Max(widest, Math.Min(maximum, Math.Max(label, value) + 24));
        }
        double requiredChord = widest + 14;
        double radius = RingRadius(w, h);
        for (int candidate = 12; candidate >= 5; candidate--)
            if (2 * radius * Math.Sin(Math.PI / candidate) >= requiredChord) return candidate;
        return 5;
    }

    private bool UsesDenseRing(double w, double h) =>
        _node is not null && RingChildren(_node).Count > ChipCapacity(RingChildren(_node), w, h);

    private double DenseRingRadius(double w, double h) =>
        Math.Max(118, Math.Min(RingRadius(w, h), Math.Min(w * 0.21, Math.Max(1, h - 116) * 0.40)));

    private static string? KeyAttr(XmlTreeNode n)
    {
        foreach (var k in KeyAttrOrder)
            foreach (var a in n.Attributes)
                if (a.Name == k && !string.IsNullOrEmpty(a.Value))
                    return $"{a.Name}=\"{a.Value}\"";
        return null;
    }

    private static double EaseOut(double t) => 1 - Math.Pow(1 - t, 3);

    private static string Prefix(string? s, int n)
    {
        if (string.IsNullOrEmpty(s)) return s ?? "";
        return s.Length <= n ? s : s.Substring(0, n);
    }

    // ================= animation =================

    private void StartAppear()
    {
        _appearProgress = 0;
        _appearTimer ??= MakeTimer(() =>
        {
            _appearProgress += AppearStep;
            if (_appearProgress >= 1) { _appearProgress = 1; _appearTimer!.Stop(); }
            InvalidateVisual();
        });
        _appearTimer!.Stop();
        _appearTimer!.Start();
    }

    private void StartSpin(double phase)
    {
        _spinPhase = phase;
        _spinTimer ??= MakeTimer(() =>
        {
            _spinPhase *= SpinDecay;
            if (Math.Abs(_spinPhase) < SpinStop) { _spinPhase = 0; _spinTimer!.Stop(); }
            InvalidateVisual();
        });
        _spinTimer!.Stop();
        _spinTimer!.Start();
    }

    private static DispatcherTimer MakeTimer(Action tick)
    {
        var t = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 60) };
        t.Tick += (_, _) => tick();
        return t;
    }

    // ================= interaction =================

    private HitRegion? HitTest(Point p)
    {
        for (int i = _hits.Count - 1; i >= 0; i--)
            if (_hits[i].Rect.Contains(p)) return _hits[i];
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Point point = e.GetPosition(this);
        if (Mouse.Captured == this && _ringDragLastAngle is double previous && _node is not null)
        {
            var children = RingChildren(_node);
            int shown = Math.Min(children.Count, RingCapacity(ActualWidth, ActualHeight));
            if (shown > 0)
            {
                var center = new Point(ActualWidth / 2, ActualHeight / 2 + 8);
                double angle = Math.Atan2(-(point.Y - center.Y), point.X - center.X);
                double delta = angle - previous;
                if (delta > Math.PI) delta -= 2 * Math.PI;
                if (delta < -Math.PI) delta += 2 * Math.PI;
                _ringDragLastAngle = angle;
                _ringDragRemainder += delta;
                double slot = 2 * Math.PI / shown;
                int steps = (int)(_ringDragRemainder / slot);
                if (steps != 0)
                {
                    _ringStart = ((_ringStart - steps) % children.Count + children.Count) % children.Count;
                    _ringDragRemainder -= steps * slot;
                }
                _spinPhase = _ringDragRemainder / slot;
                if ((point - _mouseDownPoint).Length > 3) _ringDragged = true;
                InvalidateVisual();
                e.Handled = true;
                return;
            }
        }
        var hit = HitTest(point);
        string key = hit?.Key ?? "";
        if (key != _hoverKey)
        {
            _hoverKey = key;
            _hoverNode = hit?.Node;
            Cursor = hit != null ? Cursors.Hand : Cursors.Arrow;
            InvalidateVisual();
        }
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _hoverKey = "";
        _hoverNode = null;
        Cursor = Cursors.Arrow;
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        Point point = e.GetPosition(this);
        _pendingClick = HitTest(point);
        _mouseDownPoint = point;
        _ringDragged = false;
        _ringDragRemainder = 0;
        _ringDragLastAngle = null;
        if (_node is not null && RingChildren(_node).Count > RingCapacity(ActualWidth, ActualHeight))
        {
            var center = new Point(ActualWidth / 2, ActualHeight / 2 + 8);
            double radius = UsesDenseRing(ActualWidth, ActualHeight)
                ? DenseRingRadius(ActualWidth, ActualHeight) : RingRadius(ActualWidth, ActualHeight);
            double distance = (point - center).Length;
            if (Math.Abs(distance - radius) < 52)
                _ringDragLastAngle = Math.Atan2(-(point.Y - center.Y), point.X - center.X);
        }
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (Mouse.Captured == this) ReleaseMouseCapture();
        _ringDragLastAngle = null;
        _spinPhase = 0;
        if (!_ringDragged && _pendingClick is { } hit) NodeActivated?.Invoke(hit.Node);
        _pendingClick = null;
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseRightButtonDown(e);
        var hit = HitTest(e.GetPosition(this));
        if (hit is { } h) NodeEditRequested?.Invoke(h.Node);
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        if (_node == null) return;
        var kids = RingChildren(_node);
        if (kids.Count <= RingCapacity(ActualWidth, ActualHeight)) return;   // ring not crowded → ignore

        _scrollAccum += e.Delta / WheelDeltaDivisor;
        int steps = (int)(_scrollAccum / ScrollNotch);
        if (steps == 0) return;
        _scrollAccum -= steps * ScrollNotch;

        _ringStart = ((_ringStart - steps) % kids.Count + kids.Count) % kids.Count;   // wraps both ways
        double magnitude = Math.Min(2.0, 0.6 + Math.Abs(steps) * 0.4);
        StartSpin(steps > 0 ? -magnitude : magnitude);
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_node == null) return;
        if (e.Key != Key.Left && e.Key != Key.Right) return;

        var group = SiblingGroup(_node);
        if (group.Count < 2) { NativeMethods.Beep(); e.Handled = true; return; }
        int idx = group.FindIndex(c => ReferenceEquals(c, _node));
        if (idx < 0) { NativeMethods.Beep(); e.Handled = true; return; }

        int next = e.Key == Key.Right
            ? (idx + 1) % group.Count
            : (idx - 1 + group.Count) % group.Count;
        NodeActivated?.Invoke(group[next]);
        e.Handled = true;
    }

    // ================= draw pass =================

    protected override void OnRender(DrawingContext dc)
    {
        _hits.Clear();
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        _dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        dc.DrawRectangle(Fill(XMColor.BgDeep, 1), null, new Rect(0, 0, w, h));

        if (_node == null) { DrawPlaceholder(dc, w, h); return; }

        var center = new Point(w / 2, h / 2 + 8);   // AppKit (midX, midY-8) flipped

        // Radial sun glow behind everything.
        double glow = Math.Min(w, h) * 0.58;
        var rg = new RadialGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            Center = center,
            GradientOrigin = center,
            RadiusX = glow,
            RadiusY = glow,
        };
        rg.GradientStops.Add(new GradientStop(CA(XMColor.SyntaxTag, 0.16), 0));
        rg.GradientStops.Add(new GradientStop(CA(XMColor.Accent, 0.05), 0.4));
        rg.GradientStops.Add(new GradientStop(CA(XMColor.BgDeep, 0.0), 1));
        rg.Freeze();
        dc.DrawEllipse(rg, null, center, glow, glow);

        DrawSiblingArc(dc, center, w, h);
        DrawChildRing(dc, center, w, h);
        DrawSun(dc, center);
        DrawBreadcrumb(dc, w, h);
        DrawFooter(dc, w, h);
        DrawInfoCard(dc, w, h);
    }

    private void DrawPlaceholder(DrawingContext dc, double w, double h)
    {
        DrawCentered(dc, FT("Nothing in orbit", XMFont.UiFamily, 16, FontWeights.SemiBold, Fill(XMColor.Text2, 1)),
                     w / 2, h / 2 - 4);   // AppKit midY+4
        DrawCentered(dc, FT("Select an element in the tree to map it here", XMFont.UiFamily, 12, FontWeights.Normal, Fill(XMColor.Text3, 1)),
                     w / 2, h / 2 + 18);  // AppKit midY-18
    }

    private void DrawSun(DrawingContext dc, Point center)
    {
        double r = SunRadius;
        dc.DrawEllipse(Fill(XMColor.Panel, 0.92), null, center, r, r);

        var outer = new Pen(Fill(XMColor.SyntaxTag, 0.75), 1.5); outer.Freeze();
        dc.DrawEllipse(null, outer, center, r - 0.75, r - 0.75);
        var inner = new Pen(Fill(XMColor.GlassTop, 1), 1); inner.Freeze();
        dc.DrawEllipse(null, inner, center, r - 7, r - 7);

        // Tag name, shrink 16 → 12 pt if it would overflow.
        string label = $"<{_node!.DisplayLabel}>";
        var tagFt = FT(label, XMFont.MonoFamily, 16, FontWeights.SemiBold, Fill(XMColor.SyntaxTag, 1));
        if (tagFt.Width > r * 1.7)
            tagFt = FT(label, XMFont.MonoFamily, 12, FontWeights.SemiBold, Fill(XMColor.SyntaxTag, 1));
        DrawBounded(dc, tagFt, new Rect(center.X - r * 0.84, center.Y - 24, r * 1.68, 20));

        // Count ELEMENT children only. Counting text nodes, comments and CDATA made the sun print
        // "12 children" while the ring drew 3 and the Details rail agreed with the ring, not the sun.
        int elementKids = 0;
        foreach (var c in _node.Children) if (c.Kind == NodeKind.Element) elementKids++;
        string counts = $"{_node.Attributes.Count} {(_node.Attributes.Count == 1 ? "attr" : "attrs")}"
                      + $" · {elementKids} {(elementKids == 1 ? "child" : "children")}";
        DrawBounded(dc, FT(counts, XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1)),
                    new Rect(center.X - r * 0.82, center.Y - 4, r * 1.64, 16));

        double y = center.Y + 26;               // AppKit center.y-26, step -15 → WPF +15
        int drawn = 0;
        foreach (var a in _node.Attributes)
        {
            if (drawn >= 2) break;
            string s = $"{a.Name}=\"{a.Value}\"";
            var ft = FT(s, XMFont.MonoFamily, 10, FontWeights.Normal, Fill(XMColor.Text2, 1));
            // Do NOT skip a long attribute, silently dropping one is worse than showing it shortened.
            DrawBounded(dc, ft, new Rect(center.X - r * 0.79, y - 7, r * 1.58, 14));
            y += 15;
            drawn++;
        }

        _hits.Add(new HitRegion(new Rect(center.X - r, center.Y - r, r * 2, r * 2), _node, "sun"));
    }

    private void DrawChildRing(DrawingContext dc, Point center, double w, double h)
    {
        var kids = RingChildren(_node!);
        if (kids.Count == 0) return;

        int cap = RingCapacity(w, h);
        int shown = Math.Min(kids.Count, cap);
        if (UsesDenseRing(w, h))
        {
            DrawDenseRing(dc, center, w, h, kids, shown);
            return;
        }

        double rr = RingRadius(w, h);
        var dash = new Pen(Fill(XMColor.Hairline, 1), 1) { DashStyle = new DashStyle(new double[] { 2, 5 }, 0) };
        dash.Freeze();
        dc.DrawEllipse(null, dash, center, rr, rr);
        double slotAngle = 2 * Math.PI / shown;
        double spinOffset = _spinPhase * slotAngle;
        double appear = EaseOut(_appearProgress);

        for (int i = 0; i < shown; i++)
        {
            var kid = kids[(_ringStart + i) % kids.Count];
            double angle = -Math.PI / 2 + i * slotAngle + spinOffset;   // slot 0 at bottom, CCW
            double dist = rr * (0.82 + 0.18 * appear);
            var pt = new Point(center.X + dist * Math.Cos(angle), center.Y - dist * Math.Sin(angle));
            string detail = KeyAttr(kid) ?? Prefix(kid.TextValue, 20);
            DrawChip(dc, pt, kid.DisplayLabel, detail, XMColor.SyntaxText, appear, kid, $"child-{kid.Id}");
        }
    }

    private sealed record DenseItem(XmlTreeNode Node, double Angle, Point Dot);

    private void DrawDenseRing(DrawingContext dc, Point center, double w, double h,
        IReadOnlyList<XmlTreeNode> children, int shown)
    {
        double radius = DenseRingRadius(w, h);
        var dash = new Pen(Fill(XMColor.Hairline, 1), 1)
            { DashStyle = new DashStyle(new double[] { 2, 5 }, 0) };
        dash.Freeze();
        dc.DrawEllipse(null, dash, center, radius, radius);

        double slot = 2 * Math.PI / shown;
        var items = new List<DenseItem>(shown);
        for (int i = 0; i < shown; i++)
        {
            XmlTreeNode child = children[(_ringStart + i) % children.Count];
            double angle = -Math.PI / 2 + i * slot;
            items.Add(new DenseItem(child, angle,
                new Point(center.X + radius * Math.Cos(angle), center.Y - radius * Math.Sin(angle))));
        }

        bool sameTag = children.Select(child => child.Name).Distinct(StringComparer.Ordinal).Take(2).Count() == 1;
        List<DenseItem> right = items.Where(item => Math.Cos(item.Angle) >= 0)
            .OrderBy(item => item.Dot.Y).ToList();
        List<DenseItem> left = items.Where(item => Math.Cos(item.Angle) < 0)
            .OrderBy(item => item.Dot.Y).ToList();
        DrawDenseColumn(dc, center, w, h, radius, right, true, sameTag);
        DrawDenseColumn(dc, center, w, h, radius, left, false, sameTag);
    }

    private void DrawDenseColumn(DrawingContext dc, Point center, double w, double h, double radius,
        IReadOnlyList<DenseItem> items, bool right, bool sameTag)
    {
        if (items.Count == 0) return;
        double laneTop = 76;
        double laneBottom = h - 40;
        double laneHeight = Math.Max(1, laneBottom - laneTop);
        double pitch = Math.Min(28, laneHeight / items.Count);
        double rowHeight = Math.Max(12, Math.Min(22, pitch - 2));
        double fontSize = rowHeight >= 17 ? 10 : 9;
        double standOff = 34;
        double innerX = right ? center.X + radius + standOff : center.X - radius - standOff;
        double outerX = right ? w - 14 : 14;
        double width = Math.Max(24, Math.Abs(outerX - innerX));

        // On a narrow window this column can collapse to about seven characters, which is where the
        // wrapping was catastrophic. Recover space by halving the stand-off from the ring.
        if (width < 96)
        {
            standOff = 18;
            innerX = right ? center.X + radius + standOff : center.X - radius - standOff;
            width = Math.Max(24, Math.Abs(outerX - innerX));
        }
        double blockHeight = pitch * items.Count;
        double top = Math.Max(laneTop, Math.Min(laneBottom - blockHeight, center.Y - blockHeight / 2));
        double rowCenter = top + pitch / 2;
        double appear = EaseOut(_appearProgress);

        foreach (DenseItem item in items)
        {
            var rect = new Rect(right ? innerX : innerX - width, rowCenter - rowHeight / 2,
                width, rowHeight);
            string key = $"child-{item.Node.Id}";
            bool hovered = _hoverKey == key;
            var stub = new Point(center.X + (radius + 10) * Math.Cos(item.Angle),
                center.Y - (radius + 10) * Math.Sin(item.Angle));
            var edge = new Point(right ? rect.Left - 5 : rect.Right + 5, rowCenter);
            var geometry = new StreamGeometry();
            using (StreamGeometryContext context = geometry.Open())
            {
                context.BeginFigure(item.Dot, false, false);
                context.LineTo(stub, true, false);
                context.LineTo(edge, true, false);
            }
            geometry.Freeze();
            var leader = new Pen(hovered ? Fill(XMColor.Accent, appear) : Fill(XMColor.HairlineS, appear),
                hovered ? 1.2 : 0.6);
            leader.Freeze();
            dc.DrawGeometry(null, leader, geometry);

            double dotRadius = hovered ? 4.5 : 3;
            dc.DrawEllipse(hovered ? Fill(XMColor.Accent, appear) : Fill(XMColor.SyntaxText, appear),
                null, item.Dot, dotRadius, dotRadius);
            var hitRect = new Rect(rect.X - 4, rect.Y - 1, rect.Width + 8, rect.Height + 2);
            if (hovered) dc.DrawRoundedRectangle(Fill(XMColor.Accent, 0.14), null, hitRect, 5, 5);

            string value = item.Node.Attributes.FirstOrDefault(attribute => attribute.Value.Length > 0).Value;
            if (string.IsNullOrEmpty(value)) value = Prefix(item.Node.TextValue, 60);
            string label = string.IsNullOrEmpty(value) ? item.Node.DisplayLabel
                : sameTag ? value : $"{item.Node.DisplayLabel} · {value}";
            var text = FT(label, XMFont.MonoFamily, fontSize, FontWeights.Medium,
                hovered ? Fill(XMColor.Text, appear) : Fill(XMColor.Text2, appear));
            // Bound to ONE line inside the row, and mirror the alignment: labels in the LEFT column are
            // right-aligned so they sit beside their own leader line instead of hugging the window edge
            // 168 pixels away from it. A 6-pixel gutter keeps the glyphs off the leader.
            DrawBounded(dc, text,
                new Rect(rect.X + (right ? 0 : 6), rect.Y, Math.Max(1, rect.Width - 6), rect.Height),
                right ? TextAlignment.Left : TextAlignment.Right);
            _hits.Add(new HitRegion(hitRect, item.Node, key));
            _hits.Add(new HitRegion(new Rect(item.Dot.X - 8, item.Dot.Y - 8, 16, 16), item.Node, key));
            rowCenter += pitch;
        }
    }

    private void DrawSiblingArc(DrawingContext dc, Point center, double w, double h)
    {
        List<XmlTreeNode> allSiblings = Siblings(_node!);
        if (allSiblings.Count == 0) return;

        double radius = Math.Min(w, h) * SiblingRadiusFactor;
        List<XmlTreeNode> sibs = SiblingArcNodes(_node!, SiblingMax);
        int shown = sibs.Count;
        double arc = SiblingArcDeg * Math.PI / 180;
        double start = Math.PI / 2 + arc / 2;

        for (int i = 0; i < shown; i++)
        {
            var sib = sibs[i];
            double t = shown == 1 ? 0.5 : (double)i / (shown - 1);
            double angle = start - arc * t;
            var pt = new Point(center.X + radius * Math.Cos(angle), center.Y - radius * Math.Sin(angle));

            bool hovered = _hoverKey == $"sib-{sib.Id}";
            double dotR = hovered ? 7 : 4.5;
            Brush fill = hovered ? Fill(XMColor.Accent, 1) : Fill(XMColor.Text3, 0.55);
            dc.DrawEllipse(fill, null, pt, dotR, dotR);

            var hit = new Rect(pt.X - dotR - 6, pt.Y - dotR - 6, (dotR + 6) * 2, (dotR + 6) * 2);
            _hits.Add(new HitRegion(hit, sib, $"sib-{sib.Id}"));
        }

        if (allSiblings.Count > shown)
        {
            int extra = allSiblings.Count - shown;
            DrawCentered(dc, FT($"+{extra} siblings", XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1)),
                         center.X, center.Y - (radius - 26));   // AppKit center.y + radius - 26
        }
    }

    private void DrawChip(DrawingContext dc, Point pt, string label, string detail,
                          string accentKey, double alpha, XmlTreeNode node, string key)
    {
        bool hovered = _hoverKey == key;
        bool hasDetail = !string.IsNullOrEmpty(detail);

        var labelFt = FT(label, XMFont.MonoFamily, 11, hovered ? FontWeights.SemiBold : FontWeights.Medium, Fill(XMColor.Text, alpha));
        FormattedText? detFt = hasDetail
            ? FT(detail, XMFont.UiFamily, 9.5, FontWeights.Normal, Fill(XMColor.Text3, alpha))
            : null;

        double labelW = labelFt.Width;
        double detW = detFt?.Width ?? 0;
        // Cap the pill at the SAME width the ring-spacing maths assumed. Without the cap a long attribute
        // value produced a pill several hundred pixels wide on a ring spaced for 188, so neighbours overlapped.
        double cw = Math.Min(MaxChipWidth(ActualWidth), Math.Max(96, Math.Max(labelW, detW) + 24));
        double ch = hasDetail ? 44 : 32;
        double grow = hovered ? 3 : 0;
        var rect = new Rect(pt.X - cw / 2 - grow, pt.Y - ch / 2 - grow, cw + 2 * grow, ch + 2 * grow);
        double corner = ch / 2.8;

        Brush fill = Fill(XMColor.Panel, (hovered ? 0.98 : 0.80) * alpha);
        Pen stroke = hovered ? new Pen(Fill(XMColor.Accent, 1), 1.2) : new Pen(Fill(accentKey, 0.45 * alpha), 0.8);
        stroke.Freeze();
        dc.DrawRoundedRectangle(fill, stroke, rect, corner, corner);

        double contentX = rect.X + 9 + grow;
        double contentW = Math.Max(1, rect.Width - 18 - 2 * grow);
        if (hasDetail)
        {
            DrawBounded(dc, labelFt, new Rect(contentX, pt.Y - 18, contentW, 17));
            DrawBounded(dc, detFt!, new Rect(contentX, pt.Y + 1, contentW, 15));
        }
        else
        {
            DrawBounded(dc, labelFt, new Rect(contentX, pt.Y - 9, contentW, 18));
        }

        _hits.Add(new HitRegion(rect, node, key));
    }

    private void DrawBreadcrumb(DrawingContext dc, double w, double h)
    {
        var chain = BreadcrumbChain(_node!);
        double yA = h - 34;
        double x = 16;
        bool collapsedDrawn = false;

        for (int i = 0; i < chain.Count; i++)
        {
            var n = chain[i];
            bool isLast = i == chain.Count - 1;
            if (collapsedDrawn && !isLast) continue;

            var probe = FT(n.DisplayLabel, XMFont.MonoFamily, 11, isLast ? FontWeights.SemiBold : FontWeights.Normal, Fill(XMColor.Text2, 1));
            if (!isLast && x + probe.Width > w - 140)
            {
                if (!collapsedDrawn)
                {
                    var col = FT("… ▸ ", XMFont.MonoFamily, 11, FontWeights.Normal, Fill(XMColor.Text3, 1));
                    DrawBL(dc, col, x, yA, h);
                    x += col.WidthIncludingTrailingWhitespace;
                    collapsedDrawn = true;
                }
                continue;
            }

            bool hovered = _hoverKey == $"crumb-{n.Id}";
            Brush brush = isLast ? Fill(XMColor.SyntaxTag, 1) : (hovered ? Fill(XMColor.Accent, 1) : Fill(XMColor.Text2, 1));
            var ft = FT(n.DisplayLabel, XMFont.MonoFamily, 11, isLast ? FontWeights.SemiBold : FontWeights.Normal, brush);
            DrawBL(dc, ft, x, yA, h);

            double topWpf = h - yA - ft.Height;
            var hitRect = new Rect(x - 2, topWpf - 4, ft.Width + 4, ft.Height + 8);
            _hits.Add(new HitRegion(hitRect, n, $"crumb-{n.Id}"));

            x += ft.Width;
            if (!isLast)
            {
                var sep = FT("  ▸  ", XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1));
                DrawBL(dc, sep, x, yA + 1, h);
                x += sep.WidthIncludingTrailingWhitespace;
            }
        }

        // "↑ parent" pill pinned top-right when the parent is an element.
        var parent = _node!.Parent;
        if (parent != null && parent.Kind == NodeKind.Element)
        {
            bool hovered = _hoverKey == "up";
            var ft = FT($"↑ {parent.DisplayLabel}", XMFont.UiFamily, 11, FontWeights.SemiBold, hovered ? Fill(XMColor.Text, 1) : Fill(XMColor.Accent, 1));
            double pw = ft.Width;
            double rectX = w - pw - 34;
            double rectYA = yA - 6;
            double rectW = pw + 22;
            double rectH = 24;
            var rect = new Rect(rectX, h - (rectYA + rectH), rectW, rectH);

            var pen = new Pen(Fill(XMColor.Accent, 0.5), 0.8); pen.Freeze();
            dc.DrawRoundedRectangle(Fill(XMColor.Accent, hovered ? 0.35 : 0.16), pen, rect, 12, 12);
            DrawCentered(dc, ft, rect.X + rectW / 2, rect.Y + rectH / 2);
            _hits.Add(new HitRegion(rect, parent, "up"));
        }
    }

    private void DrawFooter(DrawingContext dc, double w, double h)
    {
        var kids = RingChildren(_node!);
        int cap = RingCapacity(w, h);
        string left = kids.Count > cap
            ? $"{kids.Count} children, scroll to rotate the ring"
            : kids.Count > 0
                ? $"{kids.Count} {(kids.Count == 1 ? "child" : "children")}"
                : "leaf element, no children";
        // The right-hand hint used to be drawn at w - width - 16, which is exactly where the window puts
        // the "Structure only" checkbox and the page buttons, the words physically overlapped. It now
        // lives on the view's ToolTip instead, and the left status is bounded so it cannot run under the
        // chrome either.
        double trailingReserve = 150 + StructureToggleWidth;
        DrawBounded(dc, FT(left, XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1)),
                    new Rect(16, h - 28, Math.Max(1, w - trailingReserve - 16), 16), TextAlignment.Left);
    }

    private void DrawInfoCard(DrawingContext dc, double w, double h)
    {
        if (_hoverNode == null || _hoverKey == "sun") return;
        var n = _hoverNode;

        var lines = new List<FormattedText>
        {
            FT($"<{n.DisplayLabel}>", XMFont.MonoFamily, 12, FontWeights.SemiBold, Fill(XMColor.SyntaxTag, 1)),
            FT($"lines {n.StartLine}-{n.EndLine}", XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1)),
        };
        int attrShown = Math.Min(5, n.Attributes.Count);
        for (int i = 0; i < attrShown; i++)
        {
            var a = n.Attributes[i];
            lines.Add(FT($"{a.Name} = {Prefix(a.Value, 36)}", XMFont.MonoFamily, 10.5, FontWeights.Normal, Fill(XMColor.Text2, 1)));
        }
        if (n.Attributes.Count > 5)
            lines.Add(FT($"+{n.Attributes.Count - 5} more attributes", XMFont.UiFamily, 10, FontWeights.Normal, Fill(XMColor.Text3, 1)));
        if (!string.IsNullOrEmpty(n.TextValue))
            lines.Add(FT($"\"{Prefix(n.TextValue, 36)}\"", XMFont.MonoFamily, 10.5, FontWeights.Normal, Fill(XMColor.SyntaxText, 1)));

        const double pad = 12;
        const double lineH = 17;
        double longest = lines.Count == 0 ? 0 : lines.Max(l => l.Width);
        // Clamp to the CANVAS as well as to 340: on a narrow Orbit the card could be wider than the view.
        double width = Math.Min(Math.Min(340, Math.Max(160, w - 32)), Math.Max(160, longest + 2 * pad));
        double height = lines.Count * lineH + 2 * pad - 4;

        var rect = new Rect(16, h - (34 + height), width, height);   // AppKit (16, 34, w, h)
        var pen = new Pen(Fill(XMColor.HairlineS, 1), 0.8); pen.Freeze();
        dc.DrawRoundedRectangle(Fill(XMColor.Panel, 0.96), pen, rect, 10, 10);

        double firstYA = (34 + height) - pad - 12;   // AppKit top-down from rect.maxY - pad - 12
        for (int i = 0; i < lines.Count; i++)
        {
            double yA = firstYA - i * lineH;
            DrawBL(dc, lines[i], 16 + pad, yA, h);
        }
    }

    // ================= draw helpers =================

    /// <summary>Draws <paramref name="ft"/> centered on (<paramref name="cx"/>, <paramref name="cyWpf"/>).</summary>
    private void DrawCentered(DrawingContext dc, FormattedText ft, double cx, double cyWpf)
        => dc.DrawText(ft, new Point(cx - ft.Width / 2, cyWpf - ft.Height / 2));

    /// <summary>
    /// Draws <paramref name="ft"/> so it can never leave <paramref name="box"/>: one line, ellipsised
    /// when too long, vertically centred inside the box.
    /// <para>MaxLineCount = 1 is the load-bearing line. In WPF a FormattedText that has a MaxTextWidth but
    /// the default line count of int.MaxValue WRAPS onto extra lines, and trimming is only applied to the
    /// last PERMITTED line, so setting MaxTextWidth and Trimming alone (what the Orbit labels did) never
    /// produced an ellipsis. The surplus lines simply spilled onto the rows above and below, which is
    /// exactly the jumbled text down the sides of the Orbit.</para>
    /// </summary>
    private void DrawBounded(DrawingContext dc, FormattedText ft, Rect box,
                             TextAlignment align = TextAlignment.Center)
    {
        if (box.Width <= 0 || box.Height <= 0) return;
        ft.MaxTextWidth = box.Width;     // wrap width, must be set BEFORE the line cap
        ft.MaxLineCount = 1;             // one line only; now trimming can actually fire
        ft.Trimming = TextTrimming.CharacterEllipsis;
        ft.TextAlignment = align;
        dc.DrawText(ft, new Point(box.X, box.Y + Math.Max(0, (box.Height - ft.Height) / 2)));
    }

    /// <summary>
    /// Draws <paramref name="ft"/> at AppKit bottom-left point (<paramref name="x"/>, <paramref name="yA"/>).
    /// The point is the text's lower-left corner in bottom-left coords, so the WPF top is
    /// <c>height − yA − textHeight</c>.
    /// </summary>
    private void DrawBL(DrawingContext dc, FormattedText ft, double x, double yA, double h)
        => dc.DrawText(ft, new Point(x, h - yA - ft.Height));

    private FormattedText FT(string text, FontFamily family, double size, FontWeight weight, Brush brush)
        => new(text ?? "", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
               new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal),
               XMFont.Scaled(size), brush, _dpi);

    private static Brush Fill(string key, double alpha)
    {
        var c = XMColor.Color(key);
        alpha = Math.Clamp(alpha, 0, 1);
        var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B));
        b.Freeze();
        return b;
    }

    private static Color CA(string key, double alpha)
    {
        var c = XMColor.Color(key);
        alpha = Math.Clamp(alpha, 0, 1);
        return Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B);
    }
}
