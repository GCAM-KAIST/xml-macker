using System.Windows;
using System.Windows.Media;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The 10×10 kind glyph drawn on every tree row (Swift <c>AuroraTreeCell</c> icon <c>CAShapeLayer</c>):
/// <list type="bullet">
/// <item><see cref="NodeKind.Element"/> → filled <b>diamond</b> in <c>syntaxTag</c>, vertices in a 10×10 box.</item>
/// <item><see cref="NodeKind.Text"/> → <b>dot</b> in rect (2,2,6,6), <c>syntaxText</c>.</item>
/// <item><see cref="NodeKind.Comment"/> → <b>square</b> in rect (2,2,6,6), <c>syntaxCom</c>.</item>
/// <item><see cref="NodeKind.Document"/> → larger <b>square</b> in rect (1,1,8,8), <c>text2</c>.</item>
/// </list>
/// AppKit's bottom-left origin doesn't matter here, the diamond is symmetric and the squares/dot
/// are centred, so no Y-flip is needed. Brushes are pulled fresh from the active theme each render;
/// the glyph invalidates on <see cref="ThemeManager.ThemeChanged"/> (only ~visible rows are realized).
/// </summary>
public sealed class KindGlyph : FrameworkElement
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(NodeKind), typeof(KindGlyph),
        new FrameworkPropertyMetadata(NodeKind.Element, FrameworkPropertyMetadataOptions.AffectsRender));

    public NodeKind Kind
    {
        get => (NodeKind)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public KindGlyph()
    {
        Width = 10;
        Height = 10;
        Loaded += (_, _) => ThemeManager.ThemeChanged += OnThemeChanged;
        Unloaded += (_, _) => ThemeManager.ThemeChanged -= OnThemeChanged;
    }

    private void OnThemeChanged(object? sender, EventArgs e) => InvalidateVisual();

    protected override Size MeasureOverride(Size availableSize) => new(10, 10);

    protected override void OnRender(DrawingContext dc)
    {
        switch (Kind)
        {
            case NodeKind.Element:
            {
                var geo = new StreamGeometry();
                using (StreamGeometryContext c = geo.Open())
                {
                    c.BeginFigure(new Point(5, 1), true, true);
                    c.LineTo(new Point(9, 5), true, false);
                    c.LineTo(new Point(5, 9), true, false);
                    c.LineTo(new Point(1, 5), true, false);
                }
                geo.Freeze();
                dc.DrawGeometry(XMColor.Brush(XMColor.SyntaxTag), null, geo);
                break;
            }
            case NodeKind.Text:
                dc.DrawEllipse(XMColor.Brush(XMColor.SyntaxText), null, new Point(5, 5), 3, 3);
                break;
            case NodeKind.Comment:
                dc.DrawRectangle(XMColor.Brush(XMColor.SyntaxCom), null, new Rect(2, 2, 6, 6));
                break;
            case NodeKind.Document:
                dc.DrawRectangle(XMColor.Brush(XMColor.Text2), null, new Rect(1, 1, 8, 8));
                break;
        }
    }
}
