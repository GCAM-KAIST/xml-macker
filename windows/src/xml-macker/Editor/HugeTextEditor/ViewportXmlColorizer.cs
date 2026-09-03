using System;
using System.Collections.Generic;
using System.Windows.Threading;

namespace XMLMacker.Editor;

/// <summary>One classified run of text: <c>[Start, Start+Length)</c> is colored as <see cref="Class"/>.</summary>
public readonly struct ColorRun
{
    public readonly int Start;
    public readonly int Length;
    public readonly XmlColorClass Class;
    public ColorRun(int start, int length, XmlColorClass cls)
    {
        Start = start;
        Length = length;
        Class = cls;
    }
}

/// <summary>
/// Viewport-only XML syntax colorizer, the port of Swift <c>SyntaxHighlighter</c>. It colors ONLY the visible
/// char range (± a 2048-char overscroll pad), caches results per 4096-char chunk (<see cref="_coloredChunks"/>),
/// and recovers the tokenizer mode with a 512-char look-behind at each chunk boundary. Coloring the whole 655 MB
/// file would be pointless and slow; only the tens of KB around the viewport are ever tokenized.
///
/// <para>Coloring is computed synchronously on demand (cheap, chunk-cached) so the first paint after a jump is
/// colored; a 50 ms throttle then coalesces re-color requests from rapid scrolling/typing into a single repaint
/// via <see cref="RepaintRequested"/>.</para>
///
/// <para>Because runs are cached by absolute offset, ANY edit shifts later offsets, so an edit clears the whole
/// (viewport-sized, evicted) cache rather than trying to patch offsets. Re-coloring the viewport is trivial.</para>
/// </summary>
public sealed class ViewportXmlColorizer
{
    private const int ChunkSize = 4096;
    private const int Pad = 2048;
    private const int LookBehind = 512;

    private enum Mode { Text, OpenTag, CloseTag, AttrName, AttrEq, AttrVal, Comment, PI }

    private readonly ITextBuffer _buffer;
    private readonly HashSet<int> _coloredChunks = new();
    private readonly Dictionary<int, List<ColorRun>> _chunkRuns = new();
    private readonly DispatcherTimer _throttle;

    /// <summary>Raised (throttled, 50 ms) to ask the editor to repaint after scroll/edit settles.</summary>
    public event EventHandler? RepaintRequested;

    public ViewportXmlColorizer(ITextBuffer buffer)
    {
        _buffer = buffer;
        _throttle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _throttle.Tick += (_, __) =>
        {
            _throttle.Stop();
            RepaintRequested?.Invoke(this, EventArgs.Empty);
        };
    }

    /// <summary>Schedules a repaint after 50 ms of quiet (scroll / clip-bounds change).</summary>
    public void ScheduleColorVisible()
    {
        _throttle.Stop();
        _throttle.Start();
    }

    /// <summary>Drops the entire cache (edit invalidation, tab rebind, or theme recolor) and schedules a repaint.</summary>
    public void InvalidateAll()
    {
        _coloredChunks.Clear();
        _chunkRuns.Clear();
        ScheduleColorVisible();
    }

    /// <summary>
    /// Ensures every chunk overlapping <c>[visStart-2048, visEnd+2048]</c> is colored, and evicts chunks far outside
    /// that window so the cache stays viewport-sized. Cheap and idempotent, called synchronously from render.
    /// </summary>
    public void EnsureColored(int visStart, int visEnd)
    {
        int total = _buffer.Length;
        if (total == 0) { _coloredChunks.Clear(); _chunkRuns.Clear(); return; }

        int start = Math.Max(0, visStart - Pad);
        int end = Math.Min(total, visEnd + Pad);
        if (end <= start) return;

        int firstChunk = start / ChunkSize;
        int lastChunk = (end - 1) / ChunkSize;

        // Evict chunks outside a generous window around the visible band.
        if (_coloredChunks.Count > 0)
        {
            int keepLo = firstChunk - 8;
            int keepHi = lastChunk + 8;
            _stale.Clear();
            foreach (int c in _coloredChunks)
                if (c < keepLo || c > keepHi) _stale.Add(c);
            foreach (int c in _stale)
            {
                _coloredChunks.Remove(c);
                _chunkRuns.Remove(c);
            }
        }

        for (int c = firstChunk; c <= lastChunk; c++)
            if (!_coloredChunks.Contains(c))
                ColorChunk(c, total);
    }

