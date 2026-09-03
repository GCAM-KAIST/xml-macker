using System;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Editor;

/// <summary>
/// The six XML token classes produced by <see cref="ViewportXmlColorizer"/> and mapped to theme brushes by
/// <see cref="SyntaxColors"/>. Order matches the Aurora-Dark token table of the macOS version.
/// </summary>
public enum XmlColorClass : byte
{
    /// <summary>Element text content, <c>XM.syntaxText</c> (mint).</summary>
    Text = 0,
    /// <summary>Element/tag names, <c>XM.syntaxTag</c> (violet).</summary>
    Tag = 1,
    /// <summary>Attribute names, <c>XM.syntaxAttr</c> (aqua).</summary>
    Attr = 2,
    /// <summary>Attribute values, <c>XM.syntaxVal</c> (amber).</summary>
    Val = 3,
    /// <summary>Punctuation <c>&lt; &gt; / = " '</c>, <c>XM.syntaxPunct</c>.</summary>
    Punct = 4,
    /// <summary>Comments / PIs / CDATA, <c>XM.syntaxCom</c>.</summary>
    Com = 5,
}

/// <summary>
/// Token → <see cref="Brush"/> mapping service for the editor hot path. Brushes are resolved once from the active
/// theme's <c>XM.syntax*</c> keys, frozen for cross-thread-free fast reuse, and re-resolved whenever
/// <see cref="ThemeManager.ThemeChanged"/> fires (the WPF analog of <c>SyntaxHighlighter.rebuildColors()</c>).
/// The <see cref="Changed"/> event lets the editor invalidate its render + the colorizer chunk cache.
/// </summary>
public sealed class SyntaxColors
{
    private readonly Brush[] _brushes = new Brush[6];
    private Brush _plainText = Brushes.White;
    private Brush _link = Brushes.DodgerBlue;
    private Pen _linkPen = new(Brushes.DodgerBlue, 1);
    private bool _valid;

    /// <summary>Brush for a value that names an existing file (drawn like a hyperlink): <c>XM.accent</c>.</summary>
    public Brush Link
    {
        get { if (!_valid) Rebuild(); return _link; }
    }

    /// <summary>One-pixel pen in the link colour, for the underline.</summary>
    public Pen LinkPen
    {
        get { if (!_valid) Rebuild(); return _linkPen; }
    }

    /// <summary>Raised after the theme changes so callers can re-render / clear caches.</summary>
    public event EventHandler? Changed;

    public SyntaxColors()
    {
        ThemeManager.ThemeChanged += OnThemeChanged;
    }

    private void OnThemeChanged(object? sender, EventArgs e)
    {
        _valid = false;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Detaches the theme subscription (call when the owning editor is disposed).</summary>
    public void Detach() => ThemeManager.ThemeChanged -= OnThemeChanged;

    /// <summary>Brush for a token class.</summary>
    public Brush For(XmlColorClass c)
    {
        if (!_valid) Rebuild();
        return _brushes[(int)c];
    }

    /// <summary>Brush for uncolored text (offsets outside the colored viewport band): <c>XM.text</c>.</summary>
    public Brush PlainText
    {
        get { if (!_valid) Rebuild(); return _plainText; }
    }

    private void Rebuild()
    {
        _brushes[(int)XmlColorClass.Text] = Freeze(XMColor.Brush(XMColor.SyntaxText));
        _brushes[(int)XmlColorClass.Tag] = Freeze(XMColor.Brush(XMColor.SyntaxTag));
        _brushes[(int)XmlColorClass.Attr] = Freeze(XMColor.Brush(XMColor.SyntaxAttr));
        _brushes[(int)XmlColorClass.Val] = Freeze(XMColor.Brush(XMColor.SyntaxVal));
        _brushes[(int)XmlColorClass.Punct] = Freeze(XMColor.Brush(XMColor.SyntaxPunct));
        _brushes[(int)XmlColorClass.Com] = Freeze(XMColor.Brush(XMColor.SyntaxCom));
        _plainText = Freeze(XMColor.Brush(XMColor.Text));
        _link = Freeze(XMColor.Brush(XMColor.Accent));
        _linkPen = new Pen(_link, 1);
        _linkPen.Freeze();
        _valid = true;
    }

    private static Brush Freeze(Brush b)
    {
        if (b is SolidColorBrush scb)
        {
            var clone = new SolidColorBrush(scb.Color);
            clone.Freeze();
            return clone;
        }
        if (b.CanFreeze && !b.IsFrozen) b.Freeze();
        return b;
    }
}
