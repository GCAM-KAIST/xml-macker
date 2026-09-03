using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The profiler-style <b>flame graph</b> of the current selection (Swift <c>HierarchyMiniView</c>),
/// custom-drawn in <see cref="OnRender"/>. Three stacked rows, the selected element (row 0, TOP),
/// its child elements (row 1, middle), and grandchildren nested inside each child (row 2, bottom).
/// Because AppKit's origin is bottom-left, the Swift geometry is <b>Y-flipped</b> here: row 0 is the
/// topmost visual row.
///
/// Segment width is proportional to a cheap weight (<c>1 + directElementChildren</c>, never a deep
/// walk, must stay O(children) on 12M-node trees). Tiny stragglers fold into a <c>+N</c> chip
/// (row-1 cap 40, per-parent row-2 cap 12). Hover highlights a segment and shows a tooltip
/// <see cref="Popup"/>; clicking a child navigates down, clicking the selected row (0) navigates up, 
/// both via <see cref="OnChildClicked"/>. Hit-testing walks a stored rect→node list back-to-front.
/// </summary>
public sealed class HierarchyMiniView : FrameworkElement
{
    // Palette hues (cycled across sibling segments), and the preferred key-attribute names.
    private static readonly string[] Palette = { XMColor.Accent, XMColor.SyntaxText, XMColor.SyntaxAttr, XMColor.SyntaxVal };
    private static readonly string[] KeyAttrNames = { "name", "year", "type", "id", "key" };

    private XmlTreeNode? _node;
    private XmlTreeNode? _hoverNode;
    private string? _hoverTip;
    private Rect _hoverRect;

    // Drawn segments (draw order) → hit-tested back-to-front so topmost wins.
    private readonly List<(Rect Rect, XmlTreeNode Node)> _hitRegions = new();
    private readonly List<(Rect Rect, string Tip)> _tipRegions = new();

    private readonly Popup _tip;
    private readonly Border _tipBorder;
    private readonly TextBlock _tipText;

    /// <summary>Fired on a click: a child/grandchild navigates down; the selected row navigates up (to the parent).</summary>
    public event Action<XmlTreeNode>? OnChildClicked;

