import Foundation

// Live well-formedness linter for the scoped validator, the piece
// that makes "edit something wrong → see the error" actually work.
//
// Why not Foundation's XMLParser for this job:
//   • XMLParser ABORTS at the first error, so the user only ever sees
//     one problem at a time, with libxml2's cryptic wording.
//   • It can't cope with our over-extraction strategy (we hand it a
//     window of text that intentionally extends PAST the scope
//     element, because the element's true end can't be trusted after
//     edits, the tree's endLine data is from load time). XMLParser
//     would report the trailing siblings as garbage.
//   • A truncated window (huge scope, cut at the cap) makes XMLParser
//     emit a bogus "premature end of data" error every time.
//
// This linter is a single-pass, quote-aware, comment/CDATA/PI-aware
// tag-stack scanner in the spirit of the classic Windows "XML Marker":
//   • reports EVERY structural error in the window, not just the first
//   • friendly messages ("Mismatched closing tag </regioddn>, expected
//     </region> (opened on line 812)")
//   • STOPS once the scope's root element closes, everything after is
//     outside the scope, so over-extraction costs nothing
//   • suppresses "never closed" errors when the window was cut at the
//     cap (we can't know, the closing tag may simply be past the cut)
//
// Line numbers are relative to the fragment, shifted by `baseLine` so
// they match the absolute position in the source editor.
enum XMLFragmentLinter {

    static let maxErrors = 50

    private enum QuotedRunResult {
        case closed
        // A `>` followed only by whitespace before the next `<` is a very
        // strong signal that the quote immediately before that `>` was lost.
        case missingQuoteBeforeTagEnd(Int)
        case rawLessThan(Int)
        case endOfInput
        case errorLimit
    }

    static func lint(_ text: String,
                     baseLine: Int,
                     reachedDocEnd: Bool,
                     baseOffset: Int = 0) -> [XMLStreamParser.ParseError] {
        let ns = text as NSString
        var len = ns.length
        // A bounded window can end in the middle of a tag; scanning that
        // fragment reported "stray closing tag </minicam-energy->" on a
        // clean 75 MB file. Ignore an unfinished trailing tag.
        if !reachedDocEnd {
            let lastLT = ns.range(of: "<", options: .backwards).location
            if lastLT != NSNotFound {
                let lastGT = ns.range(of: ">", options: .backwards).location
                if lastGT == NSNotFound || lastGT < lastLT { len = lastLT }
            }
        }
        var errors: [XMLStreamParser.ParseError] = []
        // Open-element stack. `completedChildNames` contains only children
        // that already closed with an exact matching name (or `/>`). This is
        // trustworthy local spelling evidence for conservative typo fixes.
        // nameRange is the opening tag's own name, so the neighbour rule
        // below can rewrite the OPENING tag when that is the typo.
        var stack: [(name: String, line: Int, nameRange: NSRange, completedChildNames: Set<String>)] = []
        var rootWasOpened = false
        // If scanning stops inside a comment, CDATA, PI, quote, or tag, an
        // element-close insertion at EOF would land *inside* that construct.
        // Keep only the primary local repair in that situation.
        var suppressEOFStackFixes = false

        var i = 0
        var line = max(1, baseLine)       // absolute line of position i
        var lastLineStart = 0             // offset where current line began

        func col(_ offset: Int) -> Int { offset - lastLineStart + 1 }

        // Build a FixIt whose range is shifted into DOCUMENT
        // coordinates (fragment offset + baseOffset) and carries the
        // exact current text so the applier can verify before editing.
        func fixIt(_ localRange: NSRange, _ replacement: String, _ title: String) -> XMLStreamParser.FixIt {
            XMLStreamParser.FixIt(
                range: NSRange(location: localRange.location + baseOffset,
                               length: localRange.length),
                original: localRange.length > 0 ? ns.substring(with: localRange) : "",
                replacement: replacement,
                title: title)
        }

        @discardableResult
        func addError(_ offset: Int, _ lineAt: Int, _ msg: String,
                      fix: XMLStreamParser.FixIt? = nil) -> Bool {
            guard errors.count < maxErrors else { return false }
            errors.append(XMLStreamParser.ParseError(
                line: lineAt, column: max(1, col(offset)), message: msg, fix: fix))
            return errors.count < maxErrors
        }

        // Advance i by one unit, maintaining line bookkeeping.
        @inline(__always)
        func advance() {
            if ns.character(at: i) == 0x0A { line += 1; lastLineStart = i + 1 }
            i += 1
        }

        // Skip forward until `needle` is found; returns false when the
        // window ends first. Used for comments / CDATA / PIs.
        func skipPast(_ needle: String) -> Bool {
            let r = ns.range(of: needle, options: [],
                             range: NSRange(location: i, length: len - i))
            guard r.location != NSNotFound else {
                // Fast-forward line counting to the end of the window.
                while i < len { advance() }
                return false
            }
            let stop = r.location + r.length
            while i < stop { advance() }
            return true
        }

        // Skip a declaration such as DOCTYPE without stopping at a `>` that
        // belongs to a quoted identifier or to its internal subset.
        func skipMarkupDeclaration() -> Bool {
            var quote: unichar?
            var subsetDepth = 0
            while i < len {
                let c = ns.character(at: i)
                advance()
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == 0x22 || c == 0x27 {
                    quote = c
                } else if c == 0x5B { // '['
                    subsetDepth += 1
                } else if c == 0x5D, subsetDepth > 0 { // ']'
                    subsetDepth -= 1
                } else if c == 0x3E, subsetDepth == 0 { // '>'
                    return true
                }
            }
            return false
        }

        func isNameStart(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
            c == 0x5F /*_*/ || c == 0x3A /*:*/ || c > 0x7F
        }
        func isNameChar(_ c: unichar) -> Bool {
            isNameStart(c) || (c >= 0x30 && c <= 0x39) ||
            c == 0x2D /*-*/ || c == 0x2E /*.*/
        }

        func isXMLWhitespace(_ c: unichar) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }

