using System;
using System.Collections.Generic;
using System.Text;

namespace XMLMacker.Core;

/// <summary>
/// A hand-written, single-pass, character-level well-formedness scanner, a 1:1 port of the Swift
/// <c>XMLFragmentLinter</c>. This is the engine behind live scoped validation ("edit something wrong → immediately
/// see the error(s) with a one-click fix"). It deliberately is NOT the streaming parser, because:
/// <list type="number">
/// <item>a real parser aborts at the first error; this reports EVERY structural error in the window;</item>
/// <item>the validator over-extracts (hands a window that extends PAST the scope element); this STOPS once the
/// scope's root element closes, so the trailing text is free;</item>
/// <item>a truncated window makes a real parser emit bogus "premature end of data"; this suppresses "never closed"
/// errors when the window was cut (<paramref name="reachedDocEnd"/> == <c>false</c>).</item>
/// </list>
///
/// <b>UTF-16 semantics:</b> the raw .NET <see cref="string"/> is indexed by <see cref="char"/> (UTF-16 code unit).
/// Any char <c>&gt; 0x7F</c> is treated as a name character (non-ASCII element names pass). Never convert to runes.
/// </summary>
public static class XmlFragmentLinter
{
    private enum QuotedRunKind
    {
        Closed,
        MissingQuoteBeforeTagEnd,
        RawLessThan,
        EndOfInput,
        ErrorLimit
    }

    private readonly record struct QuotedRunResult(QuotedRunKind Kind, int Offset = -1);

    /// <summary>Hard cap on reported errors per lint. Once reached, scanning stops.</summary>
    public const int MaxErrors = 50;