    public HierarchyMiniView()
    {
        _tipText = new TextBlock
        {
            FontFamily = XMFont.MonoFamily,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.NoWrap,
        };
        _tipBorder = new Border
        {
            Child = _tipText,
            CornerRadius = new CornerRadius(5),
            BorderThickness = new Thickness(0.5),
            Padding = new Thickness(6, 3, 6, 3),
        };
        _tip = new Popup
        {
            Child = _tipBorder,
            AllowsTransparency = true,
            Placement = PlacementMode.Relative,
            PlacementTarget = this,
            IsHitTestVisible = false,
            StaysOpen = true,
        };

        Loaded += (_, _) =>
        {
            ThemeManager.ThemeChanged += OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            StructureFilter.Changed += OnStructureFilterChanged;
            InvalidateVisual();
        };
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
            StructureFilter.Changed -= OnStructureFilterChanged;
            _tip.IsOpen = false;
        };
    }

    /// <summary>Set the selected element (or <c>null</c>); rebuilds the flame graph.</summary>
    public void SetNode(XmlTreeNode? node)
    {
        _node = node;
        _hoverNode = null;
        _hoverTip = null;
        _tip.IsOpen = false;
        InvalidateVisual();
    }

    // ── Intrinsic size ──────────────────────────────────────────────────────────────────────────
    /// <summary>Natural height is <b>120 pt × globalScale</b>; width takes whatever the pane offers.</summary>
    protected override Size MeasureOverride(Size availableSize)
    {
        double w = double.IsInfinity(availableSize.Width) ? 0 : availableSize.Width;
        return new Size(w, XMMetric.S(120));
    }

    // ── Weight & helpers (O(children), never recursive) ──────────────────────────────────────────
    private static int Weight(XmlTreeNode n)
    {
        return 1 + ElementKids(n).Count;
    }

    private static List<XmlTreeNode> ElementKids(XmlTreeNode n)
    {
        return n.Children.Where(c => c.Kind == NodeKind.Element).ToList();
    }

    private static (string Name, string Value)? KeyAttr(XmlTreeNode n)
    {
        foreach ((string Name, string Value) a in n.Attributes)
            foreach (string pref in KeyAttrNames)
                if (a.Name == pref) return a;
        return n.Attributes.Count > 0 ? n.Attributes[0] : null;
    }

    private static string LabelFor(XmlTreeNode n, bool wide)
    {
        if (wide && KeyAttr(n) is { } a) return $"{n.Name} · {a.Value}";
        return n.Name;
    }

    private static Color WithAlpha(Color c, double alpha)
        => Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);

    private double PixelsPerDip()
    {
        try { return VisualTreeHelper.GetDpi(this).PixelsPerDip; }
        catch { return 1.0; }
    }

    // ── Rendering ─────────────────────────────────────────────────────────────────────────────
    protected override void OnRender(DrawingContext dc)
    {
        _hitRegions.Clear();
        _tipRegions.Clear();

        double width = ActualWidth;
        double height = ActualHeight;
        if (width <= 1 || height <= 1) return;

        double ppd = PixelsPerDip();

        // View chrome: bgDeep@0.35 fill, hairline 0.5 stroke, radiusCard (14) corners.
        Color bg = WithAlpha(XMColor.Color(XMColor.BgDeep), 0.35);
        var chromePen = new Pen(new SolidColorBrush(XMColor.Color(XMColor.Hairline)), XMMetric.Hairline);
        double half = XMMetric.Hairline / 2;
        var chromeRect = new Rect(half, half, Math.Max(0, width - XMMetric.Hairline), Math.Max(0, height - XMMetric.Hairline));
        dc.DrawRoundedRectangle(new SolidColorBrush(bg), chromePen, chromeRect, XMMetric.RadiusCard, XMMetric.RadiusCard);

        dc.PushClip(new RectangleGeometry(new Rect(0, 0, width, height), XMMetric.RadiusCard, XMMetric.RadiusCard));
        try
        {
            if (_node is null)
            {
                DrawCentered(dc, "No selection", XMFont.UiFamily, FontWeights.Medium, XMFont.Scaled(10),
                    XMColor.Color(XMColor.Text3), width, height, ppd);
                return;
            }

            DrawFlame(dc, width, height, ppd);
        }
        finally
        {
            dc.Pop();
        }
    }

    private void DrawFlame(DrawingContext dc, double width, double height, double ppd)
    {
        const double pad = 8, rowGap = 3;
        double rowH = Math.Clamp((height - 2 * pad - rowGap * 2) / 3, 20, 30);
        double fullW = width - 2 * pad;
        if (fullW <= 1) return;

        double radius = Math.Min(4, rowH / 4);

        // WPF top-left origin: row 0 is the TOP row (Y-flip of the AppKit geometry).
        double row0Y = pad;
        double row1Y = row0Y + rowGap + rowH;
        double row2Y = row1Y + rowGap + rowH;

        XmlTreeNode node = _node!;

        // ── Row 0, the selected element, full width. ──
        var row0Rect = new Rect(pad, row0Y, fullW, rowH);
        DrawSegment(dc, row0Rect,
            WithAlpha(XMColor.Color(XMColor.SyntaxTag), 0.20),
            WithAlpha(XMColor.Color(XMColor.SyntaxTag), 0.55),
            $"<{LabelFor(node, width > 160)}>", XMColor.Color(XMColor.SyntaxTag), bold: true,
            radius, ppd, node);

        List<XmlTreeNode> allKids = ElementKids(node);

        // ── Leaf case (no element children): one mint bar for the text value. ──
        if (allKids.Count == 0)
        {
            string val = node.TextValue.Replace('\n', ' ').Replace('\r', ' ').Trim();
            bool empty = val.Length == 0;
            string msg = empty ? "(no child elements)" : val;
            var leafRect = new Rect(pad, row1Y, fullW, rowH);
            Color mint = XMColor.Color(XMColor.SyntaxText);
            DrawSegment(dc, leafRect,
                empty ? WithAlpha(mint, 0.06) : WithAlpha(mint, 0.15),
                empty ? WithAlpha(mint, 0.20) : WithAlpha(mint, 0.50),
                msg, empty ? XMColor.Color(XMColor.Text3) : mint, bold: false,
                radius, ppd, null);
            return;
        }

        // ── Row 1, children (width ∝ weight, with folding). ──
        const double gap = 2, minSeg = 26;

        List<XmlTreeNode> kids = StructureFilter.Apply(allKids).ToList();
        int hiddenValues = allKids.Count - kids.Count;
        double valuesWidth = hiddenValues > 0 ? 60 : 0;

        // Precompute each child's weight ONCE (keeps the sort/layout O(children), never O(n²)).
        var wk = new Dictionary<XmlTreeNode, int>(kids.Count);
        int totalWeight = 0;
        foreach (XmlTreeNode k in kids)
        {
            int w = Weight(k);
            wk[k] = w;
            totalWeight += w;
        }
        if (totalWeight <= 0) totalWeight = 1;

        var byWeightDesc = new List<XmlTreeNode>(kids);
        byWeightDesc.Sort((a, b) => wk[b].CompareTo(wk[a]));

        var visible = new List<XmlTreeNode>();
        var folded = new List<XmlTreeNode>();
        foreach (XmlTreeNode k in byWeightDesc)
        {
            double w = (double)wk[k] / totalWeight * Math.Max(1, fullW - valuesWidth);
            if (w >= minSeg && visible.Count < 40) visible.Add(k);
            else folded.Add(k);
        }

        // All-tiny fallback: show as many equal slices as fit, reserving one slot for +N on overflow.
        if (visible.Count == 0 && folded.Count > 0)
        {
            int fitCount = Math.Max(1, (int)Math.Floor(Math.Max(1, fullW - valuesWidth) / (minSeg + gap)));
            bool overflow = folded.Count > fitCount;
            int take = overflow ? Math.Max(1, fitCount - 1) : fitCount;
            take = Math.Min(take, folded.Count);
            visible = folded.GetRange(0, take);
            folded = folded.GetRange(take, folded.Count - take);
        }

        // Re-sort visible back to document (file) order so the map reads left-to-right.
        visible.Sort((a, b) => a.StartLine.CompareTo(b.StartLine));

        double foldW = folded.Count == 0 ? 0 : 34;
        double reserved = foldW + (folded.Count > 0 ? gap : 0)
                          + valuesWidth + (hiddenValues > 0 ? gap : 0);
        double rowW = Math.Max(1, fullW - reserved - gap * Math.Max(0, visible.Count - 1));
        int visWeight = 0;
        foreach (XmlTreeNode k in visible) visWeight += wk[k];
        if (visWeight <= 0) visWeight = 1;

        double maxX = pad + fullW - reserved;
        double x = pad;
        var placed = new List<(XmlTreeNode Kid, Rect Rect, int Hue)>();
        for (int i = 0; i < visible.Count; i++)
        {
            XmlTreeNode kid = visible[i];
            double w = Math.Max(minSeg, (double)wk[kid] / visWeight * rowW);
            if (x + w > maxX) w = maxX - x;
            if (w <= 0) break;

            var rect = new Rect(x, row1Y, w, rowH);
            Color hue = XMColor.Color(Palette[i % 4]);
            DrawSegment(dc, rect,
                WithAlpha(hue, 0.16), WithAlpha(hue, 0.50),
                LabelFor(kid, w > 110), XMColor.Color(XMColor.Text), bold: false,
                radius, ppd, kid);
            placed.Add((kid, rect, i));
            x += w + gap;
        }

        // The +N fold segment fills the remaining width on the right.
        if (folded.Count > 0 && x < pad + fullW)
        {
            double remaining = pad + fullW - x;
            double foldExtent = hiddenValues > 0
                ? Math.Max(minSeg, remaining - valuesWidth - gap)
                : Math.Max(minSeg, remaining);
            var foldRect = new Rect(x, row1Y, Math.Min(foldExtent, remaining), rowH);
            DrawSegment(dc, foldRect,
                XMColor.Color(XMColor.Hairline), XMColor.Color(XMColor.HairlineS),
                $"+{folded.Count}", XMColor.Color(XMColor.Text3), bold: false,
                radius, ppd, null);
            _tipRegions.Add((foldRect, $"{folded.Count} more elements are too small to draw; see Subtags"));
            x += foldRect.Width + gap;
        }

        if (hiddenValues > 0 && x < pad + fullW)
        {
            var valuesRect = new Rect(x, row1Y, pad + fullW - x, rowH);
            DrawValuesSummary(dc, valuesRect, hiddenValues, XMColor.Color(XMColor.SyntaxText), radius, ppd,
                $"{Plural(hiddenValues, "plain value")} hidden by Structure only; see Subtags");
        }

        // ── Row 2, grandchildren (nested inside each visible child's horizontal span). ──
        foreach ((XmlTreeNode kid, Rect kidRect, int i) in placed)
        {
            List<XmlTreeNode> allGrand = ElementKids(kid);
            if (allGrand.Count == 0) continue;

            Color hue = XMColor.Color(Palette[i % 4]);
            List<XmlTreeNode> grand = StructureFilter.Enabled
                ? allGrand.Where(StructureFilter.IsContainer).ToList()
                : allGrand;
            if (grand.Count == 0)
            {
                var valuesRect = new Rect(kidRect.X, row2Y, kidRect.Width, rowH);
                DrawValuesSummary(dc, valuesRect, allGrand.Count, hue, radius, ppd,
                    $"{Plural(allGrand.Count, "plain value")} inside <{kid.Name}>");
                continue;
            }

            int gTotal = 0;
            foreach (XmlTreeNode g in grand) gTotal += Weight(g);
            if (gTotal <= 0) gTotal = 1;

            var gVisible = new List<XmlTreeNode>();
            int gFolded = 0;
            foreach (XmlTreeNode g in grand)
            {
                double w = (double)Weight(g) / gTotal * kidRect.Width;
                if (w >= minSeg && gVisible.Count < 12) gVisible.Add(g);
                else gFolded++;
            }

            // All-tiny grandchildren: one summary segment across the parent's span.
            if (gVisible.Count == 0)
            {
                var sumRect = new Rect(kidRect.X, row2Y, kidRect.Width, rowH);
                DrawSegment(dc, sumRect,
                    WithAlpha(hue, 0.08), WithAlpha(hue, 0.30),
                    $"{grand.Count} × {grand[0].Name}", XMColor.Color(XMColor.Text3), bold: false,
                    radius, ppd, null);
                _tipRegions.Add((sumRect, $"{grand.Count} <{grand[0].Name}> elements inside <{kid.Name}>"));
                continue;
            }

            double gFoldW = gFolded > 0 ? 26 : 0;
            double gRowW = kidRect.Width - gFoldW;
            int gVisWeight = 0;
            foreach (XmlTreeNode g in gVisible) gVisWeight += Weight(g);
            if (gVisWeight <= 0) gVisWeight = 1;

            double gMaxX = kidRect.X + kidRect.Width - gFoldW;
            double gx = kidRect.X;
            for (int j = 0; j < gVisible.Count; j++)
            {
                XmlTreeNode g = gVisible[j];
                double avail = gMaxX - gx;
                if (avail < 10) break; // no room, stop drawing this parent's grandchildren
                double gw = Math.Max(minSeg, (double)Weight(g) / gVisWeight * gRowW);
                if (gw > avail) gw = avail;
                if (gw < 10) break;

                var gRect = new Rect(gx, row2Y, gw, rowH);
                DrawSegment(dc, gRect,
                    WithAlpha(hue, 0.09), WithAlpha(hue, 0.35),
                    LabelFor(g, gw > 110), XMColor.Color(XMColor.Text2), bold: false,
                    radius, ppd, g);
                gx += gw + gap;
            }

            // A +N segment for the folded grandchildren, only if ≥18 pt remain in the parent's span.
            double gRight = kidRect.X + kidRect.Width;
            if (gFolded > 0 && gRight - gx >= 18)
            {
                var gFoldRect = new Rect(gx, row2Y, gRight - gx, rowH);
                DrawSegment(dc, gFoldRect,
                    XMColor.Color(XMColor.Hairline), XMColor.Color(XMColor.HairlineS),
                    $"+{gFolded}", XMColor.Color(XMColor.Text3), bold: false,
                    radius, ppd, null);
                _tipRegions.Add((gFoldRect, $"{gFolded} more elements inside <{kid.Name}>"));
            }
        }
    }

    private void DrawSegment(DrawingContext dc, Rect rect, Color fill, Color stroke,
        string? label, Color labelColor, bool bold, double radius, double ppd, XmlTreeNode? node)
    {
        if (rect.Width <= 0 || rect.Height <= 0) return;

        bool hovered = (node is not null && ReferenceEquals(node, _hoverNode))
                       || (node is null && _hoverTip is not null && _hoverRect == rect);
        Color f = hovered ? WithAlpha(fill, Math.Min(1.0, fill.A / 255.0 + 0.14)) : fill;
        double lw = hovered ? 1.2 : 0.5;

        dc.DrawRoundedRectangle(new SolidColorBrush(f), new Pen(new SolidColorBrush(stroke), lw), rect, radius, radius);

        if (label is not null && rect.Width >= 34)
            DrawLabel(dc, rect, label, labelColor, bold, ppd);

        if (node is not null)
            _hitRegions.Add((rect, node));
    }

    private void DrawValuesSummary(DrawingContext dc, Rect rect, int count, Color hue,
        double radius, double ppd, string tip)
    {
        if (rect.Width < 10) return;
        DrawSegment(dc, rect,
            WithAlpha(hue, 0.06), WithAlpha(hue, 0.25),
            Plural(count, "value"), XMColor.Color(XMColor.Text3), bold: false,
            radius, ppd, null);
        _tipRegions.Add((rect, tip));
    }

    private static string Plural(int count, string word)
        => $"{count} {word}{(count == 1 ? "" : "s")}";

    private void DrawLabel(DrawingContext dc, Rect rect, string label, Color color, bool bold, double ppd)
    {
        const double inset = 4;
        double avail = rect.Width - inset * 2;
        if (avail <= 0) return;

        var tf = new Typeface(XMFont.MonoFamily, FontStyles.Normal,
            bold ? FontWeights.SemiBold : FontWeights.Medium, FontStretches.Normal);
        double size = XMFont.Scaled(10.5);
        string text = MiddleTruncate(label, tf, size, avail, ppd);

        var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            tf, size, new SolidColorBrush(color), ppd);

        double midY = rect.Y + rect.Height / 2;
        double tx = rect.X + inset + (avail - ft.Width) / 2;
        double ty = (midY - 7) + (14 - ft.Height) / 2;
        dc.DrawText(ft, new Point(tx, ty));
    }

    private static double Measure(string s, Typeface tf, double size, double ppd)
    {
        var ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            tf, size, Brushes.Black, ppd);
        return ft.WidthIncludingTrailingWhitespace;
    }

    /// <summary>Truncate <paramref name="s"/> in the MIDDLE with an ellipsis so it fits <paramref name="maxWidth"/>.</summary>
    private static string MiddleTruncate(string s, Typeface tf, double size, double maxWidth, double ppd)
    {
        if (Measure(s, tf, size, ppd) <= maxWidth) return s;
        if (s.Length <= 1) return s;
        const string ell = "…";
        for (int keep = s.Length - 1; keep >= 1; keep--)
        {
            int head = (keep + 1) / 2;
            int tail = keep - head;
            string cand = s.Substring(0, head) + ell + (tail > 0 ? s.Substring(s.Length - tail) : "");
            if (Measure(cand, tf, size, ppd) <= maxWidth) return cand;
        }
        return ell;
    }

    private void DrawCentered(DrawingContext dc, string text, FontFamily family, FontWeight weight,
        double size, Color color, double width, double height, double ppd)
    {
        var tf = new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal);
        var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            tf, size, new SolidColorBrush(color), ppd);
        dc.DrawText(ft, new Point((width - ft.Width) / 2, (height - ft.Height) / 2));
    }

    // ── Hover tooltip ─────────────────────────────────────────────────────────────────────────
    private void UpdateTooltip()
    {
        if ((_hoverNode is null && _hoverTip is null) || _node is null)
        {
            _tip.IsOpen = false;
            return;
        }

        string? tip;
        if (_hoverNode is not null && ReferenceEquals(_hoverNode, _node))
        {
            // Row 0 doubles as an up-button: only tip when there is an element parent to climb to.
            if (_node.Parent is { Kind: NodeKind.Element } p)
                tip = $"↑ up to <{p.Name}>";
            else { _tip.IsOpen = false; return; }
        }
        else if (_hoverNode is not null)
        {
            XmlTreeNode hn = _hoverNode;
            string t = hn.Name;
            if (KeyAttr(hn) is { } a) t += $"  {a.Name}={a.Value}";
            List<XmlTreeNode> hk = ElementKids(hn);
            int groups = hk.Count(StructureFilter.IsContainer);
            if (groups > 0 && groups < hk.Count)
                t += $"  ·  {Plural(groups, "group")} · {Plural(hk.Count - groups, "value")}";
            else if (hk.Count > 0) t += $"  ·  {hk.Count} inside";
            else if (!string.IsNullOrEmpty(hn.TextValue))
                t += $"  =  {hn.TextValue[..Math.Min(24, hn.TextValue.Length)]}";
            tip = t;
        }
        else
        {
            tip = _hoverTip;
        }

        if (string.IsNullOrEmpty(tip))
        {
            _tip.IsOpen = false;
            return;
        }

        double ppd = PixelsPerDip();
        _tipText.FontSize = XMFont.Scaled(10);
        _tipText.Text = tip;
        _tipText.Foreground = new SolidColorBrush(XMColor.Color(XMColor.Text));
        _tipBorder.Background = new SolidColorBrush(WithAlpha(XMColor.Color(XMColor.Bg), 0.94));
        _tipBorder.BorderBrush = new SolidColorBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.60));

        var tf = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        double tw = Measure(tip, tf, XMFont.Scaled(10), ppd) + 12;
        double th = new FormattedText("Xg", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            tf, XMFont.Scaled(10), Brushes.Black, ppd).Height + 6;

        double cx = _hoverRect.X + _hoverRect.Width / 2;
        double x = Math.Clamp(cx - tw / 2, 0, Math.Max(0, ActualWidth - tw));
        double y = _hoverRect.Y - 4 - th;
        if (y < 0) y = _hoverRect.Bottom + 4; // flip below if it would overflow the top

        _tip.HorizontalOffset = x;
        _tip.VerticalOffset = y;
        _tip.IsOpen = true;
    }

    // ── Interaction ─────────────────────────────────────────────────────────────────────────────
    private XmlTreeNode? HitTest(Point p, out Rect rect)
    {
        // Back-to-front: the last-drawn (topmost) region wins.
        for (int i = _hitRegions.Count - 1; i >= 0; i--)
        {
            if (_hitRegions[i].Rect.Contains(p))
            {
                rect = _hitRegions[i].Rect;
                return _hitRegions[i].Node;
            }
        }
        rect = default;
        return null;
    }

    private string? TipHitTest(Point p, out Rect rect)
    {
        for (int i = _tipRegions.Count - 1; i >= 0; i--)
        {
            if (_tipRegions[i].Rect.Contains(p))
            {
                rect = _tipRegions[i].Rect;
                return _tipRegions[i].Tip;
            }
        }
        rect = default;
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Point point = e.GetPosition(this);
        XmlTreeNode? hit = HitTest(point, out Rect rect);
        string? hitTip = hit is null ? TipHitTest(point, out rect) : null;
        if (!ReferenceEquals(hit, _hoverNode) || hitTip != _hoverTip)
        {
            _hoverNode = hit;
            _hoverTip = hitTip;
            _hoverRect = rect;
            UpdateTooltip();
            InvalidateVisual();
        }
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        if (_hoverNode is not null || _hoverTip is not null)
        {
            _hoverNode = null;
            _hoverTip = null;
            _tip.IsOpen = false;
            InvalidateVisual();
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        XmlTreeNode? hit = HitTest(e.GetPosition(this), out _);
        if (hit is null || _node is null) return;

        if (!ReferenceEquals(hit, _node))
        {
            OnChildClicked?.Invoke(hit); // navigate down
        }
        else if (_node.Parent is { Kind: NodeKind.Element } parent)
        {
            OnChildClicked?.Invoke(parent); // row 0 → navigate up
        }
        e.Handled = true;
    }

    // ── Theme / zoom ────────────────────────────────────────────────────────────────────────────
    private void OnThemeChanged(object? sender, EventArgs e)
    {
        UpdateTooltip();
        InvalidateVisual();
    }

    private void OnStructureFilterChanged(object? sender, EventArgs e)
    {
        _hoverNode = null;
        _hoverTip = null;
        _tip.IsOpen = false;
        InvalidateVisual();
    }

    private void OnRebuildFonts(object? sender, EventArgs e)
    {
        InvalidateMeasure();
        UpdateTooltip();
        InvalidateVisual();
    }
}