        func readName() -> String {
            let start = i
            while i < len, isNameChar(ns.character(at: i)) { advance() }
            return ns.substring(with: NSRange(location: start, length: i - start))
        }

        // Is `close` plausibly a TYPO of `open`? (regioddn ↔ region,
        // tranSubsectorX ↔ tranSubsector). Decides the recovery
        // strategy on mismatch: a typo'd close still CLOSES its
        // element (pop → one clean error); an unrelated name is a
        // stray close (don't pop → the real close can still match).
        func looksLikeTypo(_ close: String, _ open: String) -> Bool {
            let a = close.lowercased(), b = open.lowercased()
            if a == b { return true }
            // Small edit distance catches dropped/swapped letters EARLY
            // in the name, </peiod> for <period>, where the common-
            // prefix rule fails (shared prefix is only "pe"). Keeping the
            // threshold at two is deliberate: a merely similar GCAM tag is
            // not enough evidence to offer a destructive rename.
            return min(a.count, b.count) >= 4 && editDistanceAtMost2(a, b)
        }

        // Bounded Levenshtein: true iff distance(a, b) ≤ 2. Row-min
        // early exit keeps it O(len) in practice for tag-sized strings.
        func editDistanceAtMost2(_ a: String, _ b: String) -> Bool {
            let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
            if abs(x.count - y.count) > 2 { return false }
            if x.isEmpty || y.isEmpty { return max(x.count, y.count) <= 2 }
            var prev = Array(0...y.count)
            for i in 1...x.count {
                var cur = Array(repeating: 0, count: y.count + 1)
                cur[0] = i
                var rowMin = i
                for j in 1...y.count {
                    let cost = x[i-1] == y[j-1] ? 0 : 1
                    cur[j] = Swift.min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
                    rowMin = Swift.min(rowMin, cur[j])
                }
                if rowMin > 2 { return false }
                prev = cur
            }
            return prev[y.count] <= 2
        }

        func isValidXMLScalar(_ value: UInt32) -> Bool {
            value == 0x09 || value == 0x0A || value == 0x0D ||
            (value >= 0x20 && value <= 0xD7FF) ||
            (value >= 0xE000 && value <= 0xFFFD) ||
            (value >= 0x10000 && value <= 0x10FFFF)
        }