    private readonly List<int> _stale = new();

    /// <summary>Returns the colored runs overlapping <c>[start, end)</c>, clipped to that span. Uncolored gaps are omitted.</summary>
    public void GetRuns(int start, int end, List<ColorRun> output)
    {
        output.Clear();
        if (end <= start) return;
        int firstChunk = start / ChunkSize;
        int lastChunk = (end - 1) / ChunkSize;
        for (int c = firstChunk; c <= lastChunk; c++)
        {
            if (!_chunkRuns.TryGetValue(c, out var runs)) continue;
            foreach (ColorRun r in runs)
            {
                int s = Math.Max(start, r.Start);
                int e = Math.Min(end, r.Start + r.Length);
                if (e > s) output.Add(new ColorRun(s, e - s, r.Class));
            }
        }
    }

    private void ColorChunk(int chunkIndex, int total)
    {
        int chunkStart = chunkIndex * ChunkSize;
        int chunkEnd = Math.Min(total, chunkStart + ChunkSize);
        if (chunkEnd <= chunkStart) { _coloredChunks.Add(chunkIndex); return; }

        // Recover the tokenizer mode by scanning up to 512 chars of look-behind with no run output.
        int lbStart = Math.Max(0, chunkStart - LookBehind);
        Mode mode = Mode.Text;
        char quote = '"';
        if (lbStart < chunkStart)
        {
            string lb = _buffer.Substring(lbStart, chunkStart - lbStart);
            Scan(lb, 0, lb.Length, ref mode, ref quote, null, 0);
        }

        string chunk = _buffer.Substring(chunkStart, chunkEnd - chunkStart);
        var runs = new List<ColorRun>();
        Scan(chunk, 0, chunk.Length, ref mode, ref quote, runs, chunkStart);

        _chunkRuns[chunkIndex] = runs;
        _coloredChunks.Add(chunkIndex);
    }

    private static XmlColorClass ModeDefaultColor(Mode m) => m switch
    {
        Mode.Text => XmlColorClass.Text,
        Mode.OpenTag => XmlColorClass.Tag,
        Mode.CloseTag => XmlColorClass.Tag,
        Mode.AttrName => XmlColorClass.Attr,
        Mode.AttrEq => XmlColorClass.Punct,
        Mode.AttrVal => XmlColorClass.Val,
        Mode.Comment => XmlColorClass.Com,
        Mode.PI => XmlColorClass.Com,
        _ => XmlColorClass.Text,
    };

    private static bool IsWs(char c) => c == ' ' || c == '\t' || c == '\r' || c == '\n';