    /// <summary>
    /// Scans <paramref name="text"/> for well-formedness errors, producing multi-errors with one-click fix-its whose
    /// ranges are in document coordinates.
    /// </summary>
    /// <param name="text">The window to lint.</param>
    /// <param name="baseLine">1-based absolute line in the source editor where the window starts. All reported lines are shifted by this.</param>
    /// <param name="reachedDocEnd">
    /// True iff the window extends to the real end of the document (was NOT cut at a cap). Gates all
    /// "never closed / unterminated / stray '&lt;' at end" errors: when the window was cut early, missing closers may
    /// simply lie past the cut, so those errors are suppressed.
    /// </param>
    /// <param name="baseOffset">Absolute char offset (document coordinates) where the window starts; added to every fix-it range. Default 0.</param>
    /// <returns>Errors with attached fix-its; line numbers already absolute.</returns>
    public static List<ParseError> Lint(string text, int baseLine, bool reachedDocEnd, int baseOffset = 0)
    {
        string ns = text;                       // index by char (UTF-16 code unit)
        int len = ns.Length;
        if (!reachedDocEnd)
        {
            int lastLt = ns.LastIndexOf('<');
            int lastGt = ns.LastIndexOf('>');
            if (lastLt >= 0 && lastGt < lastLt) len = lastLt;
        }
        var errors = new List<ParseError>();
        var stack = new List<(string Name, int Line, int NameStart, HashSet<string> Completed)>();
        Dictionary<string, int>? openTagCounts = null;   // built on first mismatch: how often each name opens an element
        bool rootWasOpened = false;             // set once any element opens; detects "scope root closed"
        bool suppressEofStackFixes = false;
        int i = 0;                              // current UTF-16 index
        int line = Math.Max(1, baseLine);       // current absolute line
        int lastLineStart = 0;                  // offset where the current line began (for column math)

        int Col(int offset) => offset - lastLineStart + 1;   // 1-based column

        FixIt MakeFixIt(int localLoc, int localLen, string replacement, string title)
        {
            string original = localLen > 0 ? ns.Substring(localLoc, localLen) : "";
            return new FixIt((localLoc + baseOffset, localLen), original, replacement, title);
        }

        // Returns false once the cap is reached (callers break the scan loop on false).
        bool AddError(int offset, int lineAt, string msg, FixIt? fix = null)
        {
            if (errors.Count >= MaxErrors) return false;
            errors.Add(new ParseError(lineAt, Math.Max(1, Col(offset)), msg, fix));
            return errors.Count < MaxErrors;
        }

        void Advance()
        {
            if (i < len && ns[i] == '\n') { line++; lastLineStart = i + 1; }   // count lines ONLY on \n (CRLF counts once)
            i++;
        }

        // Search for needle from i to end; advance past the match (maintaining line count) → true; else fast-forward to end → false.
        bool SkipPast(string needle)
        {
            int idx = ns.IndexOf(needle, i, len - i, StringComparison.Ordinal);
            if (idx < 0)
            {
                while (i < len) Advance();
                return false;
            }
            int target = idx + needle.Length;
            while (i < target) Advance();
            return true;
        }

        // A declaration can contain quoted identifiers and an internal subset.
        // Neither a quoted '>' nor one inside the subset ends the declaration.
        bool SkipMarkupDeclaration()
        {
            char? quote = null;
            int subsetDepth = 0;
            while (i < len)
            {
                char current = ns[i];
                Advance();
                if (quote is { } activeQuote)
                {
                    if (current == activeQuote) quote = null;
                }
                else if (current is '"' or '\'')
                {
                    quote = current;
                }
                else if (current == '[')
                {
                    subsetDepth++;
                }
                else if (current == ']' && subsetDepth > 0)
                {
                    subsetDepth--;
                }
                else if (current == '>' && subsetDepth == 0)
                {
                    return true;
                }
            }
            return false;
        }

        static bool IsNameStart(char c) =>
            (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == ':' || c > 0x7F;

        static bool IsNameChar(char c) =>
            IsNameStart(c) || (c >= '0' && c <= '9') || c == '-' || c == '.';

        static bool IsXmlWhitespace(char c) => c is ' ' or '\t' or '\n' or '\r';

        static bool IsValidXmlScalar(uint value) =>
            value is 0x09 or 0x0A or 0x0D ||
            value is >= 0x20 and <= 0xD7FF ||
            value is >= 0xE000 and <= 0xFFFD ||
            value is >= 0x10000 and <= 0x10FFFF;

        static bool IsValidEntityBody(string body)
        {
            if (body.StartsWith("#x", StringComparison.OrdinalIgnoreCase))
            {
                ReadOnlySpan<char> digits = body.AsSpan(2);
                if (digits.Length == 0) return false;
                foreach (char digit in digits)
                    if (!Uri.IsHexDigit(digit)) return false;
                return uint.TryParse(digits, System.Globalization.NumberStyles.HexNumber, null,
                    out uint hex) && IsValidXmlScalar(hex);
            }
            if (body.StartsWith('#'))
            {
                ReadOnlySpan<char> digits = body.AsSpan(1);
                if (digits.Length == 0) return false;
                foreach (char digit in digits)
                    if (digit is < '0' or > '9') return false;
                return uint.TryParse(digits, out uint dec) && IsValidXmlScalar(dec);
            }
            if (body.Length == 0 || !IsNameStart(body[0])) return false;
            for (int n = 1; n < body.Length; n++) if (!IsNameChar(body[n])) return false;
            return true;
        }

        static bool IsSafeMissingSemicolonCandidate(string body) =>
            body is "amp" or "lt" or "gt" or "quot" or "apos" ||
            body.StartsWith('#') && IsValidEntityBody(body);

        string ReadName()
        {
            int startN = i;
            while (i < len && IsNameChar(ns[i])) i++;   // name chars are never '\n', so no line bookkeeping needed
            return ns.Substring(startN, i - startN);
        }

        (bool Valid, bool CanContinue) ConsumeEntityReference(char? terminatingQuote = null,
            string? context = null)
        {
            int entStart = i;
            int entLine = line;
            Advance();
            var body = new StringBuilder();
            bool closed = false;
            int steps = 0;
            while (i < len && steps < 128)
            {
                char current = ns[i];
                if (current == ';')
                {
                    closed = true;
                    Advance();
                    break;
                }
                if (current is '<' or '>' or '/' or '&' || IsXmlWhitespace(current) ||
                    terminatingQuote is { } quote && current == quote)
                {
                    break;
                }
                // Swift builds the body from individual UTF-16 units and
                // substitutes a space when one unit is not a Unicode scalar.
                body.Append(char.IsSurrogate(current) ? ' ' : current);
                Advance();
                steps++;
            }

            string entityBody = body.ToString();
            if (closed && IsValidEntityBody(entityBody)) return (true, true);

            string suffix = context is null ? string.Empty : $" in {context}";
            FixIt fix;
            string message;
            if (!closed && IsSafeMissingSemicolonCandidate(entityBody))
            {
                fix = MakeFixIt(i, 0, ";", $"Insert ';' after &{entityBody}");
                message = $"Entity &{entityBody}{suffix} is missing its closing ';'";
            }
            else
            {
                fix = MakeFixIt(entStart, 1, "&amp;", "Change '&' to '&amp;'");
                message = $"Unescaped or invalid '&'{suffix}, write a literal ampersand as &amp;";
            }
            return (false, AddError(entStart, entLine, message, fix));
        }

        QuotedRunResult SkipQuoted(char quote, string? entityContext = null)
        {
            Advance();
            int possibleTagEnd = -1;
            while (i < len)
            {
                char current = ns[i];
                if (current == quote)
                {
                    Advance();
                    return new QuotedRunResult(QuotedRunKind.Closed);
                }
                if (current == '&')
                {
                    var entity = ConsumeEntityReference(quote, entityContext);
                    if (!entity.CanContinue) return new QuotedRunResult(QuotedRunKind.ErrorLimit);
                    continue;
                }
                if (current == '<')
                {
                    return possibleTagEnd >= 0
                        ? new QuotedRunResult(QuotedRunKind.MissingQuoteBeforeTagEnd, possibleTagEnd)
                        : new QuotedRunResult(QuotedRunKind.RawLessThan, i);
                }
                if (current == '>')
                {
                    possibleTagEnd = i;
                }
                else if (possibleTagEnd >= 0 && i > possibleTagEnd && !IsXmlWhitespace(current))
                {
                    possibleTagEnd = -1;
                }
                Advance();
            }
            return new QuotedRunResult(QuotedRunKind.EndOfInput);
        }

        // ---- Main scan loop ------------------------------------------------------------------------------------
        while (i < len)
        {
            char c = ns[i];

            // A) Not '<', text content.
            if (c != '<')
            {
                if (c == '&')
                {
                    if (!ConsumeEntityReference().CanContinue) goto DoneScan;
                    continue;
                }

                Advance();
                continue;
            }

            // B) '<', markup. Record the tag start.
            int tagStart = i, tagLine = line;

            // 1. Comment <!--
            if (i + 3 < len && ns[i + 1] == '!' && ns[i + 2] == '-' && ns[i + 3] == '-')
            {
                i += 4;
                if (!SkipPast("-->"))
                {
                    suppressEofStackFixes = true;
                    if (reachedDocEnd) AddError(tagStart, tagLine, "Comment is never closed (missing -->)",
                        MakeFixIt(len, 0, "-->", "Append '-->'"));
                    goto DoneScan;
                }
                continue;
            }

            // 2. CDATA <![CDATA[
            if (i + 8 < len && string.CompareOrdinal(ns, i, "<![CDATA[", 0, 9) == 0)
            {
                i += 9;
                if (!SkipPast("]]>"))
                {
                    suppressEofStackFixes = true;
                    if (reachedDocEnd) AddError(tagStart, tagLine, "CDATA section is never closed (missing ]]>)",
                        MakeFixIt(len, 0, "]]>", "Append ']]>'"));
                    goto DoneScan;
                }
                continue;
            }

            // 3. DOCTYPE / other markup declaration
            if (i + 1 < len && ns[i + 1] == '!')
            {
                i += 2;
                if (!SkipMarkupDeclaration())
                {
                    suppressEofStackFixes = true;
                    if (reachedDocEnd)
                        AddError(tagStart, tagLine, "Markup declaration is never closed");
                    goto DoneScan;
                }
                continue;
            }

            // 4. PI <?
            if (i + 1 < len && ns[i + 1] == '?')
            {
                i += 2;
                if (!SkipPast("?>"))
                {
                    suppressEofStackFixes = true;
                    if (reachedDocEnd) AddError(tagStart, tagLine, "Processing instruction is never closed (missing ?>)",
                        MakeFixIt(len, 0, "?>", "Append '?>'"));
                    goto DoneScan;
                }
                continue;
            }

            // 5. Closing tag </name>
            if (i + 1 < len && ns[i + 1] == '/')
            {
                Advance();
                Advance();
                int closeNameStart = i;
                string name = ReadName();
                while (i < len && (ns[i] == ' ' || ns[i] == '\t' || ns[i] == '\n' || ns[i] == '\r')) Advance();

                if (name.Length == 0)
                {
                    if (!AddError(tagStart, tagLine,
                        "Malformed closing tag, '</' must be followed by the tag name")) goto DoneScan;
                    continue;
                }

                bool stopAfterClosingTag = false;
                if (i < len && ns[i] == '>')
                {
                    Advance();
                }
                else if (i >= len)
                {
                    suppressEofStackFixes = true;
                    if (reachedDocEnd) AddError(tagStart, tagLine,
                        $"Unterminated closing tag </{name} (missing '>')",
                        MakeFixIt(len, 0, ">", $"Append '>' to </{name}>"));
                    stopAfterClosingTag = true;
                }
                else if (ns[i] == '<')
                {
                    if (!AddError(tagStart, tagLine,
                        $"Unterminated closing tag </{name} (missing '>' before the next tag)",
                        MakeFixIt(i, 0, ">", "Insert '>' before the next '<'"))) goto DoneScan;
                }
                else
                {
                    int junkStart = i;
                    while (i < len && ns[i] != '>' && ns[i] != '<') Advance();
                    if (!AddError(junkStart, tagLine,
                        $"Unexpected text in closing tag </{name}>, only whitespace is allowed before '>'"))
                        goto DoneScan;
                    if (i < len && ns[i] == '>')
                    {
                        Advance();
                    }
                    else if (i >= len)
                    {
                        suppressEofStackFixes = true;
                        stopAfterClosingTag = true;
                    }
                }

                if (stack.Count > 0)
                {
                    var top = stack[^1];
                    if (top.Name == name)
                    {
                        var completed = top;
                        stack.RemoveAt(stack.Count - 1);
                        if (stack.Count > 0) stack[^1].Completed.Add(completed.Name);
                        if (stack.Count == 0 && rootWasOpened) goto DoneScan;
                    }
                    else if (FindStackName(name) is int depth)
                    {
                        for (int s = stack.Count - 1; s > depth; s--)
                        {
                            var unclosed = stack[s];
                            if (!AddError(tagStart, tagLine,
                                $"Element <{unclosed.Name}> is never closed (opened on line {unclosed.Line})",
                                MakeFixIt(tagStart, 0, $"</{unclosed.Name}>",
                                    $"Insert </{unclosed.Name}> before </{name}>"))) goto DoneScan;
                        }
                        stack.RemoveRange(depth, stack.Count - depth);
                        if (stack.Count == 0 && rootWasOpened) goto DoneScan;
                    }
                    else if (FindTypoDepth(name) is int typoDepth)
                    {
                        var intended = stack[typoDepth];
                        bool established = typoDepth > 0 &&
                            stack[typoDepth - 1].Completed.Contains(intended.Name) &&
                            !stack[typoDepth - 1].Completed.Contains(name);

                        if (typoDepth < stack.Count - 1)
                        {
                            for (int s = stack.Count - 1; s > typoDepth; s--)
                            {
                                var unclosed = stack[s];
                                FixIt? innerFix = established
                                    ? MakeFixIt(tagStart, 0, $"</{unclosed.Name}>",
                                        $"Insert </{unclosed.Name}> before </{name}>")
                                    : null;
                                if (!AddError(tagStart, tagLine,
                                    $"Element <{unclosed.Name}> is never closed (opened on line {unclosed.Line})",
                                    innerFix)) goto DoneScan;
                            }
                        }

                        bool innermost = typoDepth == stack.Count - 1;
                        bool offerRename = established || innermost;
                        string ambiguity = offerRename
                            ? string.Empty
                            : ", no automatic rename because either tag name may be the typo";

                        // WHICH tag is the typo? Ask the neighbours. If the opening tag's name opens no other
                        // element in this text while the closing tag's name opens several, the OPENING tag is
                        // the typo (a slip typed into <AgSupplydySector> among twenty <AgSupplySector>s).
                        // Renaming the closing tag in that case would "repair" the file into a brand-new,
                        // unintended element name. Otherwise the closing tag is renamed, as before.
                        openTagCounts ??= CountOpenTags(ns, len);
                        int openOthers = (openTagCounts.TryGetValue(intended.Name, out int oc) ? oc : 0) - 1;
                        int closeKnown = openTagCounts.TryGetValue(name, out int cc) ? cc : 0;
                        bool openingIsTypo = offerRename && openOthers <= 0 && closeKnown >= 1;

                        FixIt? renameFix = null;
                        string message;
                        if (openingIsTypo)
                        {
                            string plural = closeKnown == 1 ? "" : "s";
                            renameFix = MakeFixIt(intended.NameStart, intended.Name.Length, name,
                                $"Change opening tag to <{name}> ({closeKnown} other element{plural} here are named {name})");
                            message = $"Opening tag <{intended.Name}> on line {intended.Line} looks like a typo of <{name}> "
                                    + $",  {closeKnown} other element{plural} here are named {name}, none {intended.Name}";
                        }
                        else
                        {
                            if (offerRename)
                                renameFix = MakeFixIt(closeNameStart, name.Length, intended.Name,
                                    $"Change closing tag to </{intended.Name}>");
                            message = $"Mismatched closing tag </{name}>, expected </{intended.Name}> (opened on line {intended.Line}){ambiguity}";
                        }
                        if (!AddError(tagStart, tagLine, message, renameFix)) goto DoneScan;
                        stack.RemoveRange(typoDepth, stack.Count - typoDepth);
                        if (stack.Count == 0 && rootWasOpened) goto DoneScan;
                    }
                    else
                    {
                        if (!AddError(tagStart, tagLine,
                            $"Stray closing tag </{name}>, no opening tag matches (currently inside <{top.Name}>, line {top.Line})"))
                            goto DoneScan;
                    }
                }
                else
                {
                    if (!AddError(tagStart, tagLine, $"Closing tag </{name}> has no matching opening tag"))
                        goto DoneScan;
                }
                if (stopAfterClosingTag) goto DoneScan;
                continue;

                int? FindStackName(string sought)
                {
                    for (int s = stack.Count - 1; s >= 0; s--)
                        if (stack[s].Name == sought) return s;
                    return null;
                }

                int? FindTypoDepth(string closeName)
                {
                    for (int s = stack.Count - 1; s >= 0; s--)
                        if (LooksLikeTypo(closeName, stack[s].Name)) return s;
                    return null;
                }
            }

            // 6. Opening tag <name …>
            Advance();   // consume '<'
            if (i >= len)
            {
                suppressEofStackFixes = true;
                if (reachedDocEnd) AddError(tagStart, tagLine, "Stray '<' at end of text");
                goto DoneScan;
            }
            if (!IsNameStart(ns[i]))
            {
                if (!AddError(tagStart, tagLine,
                    "Malformed tag, '<' must be immediately followed by a tag name (write &lt; for a literal '<')"))
                    goto DoneScan;
                continue;
            }

            {
                string name = ReadName();
                bool selfClosing = false, terminated = false;
                var seenAttributes = new Dictionary<string, (string Text, bool Complete)>(StringComparer.Ordinal);

                // attrLoop
                while (i < len)
                {
                    char a = ns[i];

                    if (a == ' ' || a == '\t' || a == '\n' || a == '\r')
                    {
                        Advance();
                        continue;
                    }
                    if (a == '>')
                    {
                        Advance();
                        terminated = true;
                        break;
                    }
                    if (a == '/')
                    {
                        if (i + 1 < len && ns[i + 1] == '>')
                        {
                            Advance(); Advance();
                            selfClosing = true;
                            terminated = true;
                            break;
                        }
                        int slashOffset = i;
                        int slashLine = line;
                        Advance();
                        int whitespaceStart = i;
                        while (i < len && IsXmlWhitespace(ns[i])) Advance();
                        if (i < len && ns[i] == '>')
                        {
                            if (!AddError(slashOffset, slashLine,
                                "Whitespace is not allowed between '/' and '>' in a self-closing tag",
                                MakeFixIt(whitespaceStart, i - whitespaceStart, "",
                                    "Remove whitespace between '/' and '>'"))) goto DoneScan;
                            Advance();
                            selfClosing = true;
                            terminated = true;
                            break;
                        }
                        if (i >= len)
                        {
                            suppressEofStackFixes = true;
                            if (reachedDocEnd) AddError(slashOffset, slashLine,
                                $"Self-closing tag <{name} is missing its final '>'",
                                MakeFixIt(whitespaceStart, len - whitespaceStart, ">",
                                    "Finish the tag with '/>'"));
                            selfClosing = true;
                            terminated = true;
                            break;
                        }
                        if (!AddError(slashOffset, slashLine,
                            $"Unexpected '/' in <{name}>, '/' is only valid as part of '/>'")) goto DoneScan;
                        continue;
                    }
                    if (a == '<')
                    {
                        var fix = MakeFixIt(i, 0, ">", "Insert '>' before the next '<'");
                        if (!AddError(tagStart, tagLine,
                            $"Unterminated tag <{name} (missing '>'), opened on line {tagLine}", fix))
                            goto DoneScan;
                        terminated = true;   // resync: treat this '<' as a fresh start
                        break;
                    }
                    if (a == '"' || a == '\'')
                    {
                        if (!AddError(i, line,
                            $"Unexpected quote in <{name}>, attributes must be written name=\"value\""))
                            goto DoneScan;
                        QuotedRunResult unexpectedQuote = SkipQuoted(a);
                        if (unexpectedQuote.Kind == QuotedRunKind.Closed)
                        {
                            continue;
                        }
                        suppressEofStackFixes = true;
                        goto DoneScan;
                    }
                    if (IsNameStart(a))
                    {
                        int attrStart = i;
                        string attrName = ReadName();
                        bool attributeComplete = false;
                        while (i < len && IsXmlWhitespace(ns[i])) Advance();

                        if (i < len && ns[i] == '=')
                        {
                            Advance();
                            while (i < len && IsXmlWhitespace(ns[i])) Advance();
                            if (i < len)
                            {
                                char v = ns[i];
                                if (v == '"' || v == '\'')
                                {
                                    int qStart = i, qLine = line;
                                    int errorsBeforeValue = errors.Count;
                                    QuotedRunResult quoted = SkipQuoted(v,
                                        $"attribute '{attrName}' in <{name}>");
                                    switch (quoted.Kind)
                                    {
                                        case QuotedRunKind.Closed:
                                            attributeComplete = errors.Count == errorsBeforeValue;
                                            if (i < len && IsNameStart(ns[i]) &&
                                                !AddError(i, line,
                                                    $"Attributes in <{name}> must be separated by whitespace",
                                                    MakeFixIt(i, 0, " ",
                                                        "Insert space before the next attribute")))
                                                goto DoneScan;
                                            break;

                                        case QuotedRunKind.MissingQuoteBeforeTagEnd:
                                            if (!AddError(qStart, qLine,
                                                $"Attribute value quote is never closed in <{name}> before its '>'",
                                                MakeFixIt(quoted.Offset, 0, v.ToString(),
                                                    $"Insert the missing {v} before '>'")))
                                                goto DoneScan;
                                            terminated = true;
                                            break;

                                        case QuotedRunKind.RawLessThan:
                                            suppressEofStackFixes = true;
                                            if (!AddError(quoted.Offset, line,
                                                $"Raw '<' is not allowed inside attribute '{attrName}' in <{name}>; either close the quote before it or write &lt;"))
                                                goto DoneScan;
                                            goto DoneScan;

                                        case QuotedRunKind.EndOfInput:
                                            suppressEofStackFixes = true;
                                            if (reachedDocEnd)
                                            {
                                                AddError(qStart, qLine,
                                                    $"Attribute value quote and tag are never closed in <{name}>",
                                                    MakeFixIt(len, 0, $"{v}>",
                                                        $"Append the missing {v} and '>'"));
                                                terminated = true;
                                            }
                                            break;

                                        case QuotedRunKind.ErrorLimit:
                                            goto DoneScan;
                                    }
                                    if (quoted.Kind is QuotedRunKind.MissingQuoteBeforeTagEnd or
                                        QuotedRunKind.EndOfInput)
                                        break;
                                }
                                else if (v == '>' || v == '/')
                                {
                                    var fix = MakeFixIt(i, 0, "\"\"", $"Insert \"\" after {attrName}=");
                                    if (!AddError(i, line, $"Attribute '{attrName}' in <{name}> has no value after '='", fix))
                                        goto DoneScan;
                                }
                                else
                                {
                                    int tokStart = i, tokLine = line;
                                    bool tokenEntitiesAreValid = true;
                                    while (i < len)
                                    {
                                        char current = ns[i];
                                        if (IsXmlWhitespace(current) || current == '>' || current == '/' ||
                                            current == '"' || current == '\'') break;
                                        if (current == '&')
                                        {
                                            var entity = ConsumeEntityReference(context:
                                                $"attribute '{attrName}' in <{name}>");
                                            tokenEntitiesAreValid &= entity.Valid;
                                            if (!entity.CanContinue) goto DoneScan;
                                            continue;
                                        }
                                        Advance();
                                    }
                                    int tokLen = i - tokStart;
                                    string token = ns.Substring(tokStart, tokLen);
                                    bool hasClosingQuote = i < len && (ns[i] == '"' || ns[i] == '\'') &&
                                        (i + 1 >= len || IsXmlWhitespace(ns[i + 1]) || ns[i + 1] == '>' || ns[i + 1] == '/');
                                    FixIt? fix = hasClosingQuote && tokenEntitiesAreValid
                                        ? MakeFixIt(tokStart, 0, ns[i].ToString(), $"Insert opening {ns[i]} before {token}")
                                        : tokenEntitiesAreValid
                                            ? MakeFixIt(tokStart, tokLen, $"\"{token}\"", $"Wrap in quotes: {attrName}=\"{token}\"")
                                            : null;
                                    if (!AddError(tokStart, tokLine, hasClosingQuote
                                        ? $"Attribute '{attrName}' in <{name}> is missing its opening quote"
                                        : $"Attribute value of '{attrName}' in <{name}> must be quoted (use {attrName}=\"…\")", fix))
                                        goto DoneScan;
                                    if (hasClosingQuote) Advance();
                                }
                            }
                        }
                        else if (i < len && (ns[i] == '"' || ns[i] == '\''))
                        {
                            int quoteOffset = i;
                            if (!AddError(i, line,
                                $"Attribute '{attrName}' in <{name}> is missing '=' before its quoted value",
                                MakeFixIt(i, 0, "=", "Insert '=' before the quoted value")))
                                goto DoneScan;
                            QuotedRunResult quoted = SkipQuoted(ns[quoteOffset],
                                $"attribute '{attrName}' in <{name}>");
                            if (quoted.Kind == QuotedRunKind.Closed)
                            {
                                if (i < len && IsNameStart(ns[i]) &&
                                    !AddError(i, line,
                                        $"Attributes in <{name}> must be separated by whitespace",
                                        MakeFixIt(i, 0, " ", "Insert space before the next attribute")))
                                    goto DoneScan;
                            }
                            else
                            {
                                suppressEofStackFixes = true;
                                goto DoneScan;
                            }
                        }
                        else
                        {
                            int look = i;
                            while (look < len && IsXmlWhitespace(ns[look])) look++;
                            FixIt? valueFix = null;
                            if (look < len)
                            {
                                char lookChar = ns[look];
                                if (lookChar == '>' || lookChar == '/')
                                {
                                    valueFix = MakeFixIt(i, 0, "=\"\"",
                                        $"Change to {attrName}=\"\"");
                                }
                                else if (IsNameStart(lookChar))
                                {
                                    int tokenEnd = look;
                                    while (tokenEnd < len && IsNameChar(ns[tokenEnd])) tokenEnd++;
                                    int after = tokenEnd;
                                    while (after < len && IsXmlWhitespace(ns[after])) after++;
                                    char afterChar = after < len ? ns[after] : '>';
                                    if (afterChar == '=')
                                    {
                                        valueFix = MakeFixIt(i, 0, "=\"\"",
                                            $"Change to {attrName}=\"\"");
                                    }
                                    else if (afterChar == '>' || afterChar == '/' ||
                                             IsNameStart(afterChar))
                                    {
                                        string token = ns.Substring(look, tokenEnd - look);
                                        valueFix = MakeFixIt(i, tokenEnd - i, $"=\"{token}\"",
                                            $"Change to {attrName}=\"{token}\"");
                                    }
                                }
                            }
                            if (!AddError(i, line,
                                $"Attribute '{attrName}' in <{name}> has no value (XML requires {attrName}=\"value\")",
                                valueFix))
                                goto DoneScan;
                        }

                        // duplicate check regardless of how the value parsed
                        int attributeLength = i - attrStart;
                        string attributeText = ns.Substring(attrStart, attributeLength);
                        if (seenAttributes.TryGetValue(attrName, out var firstAttribute))
                        {
                            bool redundant = attributeComplete && firstAttribute.Complete &&
                                firstAttribute.Text == attributeText;
                            FixIt? fix = redundant
                                ? MakeFixIt(attrStart, attributeLength, "", $"Delete exactly redundant {attrName}")
                                : null;
                            if (!AddError(i, line, $"Duplicate attribute '{attrName}' in <{name}>", fix))
                                goto DoneScan;
                        }
                        else
                        {
                            seenAttributes[attrName] = (attributeText, attributeComplete);
                        }
                        continue;
                    }

                    int junkStart = i, junkLine = line;
                    Advance();
                    while (i < len && !IsXmlWhitespace(ns[i]) && ns[i] != '>' && ns[i] != '/' &&
                           ns[i] != '<' && !IsNameStart(ns[i])) Advance();
                    string junk = ns.Substring(junkStart, i - junkStart);
                    if (!AddError(junkStart, junkLine,
                        $"Unexpected token '{junk}' in <{name}>, attributes must be written name=\"value\""))
                        goto DoneScan;
                }

                // after attrLoop
                if (!terminated)   // window ended inside the tag
                {
                    if (reachedDocEnd)
                    {
                        suppressEofStackFixes = true;
                        AddError(tagStart, tagLine,
                            $"Unterminated tag <{name} (missing '>'), opened on line {tagLine}",
                            MakeFixIt(len, 0, ">", $"Append '>' to <{name}"));
                        terminated = true;
                    }
                }
                if (!selfClosing && terminated)
                {
                    stack.Add((name, tagLine, tagStart + 1, new HashSet<string>(StringComparer.Ordinal)));
                    rootWasOpened = true;
                }
                else if (selfClosing)
                {
                    if (stack.Count > 0) stack[^1].Completed.Add(name);
                    else if (!rootWasOpened)
                    {
                        rootWasOpened = true;
                        goto DoneScan;
                    }
                }
                if (i >= len) goto DoneScan;
            }
            // fall through → next scanLoop iteration
        }

    DoneScan:
        // After the scan loop ends (window exhausted): report still-open elements only if the window reached doc end.
        if (reachedDocEnd && !suppressEofStackFixes)
        {
            for (int s = stack.Count - 1; s >= 0; s--)
            {
                if (errors.Count >= MaxErrors) break;
                var unclosed = stack[s];
                var suffix = new StringBuilder();
                for (int d = stack.Count - 1; d >= s; d--) suffix.Append($"</{stack[d].Name}>");
                string closingSuffix = suffix.ToString();
                errors.Add(new ParseError(unclosed.Line, 1,
                    $"Element <{unclosed.Name}> is never closed (opened on line {unclosed.Line})",
                    MakeFixIt(len, 0, closingSuffix,
                        closingSuffix == $"</{unclosed.Name}>"
                            ? $"Append </{unclosed.Name}>"
                            : $"Append missing closing tags through </{unclosed.Name}>")));
            }
        }

        return errors;
    }

    /// <summary>
    /// How many elements in <paramref name="text"/> (first <paramref name="len"/> chars) OPEN with each name:
    /// every '&lt;' followed by a name character starts an opening tag (closing tags start with "&lt;/",
    /// comments and instructions with "&lt;!" / "&lt;?", so they are skipped).
    /// </summary>
    private static Dictionary<string, int> CountOpenTags(string text, int len)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        int n = Math.Min(len, text.Length);
        for (int k = 0; k < n - 1; k++)
        {
            if (text[k] != '<') continue;
            char c = text[k + 1];
            if (!(char.IsLetter(c) || c == '_' || c == ':')) continue;
            int e = k + 1;
            while (e < n && (char.IsLetterOrDigit(text[e]) || text[e] == '_' || text[e] == '-' || text[e] == '.' || text[e] == ':')) e++;
            string tag = text.Substring(k + 1, e - (k + 1));
            counts[tag] = counts.TryGetValue(tag, out int v) ? v + 1 : 1;
            k = e - 1;
        }
        return counts;
    }