        // A scoped fragment normally does not include the document's DTD, so
        // a syntactically valid named entity may be declared outside our
        // window. Accept it here rather than offering the harmful `&amp;foo;`
        // repair; explicit whole-document validation remains authoritative
        // for undeclared entities.
        func isValidEntityBody(_ body: String) -> Bool {
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                let digits = body.dropFirst(2)
                guard !digits.isEmpty,
                      digits.allSatisfy({ $0.isHexDigit }),
                      let value = UInt32(digits, radix: 16) else { return false }
                return isValidXMLScalar(value)
            }
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                guard !digits.isEmpty,
                      digits.allSatisfy({ $0.isNumber }),
                      let value = UInt32(digits, radix: 10) else { return false }
                return isValidXMLScalar(value)
            }
            let entity = body as NSString
            guard entity.length > 0, isNameStart(entity.character(at: 0)) else { return false }
            for index in 1..<entity.length where !isNameChar(entity.character(at: index)) {
                return false
            }
            return true
        }

        func isSafeMissingSemicolonCandidate(_ body: String) -> Bool {
            if ["amp", "lt", "gt", "quot", "apos"].contains(body) { return true }
            return body.hasPrefix("#") && isValidEntityBody(body)
        }

        // Consume the entity beginning at `i`. The optional quote prevents a
        // missing semicolon from swallowing the rest of an attribute value.
        // The caller receives validity separately from the max-error signal so
        // it can withhold a wrapping FixIt for an invalid unquoted value.
        func consumeEntityReference(terminatingQuote: unichar? = nil,
                                    context: String? = nil) -> (valid: Bool, canContinue: Bool) {
            let entStart = i, entLine = line
            advance() // '&'
            var body = ""
            var closed = false
            var steps = 0
            while i < len, steps < 128 {
                let e = ns.character(at: i)
                if e == 0x3B { closed = true; advance(); break } // ';'
                if e == 0x3C || e == 0x3E || e == 0x2F || e == 0x26 ||
                    isXMLWhitespace(e) || e == terminatingQuote {
                    break
                }
                body.append(Character(UnicodeScalar(e) ?? " "))
                advance(); steps += 1
            }
            guard closed && isValidEntityBody(body) else {
                let suffix = context.map { " in \($0)" } ?? ""
                let fix: XMLStreamParser.FixIt
                let message: String
                if !closed && isSafeMissingSemicolonCandidate(body) {
                    fix = fixIt(NSRange(location: i, length: 0), ";",
                                "Insert ';' after &\(body)")
                    message = "Entity &\(body)\(suffix) is missing its closing ';'"
                } else {
                    fix = fixIt(NSRange(location: entStart, length: 1), "&amp;",
                                "Change '&' to '&amp;'")
                    message = "Unescaped or invalid '&'\(suffix), write a literal ampersand as &amp;"
                }
                return (false, addError(entStart, entLine, message, fix: fix))
            }
            return (true, true)
        }

        // Consume an attribute value while looking for the common GCAM typo
        // `year="2020>` followed by a child tag. A raw '<' is never legal in
        // an XML attribute, but it may mean either a missing quote or a literal
        // that should be escaped. We offer a quote fix only for the strong
        // `> + whitespace + <` shape; otherwise the diagnostic has no fix.
        func skipQuoted(_ quote: unichar,
                        entityContext: String? = nil) -> QuotedRunResult {
            advance() // opening quote
            var possibleTagEnd: Int?
            while i < len {
                let c = ns.character(at: i)
                if c == quote {
                    advance()
                    return .closed
                }
                if c == 0x26 {
                    let result = consumeEntityReference(terminatingQuote: quote,
                                                        context: entityContext)
                    if !result.canContinue { return .errorLimit }
                    continue
                }
                if c == 0x3C { // '<'
                    if let tagEnd = possibleTagEnd {
                        return .missingQuoteBeforeTagEnd(tagEnd)
                    }
                    return .rawLessThan(i)
                }
                if c == 0x3E { // possible opening-tag terminator
                    possibleTagEnd = i
                } else if let tagEnd = possibleTagEnd,
                          i > tagEnd,
                          !isXMLWhitespace(c) {
                    possibleTagEnd = nil
                }
                advance()
            }
            return .endOfInput
        }

        scanLoop:
        while i < len {
            let c = ns.character(at: i)

            //, , Text content: check entities, look for '<', , 
            if c != 0x3C {
                if c == 0x26 { // '&', must be a valid entity reference
                    if !consumeEntityReference().canContinue { break scanLoop }
                    continue
                }
                advance()
                continue
            }

            //, , '<', figure out what kind of markup, , 
            let tagStart = i
            let tagLine = line

            // Comment / CDATA / DOCTYPE / PI
            if i + 3 < len,
               ns.character(at: i+1) == 0x21, ns.character(at: i+2) == 0x2D,
               ns.character(at: i+3) == 0x2D {
                i += 4
                if !skipPast("-->") {
                    suppressEOFStackFixes = true
                    if reachedDocEnd {
                        _ = addError(tagStart, tagLine,
                            "Comment is never closed (missing -->)",
                            fix: fixIt(NSRange(location: len, length: 0), "-->",
                                       "Append '-->'"))
                    }
                    break scanLoop
                }
                continue
            }
            if i + 8 < len, ns.substring(with: NSRange(location: i, length: 9)) == "<![CDATA[" {
                i += 9
                if !skipPast("]]>") {
                    suppressEOFStackFixes = true
                    if reachedDocEnd {
                        _ = addError(tagStart, tagLine,
                            "CDATA section is never closed (missing ]]>)",
                            fix: fixIt(NSRange(location: len, length: 0), "]]>",
                                       "Append ']]>'"))
                    }
                    break scanLoop
                }
                continue
            }
            if i + 1 < len, ns.character(at: i+1) == 0x21 {   // <!DOCTYPE …>
                i += 2
                if !skipMarkupDeclaration() {
                    suppressEOFStackFixes = true
                    if reachedDocEnd {
                        _ = addError(tagStart, tagLine,
                                     "Markup declaration is never closed")
                    }
                    break scanLoop
                }
                continue
            }
            if i + 1 < len, ns.character(at: i+1) == 0x3F {   // <? … ?>
                i += 2
                if !skipPast("?>") {
                    suppressEOFStackFixes = true
                    if reachedDocEnd {
                        _ = addError(tagStart, tagLine,
                            "Processing instruction is never closed (missing ?>)",
                            fix: fixIt(NSRange(location: len, length: 0), "?>",
                                       "Append '?>'"))
                    }
                    break scanLoop
                }
                continue
            }

            // Closing tag </name>
            if i + 1 < len, ns.character(at: i+1) == 0x2F {
                advance(); advance()   // consume "</"
                let closeNameStart = i
                let name = readName()
                let closeNameRange = NSRange(location: closeNameStart,
                                             length: i - closeNameStart)
                // Skip whitespace, expect '>'
                while i < len, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09
                      || ns.character(at: i) == 0x0A || ns.character(at: i) == 0x0D { advance() }
                if name.isEmpty {
                    if !addError(tagStart, tagLine, "Malformed closing tag, '</' must be followed by the tag name") { break scanLoop }
                    continue
                }
                var stopAfterClosingTag = false
                if i < len, ns.character(at: i) == 0x3E {
                    advance()
                } else if i >= len {
                    suppressEOFStackFixes = true
                    if reachedDocEnd {
                        _ = addError(tagStart, tagLine,
                            "Unterminated closing tag </\(name) (missing '>')",
                            fix: fixIt(NSRange(location: len, length: 0), ">",
                                       "Append '>' to </\(name)>"))
                    }
                    // Recover as if the unambiguous final '>' were present so
                    // a matching close does not also generate a bogus
                    // "element never closed" cascade.
                    stopAfterClosingTag = true
                } else if ns.character(at: i) == 0x3C {
                    if !addError(tagStart, tagLine,
                        "Unterminated closing tag </\(name) (missing '>' before the next tag)",
                        fix: fixIt(NSRange(location: i, length: 0), ">",
                                   "Insert '>' before the next '<'")) {
                        break scanLoop
                    }
                    // Leave i on '<' so scanning resumes at the next tag.
                } else {
                    // `</name junk>` is malformed, but deleting the junk or
                    // the entire closing tag would be guesswork. Diagnose it,
                    // consume to a safe delimiter, and deliberately omit Fix.
                    let junkStart = i
                    while i < len,
                          ns.character(at: i) != 0x3E,
                          ns.character(at: i) != 0x3C { advance() }
                    if !addError(junkStart, tagLine,
                        "Unexpected text in closing tag </\(name)>, only whitespace is allowed before '>'") {
                        break scanLoop
                    }
                    if i < len, ns.character(at: i) == 0x3E {
                        advance()
                    } else if i >= len {
                        suppressEOFStackFixes = true
                        stopAfterClosingTag = true
                    }
                }

                // Match against the stack.
                if let top = stack.last {
                    if top.name == name {
                        let completed = stack.removeLast()
                        if !stack.isEmpty {
                            stack[stack.count - 1].completedChildNames.insert(completed.name)
                        }
                        if stack.isEmpty && rootWasOpened {
                            // Scope's root element closed, everything
                            // beyond is outside the scope. Done.
                            break scanLoop
                        }
                    } else if let depth = stack.lastIndex(where: { $0.name == name }) {
                        // The close matches an OUTER open, everything
                        // above it on the stack was never closed. The
                        // repair: insert the missing close(s) right
                        // before this tag, innermost first.
                        for unclosed in stack[(depth + 1)...].reversed() {
                            if !addError(tagStart, tagLine,
                                "Element <\(unclosed.name)> is never closed (opened on line \(unclosed.line))",
                                fix: fixIt(NSRange(location: tagStart, length: 0),
                                           "</\(unclosed.name)>",
                                           "Insert </\(unclosed.name)> before </\(name)>")) {
                                break scanLoop
                            }
                        }
                        stack.removeSubrange(depth...)
                        if stack.isEmpty && rootWasOpened { break scanLoop }
                    } else if let typoDepth = stack.indices.reversed().first(where: {
                        looksLikeTypo(name, stack[$0].name)
                    }) {
                        // A typo can target the current element OR an outer
                        // one, but syntax alone cannot tell whether the open
                        // or close is misspelled. Only offer repairs when an
                        // earlier, exactly matched sibling under this same
                        // parent confirms the opening spelling.
                        let intended = stack[typoDepth]
                        let siblingEvidence: Set<String> = typoDepth > 0
                            ? stack[typoDepth - 1].completedChildNames
                            : []
                        let openingNameIsEstablished =
                            siblingEvidence.contains(intended.name) &&
                            !siblingEvidence.contains(name)
                        // The mirror case, the neighbour rule: if the
                        // CLOSING tag's name is the one the siblings use
                        // and the OPENING tag's name is used by nothing
                        // else, the opening tag is the typo. Renaming the
                        // closing tag there would invent a new element
                        // name that appears nowhere in the file, which is
                        // what it used to do.
                        let closingNameIsEstablished =
                            siblingEvidence.contains(name) &&
                            !siblingEvidence.contains(intended.name)
                        if typoDepth < stack.count - 1 {
                            for unclosed in stack[(typoDepth + 1)...].reversed() {
                                if !addError(tagStart, tagLine,
                                    "Element <\(unclosed.name)> is never closed (opened on line \(unclosed.line))",
                                    fix: openingNameIsEstablished
                                        ? fixIt(NSRange(location: tagStart, length: 0),
                                                "</\(unclosed.name)>",
                                                "Insert </\(unclosed.name)> before </\(name)>")
                                        : nil) {
                                    break scanLoop
                                }
                            }
                        }
                        // v0.44.4: the rename is offered again whenever the
                        // misspelled close belongs to the innermost open
                        // element, the case where the Fix button used to
                        // be missing entirely. Renaming a closing tag never
                        // moves or drops content; if the OPEN tag was the
                        // typo the message still names its line.
                        let innermost = typoDepth == stack.count - 1
                        let offerRename = openingNameIsEstablished || innermost
                        let siblingCount = typoDepth > 0
                            ? stack[typoDepth - 1].completedChildNames.count : 0
                        _ = siblingCount
                        let ambiguityNote = (offerRename || closingNameIsEstablished) ? "" :
                            ", no automatic rename because either tag name may be the typo"
                        let renameOpening = closingNameIsEstablished && innermost
                        let message = renameOpening
                            ? "Mismatched pair: <\(intended.name)> on line \(intended.line) is the typo, the other elements here are named \(name)"
                            : "Mismatched closing tag </\(name)>, expected </\(intended.name)> (opened on line \(intended.line))\(ambiguityNote)"
                        let repair: XMLStreamParser.FixIt? = renameOpening
                            ? fixIt(intended.nameRange, name,
                                    "Change opening tag to <\(name)>")
                            : (offerRename
                                ? fixIt(closeNameRange, intended.name,
                                        "Change closing tag to </\(intended.name)>")
                                : nil)
                        if !addError(tagStart, tagLine, message, fix: repair) {
                            break scanLoop
                        }
                        stack.removeSubrange(typoDepth...)
                        if stack.isEmpty && rootWasOpened { break scanLoop }
                    } else {
                        // An unrelated close might be extra, or its opening
                        // tag might be what is missing. Deleting it is not an
                        // unambiguous repair, so keep the diagnostic but do
                        // not expose a destructive Fix button.
                        if !addError(tagStart, tagLine,
                            "Stray closing tag </\(name)>, no opening tag matches (currently inside <\(top.name)>, line \(top.line))") {
                            break scanLoop
                        }
                    }
                } else {
                    if !addError(tagStart, tagLine,
                        "Closing tag </\(name)> has no matching opening tag") {
                        break scanLoop
                    }
                }
                if stopAfterClosingTag { break scanLoop }
                continue
            }

            // Opening tag <name …> or <name …/>
            advance()   // consume '<'
            if i >= len {
                suppressEOFStackFixes = true
                if reachedDocEnd { _ = addError(tagStart, tagLine, "Stray '<' at end of text") }
                break scanLoop
            }
            if !isNameStart(ns.character(at: i)) {
                if !addError(tagStart, tagLine,
                    "Malformed tag, '<' must be immediately followed by a tag name (write &lt; for a literal '<')") {
                    break scanLoop
                }
                continue
            }
            let openNameStart = i
            let name = readName()
            let openNameRange = NSRange(location: openNameStart, length: i - openNameStart)

            // Attribute tokenizer, proper name/=/"value" parsing so we
            // can catch the mistakes people actually make when hand-
            // editing GCAM files: duplicated attributes (copy-paste
            // year="1975" year="1975"), a bare name with no value,
            // a missing '=', an unquoted value, an unclosed quote.
            var selfClosing = false
            var terminated = false
            var seenAttributes: [String: (text: String, isComplete: Bool)] = [:]

            attrLoop:
            while i < len {
                let a = ns.character(at: i)

                // Whitespace between attributes.
                if a == 0x20 || a == 0x09 || a == 0x0A || a == 0x0D {
                    advance(); continue
                }
                if a == 0x3E { // '>'
                    advance(); terminated = true
                    break attrLoop
                }
                if a == 0x2F { // '/', must be immediately followed by '>'
                    if i + 1 < len, ns.character(at: i+1) == 0x3E {
                        advance(); advance()
                        selfClosing = true; terminated = true
                        break attrLoop
                    }
                    let slashOffset = i
                    let slashLine = line
                    advance()
                    let whitespaceStart = i
                    while i < len, isXMLWhitespace(ns.character(at: i)) { advance() }
                    if i < len, ns.character(at: i) == 0x3E {
                        let whitespaceRange = NSRange(location: whitespaceStart,
                                                      length: i - whitespaceStart)
                        if !addError(slashOffset, slashLine,
                            "Whitespace is not allowed between '/' and '>' in a self-closing tag",
                            fix: fixIt(whitespaceRange, "",
                                       "Remove whitespace between '/' and '>'")) {
                            break scanLoop
                        }
                        // Recover as the clearly intended '/>' so the linter
                        // does not invent a dependent closing-element fix.
                        advance()
                        selfClosing = true; terminated = true
                        break attrLoop
                    }
                    if i >= len {
                        suppressEOFStackFixes = true
                        if reachedDocEnd {
                            let trailingRange = NSRange(location: whitespaceStart,
                                                        length: len - whitespaceStart)
                            _ = addError(slashOffset, slashLine,
                                "Self-closing tag <\(name) is missing its final '>'",
                                fix: fixIt(trailingRange, ">",
                                           "Finish the tag with '/>'"))
                            selfClosing = true; terminated = true
                        }
                        break attrLoop
                    }
                    if !addError(slashOffset, slashLine,
                        "Unexpected '/' in <\(name)>, '/' is only valid as part of '/>'") {
                        break scanLoop
                    }
                    continue
                }
                if a == 0x3C { // raw '<' inside a tag, tag never closed
                    if !addError(tagStart, tagLine,
                        "Unterminated tag <\(name) (missing '>'), opened on line \(tagLine)",
                        fix: fixIt(NSRange(location: i, length: 0), ">",
                                   "Insert '>' before the next '<'")) {
                        break scanLoop
                    }
                    // Virtually accept the suggested '>' and keep this node
                    // on the stack. That avoids a cascade of fake stray-close
                    // errors while the user is deciding whether to apply it.
                    terminated = true
                    break attrLoop
                }
                if a == 0x22 || a == 0x27 { // quote with no name= before it
                    if !addError(i, line,
                        "Unexpected quote in <\(name)>, attributes must be written name=\"value\"") {
                        break scanLoop
                    }
                    if case .closed = skipQuoted(a) {
                        continue
                    } else {
                        suppressEOFStackFixes = true
                        break scanLoop
                    }
                }

                if isNameStart(a) {
                    let attrStart = i
                    let attrName = readName()
                    var attributeIsComplete = false
                    // Skip whitespace between name and '='.
                    while i < len {
                        let w = ns.character(at: i)
                        if w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D { advance() } else { break }
                    }
                    if i < len, ns.character(at: i) == 0x3D { // '='
                        advance()
                        while i < len {
                            let w = ns.character(at: i)
                            if isXMLWhitespace(w) { advance() } else { break }
                        }
                        if i < len {
                            let v = ns.character(at: i)
                            if v == 0x22 || v == 0x27 {
                                let qStart = i, qLine = line
                                let errorsBeforeValue = errors.count
                                switch skipQuoted(v,
                                                  entityContext: "attribute '\(attrName)' in <\(name)>") {
                                case .closed:
                                    attributeIsComplete = errors.count == errorsBeforeValue
                                    if i < len, isNameStart(ns.character(at: i)),
                                       !addError(i, line,
                                            "Attributes in <\(name)> must be separated by whitespace",
                                            fix: fixIt(NSRange(location: i, length: 0), " ",
                                                       "Insert space before the next attribute")) {
                                        break scanLoop
                                    }
                                case .missingQuoteBeforeTagEnd(let tagEnd):
                                    let quote = String(UnicodeScalar(UInt32(v))!)
                                    if !addError(qStart, qLine,
                                        "Attribute value quote is never closed in <\(name)> before its '>'",
                                        fix: fixIt(NSRange(location: tagEnd, length: 0), quote,
                                                   "Insert the missing \(quote) before '>'")) {
                                        break scanLoop
                                    }
                                    // skipQuoted stopped at the following '<'.
                                    // Recover as though the quote were present.
                                    terminated = true
                                    break attrLoop
                                case .rawLessThan(let rawOffset):
                                    suppressEOFStackFixes = true
                                    if !addError(rawOffset, line,
                                        "Raw '<' is not allowed inside attribute '\(attrName)' in <\(name)>; either close the quote before it or write &lt;") {
                                        break scanLoop
                                    }
                                    break scanLoop
                                case .endOfInput:
                                    suppressEOFStackFixes = true
                                    if reachedDocEnd {
                                        let quote = String(UnicodeScalar(UInt32(v))!)
                                        _ = addError(qStart, qLine,
                                            "Attribute value quote and tag are never closed in <\(name)>",
                                            fix: fixIt(NSRange(location: len, length: 0), "\(quote)>",
                                                       "Append the missing \(quote) and '>'"))
                                        // Preserve structural recovery, but
                                        // suppress dependent EOF close fixes.
                                        terminated = true
                                    }
                                    break attrLoop
                                case .errorLimit:
                                    break scanLoop
                                }
                            } else if v == 0x3E || v == 0x2F {
                                if !addError(i, line,
                                    "Attribute '\(attrName)' in <\(name)> has no value after '='",
                                    fix: fixIt(NSRange(location: i, length: 0), "\"\"",
                                               "Insert \"\" after \(attrName)=")) {
                                    break scanLoop
                                }
                            } else {
                                // Unquoted value, measure the token
                                // first so the repair can wrap exactly
                                // it in quotes.
                                let tokStart = i, tokLine = line
                                var tokenEntitiesAreValid = true
                                while i < len {
                                    let e = ns.character(at: i)
                                    if isXMLWhitespace(e) || e == 0x3E || e == 0x2F ||
                                       e == 0x22 || e == 0x27 { break }
                                    if e == 0x26 {
                                        let entity = consumeEntityReference(
                                            context: "attribute '\(attrName)' in <\(name)>")
                                        tokenEntitiesAreValid = tokenEntitiesAreValid && entity.valid
                                        if !entity.canContinue { break scanLoop }
                                        continue
                                    }
                                    advance()
                                }
                                let tokRange = NSRange(location: tokStart, length: i - tokStart)
                                let token = ns.substring(with: tokRange)
                                let hasClosingQuote: Bool
                                if i < len,
                                   (ns.character(at: i) == 0x22 || ns.character(at: i) == 0x27) {
                                    let after = i + 1
                                    hasClosingQuote = after >= len || isXMLWhitespace(ns.character(at: after)) ||
                                        ns.character(at: after) == 0x3E || ns.character(at: after) == 0x2F
                                } else {
                                    hasClosingQuote = false
                                }
                                if hasClosingQuote {
                                    let quote = ns.character(at: i)
                                    let quoteString = String(UnicodeScalar(UInt32(quote))!)
                                    if !addError(tokStart, tokLine,
                                        "Attribute '\(attrName)' in <\(name)> is missing its opening quote",
                                        fix: tokenEntitiesAreValid
                                            ? fixIt(NSRange(location: tokStart, length: 0), quoteString,
                                                    "Insert opening \(quoteString) before \(token)")
                                            : nil) {
                                        break scanLoop
                                    }
                                    advance() // consume the existing closing quote
                                } else if !addError(tokStart, tokLine,
                                    "Attribute value of '\(attrName)' in <\(name)> must be quoted (use \(attrName)=\"…\")",
                                    fix: tokenEntitiesAreValid
                                        ? fixIt(tokRange, "\"\(token)\"",
                                                "Wrap in quotes: \(attrName)=\"\(token)\"")
                                        : nil) {
                                    break scanLoop
                                }
                            }
                        }
                    } else if i < len,
                              (ns.character(at: i) == 0x22 || ns.character(at: i) == 0x27) {
                        // `year "2020"` has an obvious single-character
                        // omission: insert '=' rather than replacing the
                        // attribute with an empty value.
                        let quoteOffset = i
                        if !addError(quoteOffset, line,
                            "Attribute '\(attrName)' in <\(name)> is missing '=' before its quoted value",
                            fix: fixIt(NSRange(location: quoteOffset, length: 0), "=",
                                       "Insert '=' before the quoted value")) {
                            break scanLoop
                        }
                        if case .closed = skipQuoted(ns.character(at: quoteOffset),
                                                     entityContext: "attribute '\(attrName)' in <\(name)>") {
                            // recovered for continued scanning
                            if i < len, isNameStart(ns.character(at: i)),
                               !addError(i, line,
                                    "Attributes in <\(name)> must be separated by whitespace",
                                    fix: fixIt(NSRange(location: i, length: 0), " ",
                                               "Insert space before the next attribute")) {
                                break scanLoop
                            }
                        } else {
                            suppressEOFStackFixes = true
                            break scanLoop
                        }
                    } else {
                        // Name with no '=' at all, legal in HTML, not XML.
                        // v0.44.4: offer the repair again where nothing can be
                        // lost: `abc>`, `abc/>` and `abc other="…"` become
                        // abc="", and a bare following word (`name USA`)
                        // becomes the quoted value.
                        var look = i
                        while look < len, isXMLWhitespace(ns.character(at: look)) { look += 1 }
                        var valueFix: XMLStreamParser.FixIt? = nil
                        if look < len {
                            let c = ns.character(at: look)
                            if c == 0x3E || c == 0x2F {
                                valueFix = fixIt(NSRange(location: i, length: 0), "=\"\"",
                                                 "Change to \(attrName)=\"\"")
                            } else if isNameStart(c) {
                                var tokEnd = look
                                while tokEnd < len, isNameChar(ns.character(at: tokEnd)) { tokEnd += 1 }
                                var after = tokEnd
                                while after < len, isXMLWhitespace(ns.character(at: after)) { after += 1 }
                                let afterChar: unichar = after < len ? ns.character(at: after) : 0x3E
                                if afterChar == 0x3D {
                                    valueFix = fixIt(NSRange(location: i, length: 0), "=\"\"",
                                                     "Change to \(attrName)=\"\"")
                                } else if afterChar == 0x3E || afterChar == 0x2F || isNameStart(afterChar) {
                                    let token = ns.substring(with: NSRange(location: look, length: tokEnd - look))
                                    valueFix = fixIt(NSRange(location: i, length: tokEnd - i), "=\"\(token)\"",
                                                     "Change to \(attrName)=\"\(token)\"")
                                }
                            }
                        }
                        if !addError(i, line,
                            "Attribute '\(attrName)' in <\(name)> has no value (XML requires \(attrName)=\"value\")",
                            fix: valueFix) {
                            break scanLoop
                        }
                    }
                    // Duplicate check regardless of how the value parsed.
                    let attributeRange = NSRange(location: attrStart,
                                                 length: i - attrStart)
                    let attributeText = ns.substring(with: attributeRange)
                    if let first = seenAttributes[attrName] {
                        let isExactlyRedundant = attributeIsComplete &&
                            first.isComplete && first.text == attributeText
                        if !addError(i, line,
                            "Duplicate attribute '\(attrName)' in <\(name)>",
                            fix: isExactlyRedundant
                                ? fixIt(attributeRange, "",
                                        "Delete exactly redundant \(attrName)")
                                : nil) {
                            break scanLoop
                        }
                    } else {
                        seenAttributes[attrName] = (attributeText, attributeIsComplete)
                    }
                    continue
                }

                // Anything else inside a tag is illegal. Consume a compact
                // token so malformed GCAM edits cannot be reported as clean,
                // but omit a FixIt because deletion/reinterpretation is not
                // semantically safe.
                let junkStart = i, junkLine = line
                advance()
                while i < len {
                    let j = ns.character(at: i)
                    if isXMLWhitespace(j) || j == 0x3E || j == 0x2F ||
                       j == 0x3C || isNameStart(j) { break }
                    advance()
                }
                let junk = ns.substring(with: NSRange(location: junkStart,
                                                       length: i - junkStart))
                if !addError(junkStart, junkLine,
                    "Unexpected token '\(junk)' in <\(name)>, attributes must be written name=\"value\"") {
                    break scanLoop
                }
            }

            if !terminated {
                // Window ended inside the tag.
                if reachedDocEnd {
                    suppressEOFStackFixes = true
                    _ = addError(tagStart, tagLine,
                        "Unterminated tag <\(name) (missing '>'), opened on line \(tagLine)",
                        fix: fixIt(NSRange(location: len, length: 0), ">",
                                   "Append '>' to <\(name)"))
                    // Recover for the EOF missing-element-close suggestions.
                    terminated = true
                }
            }
            if !selfClosing && terminated {
                stack.append((name, tagLine, openNameRange, []))
                rootWasOpened = true
            } else if selfClosing {
                if !stack.isEmpty {
                    stack[stack.count - 1].completedChildNames.insert(name)
                } else if !rootWasOpened {
                    // The selected validation scope itself is self-closing.
                    // Everything after it belongs to a sibling and must not leak
                    // into this scope's Errors tab.
                    rootWasOpened = true
                    break scanLoop
                }
            }
            if i >= len { break scanLoop }
        }

        // End of window: whatever is still open was never closed, 
        // but ONLY report that when the window truly reached the end
        // of the document. If we cut at the cap, the closes may just
        // be past the cut.
        if reachedDocEnd && !suppressEOFStackFixes {
            for depth in stack.indices.reversed() {
                if errors.count >= maxErrors { break }
                let unclosed = stack[depth]
                // Closing an outer element also requires every still-open
                // descendant to close first. The suffix is insertion-only
                // and deterministic; it never deletes or rewrites content.
                let closingSuffix = stack[depth...].reversed()
                    .map { "</\($0.name)>" }
                    .joined()
                errors.append(XMLStreamParser.ParseError(
                    line: unclosed.line, column: 1,
                    message: "Element <\(unclosed.name)> is never closed (opened on line \(unclosed.line))",
                    fix: fixIt(NSRange(location: len, length: 0), closingSuffix,
                               closingSuffix == "</\(unclosed.name)>"
                                ? "Append </\(unclosed.name)>"
                                : "Append missing closing tags through </\(unclosed.name)>")))
            }
        }

        return errors
    }
}