    /// <summary>
    /// Single-pass token classifier (port of <c>SyntaxHighlighter.scan</c>). Walks <c>[from, to)</c> of
    /// <paramref name="s"/> starting in <paramref name="mode"/>, batching same-color runs and emitting them into
    /// <paramref name="runs"/> (when non-null) with absolute offsets <c>baseOff + localIndex</c>. When
    /// <paramref name="runs"/> is null it only advances the mode (look-behind recovery).
    /// </summary>
    private static void Scan(string s, int from, int to, ref Mode mode, ref char quote,
                            List<ColorRun>? runs, int baseOff)
    {
        int runStart = from;
        XmlColorClass runColor = ModeDefaultColor(mode);

        void Flush(int upTo)
        {
            if (runs is not null && upTo > runStart)
                runs.Add(new ColorRun(baseOff + runStart, upTo - runStart, runColor));
            runStart = upTo;
        }

        void Emit(int start, int len, XmlColorClass cls)
        {
            if (runs is not null && len > 0)
                runs.Add(new ColorRun(baseOff + start, len, cls));
        }

        int i = from;
        while (i < to)
        {
            char c = s[i];
            switch (mode)
            {
                case Mode.Text:
                    if (c == '<')
                    {
                        // Comment: <!--
                        if (i + 3 < to && s[i + 1] == '!' && s[i + 2] == '-' && s[i + 3] == '-')
                        {
                            Flush(i);
                            runColor = XmlColorClass.Com;
                            runStart = i;
                            mode = Mode.Comment;
                            i += 4;
                            continue;
                        }
                        // Processing instruction: <?
                        if (i + 1 < to && s[i + 1] == '?')
                        {
                            Flush(i);
                            runColor = XmlColorClass.Com;
                            runStart = i;
                            mode = Mode.PI;
                            i += 2;
                            continue;
                        }
                        // Close tag: </
                        if (i + 1 < to && s[i + 1] == '/')
                        {
                            Flush(i);
                            Emit(i, 2, XmlColorClass.Punct); // the "</"
                            mode = Mode.CloseTag;
                            runColor = XmlColorClass.Tag;
                            i += 2;
                            runStart = i;
                            continue;
                        }
                        // Plain open tag: <
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct); // the "<"
                        mode = Mode.OpenTag;
                        runColor = XmlColorClass.Tag;
                        i += 1;
                        runStart = i;
                        continue;
                    }
                    // ordinary text content
                    runColor = XmlColorClass.Text;
                    i++;
                    continue;

                case Mode.OpenTag: // reading the tag name
                    if (IsWs(c))
                    {
                        Flush(i);              // flush the accumulated name (runColor == Tag)
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.AttrName;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Attr;
                        continue;
                    }
                    if (c == '/')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        i++;
                        runStart = i;
                        continue;
                    }
                    if (c == '>')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.Text;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    runColor = XmlColorClass.Tag;
                    i++;
                    continue;

                case Mode.AttrName:
                    if (c == '>')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.Text;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    if (c == '/')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.OpenTag; // self-close slash before '>'
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Tag;
                        continue;
                    }
                    if (c == '=')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.AttrEq;
                        i++;
                        runStart = i;
                        continue;
                    }
                    if (IsWs(c))
                    {
                        Flush(i);
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Attr;
                        continue;
                    }
                    runColor = XmlColorClass.Attr;
                    i++;
                    continue;

                case Mode.AttrEq:
                    if (c == '"' || c == '\'')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct); // opening quote
                        quote = c;
                        mode = Mode.AttrVal;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Val;
                        continue;
                    }
                    if (c == '>')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.Text;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    // whitespace or stray chars between '=' and the quote
                    i++;
                    continue;

                case Mode.AttrVal:
                    if (c == quote)
                    {
                        Flush(i);                         // flush the value
                        Emit(i, 1, XmlColorClass.Punct);  // closing quote
                        mode = Mode.AttrName;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Attr;
                        continue;
                    }
                    runColor = XmlColorClass.Val;
                    i++;
                    continue;

                case Mode.CloseTag:
                    if (c == '>')
                    {
                        Flush(i);
                        Emit(i, 1, XmlColorClass.Punct);
                        mode = Mode.Text;
                        i++;
                        runStart = i;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    runColor = XmlColorClass.Tag;
                    i++;
                    continue;

                case Mode.Comment:
                    if (c == '-' && i + 2 < to && s[i + 1] == '-' && s[i + 2] == '>')
                    {
                        i += 3;
                        Flush(i); // include the "-->"
                        mode = Mode.Text;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    runColor = XmlColorClass.Com;
                    i++;
                    continue;

                case Mode.PI:
                    if (c == '?' && i + 1 < to && s[i + 1] == '>')
                    {
                        i += 2;
                        Flush(i); // include the "?>"
                        mode = Mode.Text;
                        runColor = XmlColorClass.Text;
                        continue;
                    }
                    runColor = XmlColorClass.Com;
                    i++;
                    continue;
            }
        }

        Flush(to);
    }
}