    // ---- Typo detection --------------------------------------------------------------------------------------

    /// <summary>
    /// Decides recovery on a mismatched closing tag. A typo'd close still CLOSES its element (pop + one clean error); an
    /// unrelated name is treated as a stray close (don't pop, so the real close can still match). Both names lowercased.
    /// </summary>
    /// <summary>Longest tag name still worth comparing for a "did you mean" suggestion.</summary>
    private const int MaxTypoNameLength = 64;

    private static bool LooksLikeTypo(string close, string open)
    {
        string a = close.ToLowerInvariant();
        string b = open.ToLowerInvariant();
        if (a == b) return true;
        // The distance check below compares every character of one name against every character of the
        // other. A tag name is a word; a document can make one a million characters long, and then that
        // comparison runs for hours. A suggestion only means anything for short names anyway.
        if (a.Length > MaxTypoNameLength || b.Length > MaxTypoNameLength) return false;
        int aCharacters = System.Globalization.StringInfo.ParseCombiningCharacters(a).Length;
        int bCharacters = System.Globalization.StringInfo.ParseCombiningCharacters(b).Length;
        return Math.Min(aCharacters, bCharacters) >= 4 && EditDistanceAtMost2(a, b);
    }

    /// <summary>Bounded Levenshtein ≤ 2 over Unicode scalars (code points), with an early row-min exit.</summary>
    private static bool EditDistanceAtMost2(string a, string b)
    {
        int[] x = Scalars(a);
        int[] y = Scalars(b);
        if (Math.Abs(x.Length - y.Length) > 2) return false;
        if (x.Length == 0 || y.Length == 0) return Math.Max(x.Length, y.Length) <= 2;

        var prev = new int[y.Length + 1];
        for (int j = 0; j <= y.Length; j++) prev[j] = j;

        for (int ii = 1; ii <= x.Length; ii++)
        {
            var cur = new int[y.Length + 1];
            cur[0] = ii;
            int rowMin = ii;
            for (int j = 1; j <= y.Length; j++)
            {
                int cost = x[ii - 1] == y[j - 1] ? 0 : 1;
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
                if (cur[j] < rowMin) rowMin = cur[j];
            }
            if (rowMin > 2) return false;   // whole row already > 2
            prev = cur;
        }
        return prev[y.Length] <= 2;
    }

    /// <summary>Decomposes a string into Unicode scalar values (surrogate pairs collapse to one code point), mirroring Swift's <c>.unicodeScalars</c>.</summary>
    private static int[] Scalars(string s)
    {
        var list = new List<int>(s.Length);
        for (int k = 0; k < s.Length; k++)
        {
            char c = s[k];
            if (char.IsHighSurrogate(c) && k + 1 < s.Length && char.IsLowSurrogate(s[k + 1]))
            {
                list.Add(char.ConvertToUtf32(c, s[k + 1]));
                k++;
            }
            else
            {
                list.Add(c);
            }
        }
        return list.ToArray();
    }
}
