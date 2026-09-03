// CSVExport.swift
//
// One place for "save a table the user will open in Excel".
//
// Why this file exists: the first CSV exports were plain UTF-8 with
// no byte-order mark. Excel for Mac guesses the encoding of a .csv
// that has no mark, and it guesses MacRoman, so the pretty "›"
// separator inside a tree path (U+203A, UTF-8 bytes E2 80 BA) landed
// in the sheet as ",Äƒ". It first showed up on a Find All export.
//
// Two fixes, both needed:
//   1. Write a UTF-8 byte-order mark so the spreadsheet stops guessing.
//   2. Fold the typographic characters we use on screen down to plain
//      ASCII in the file only, so the export reads the same in every
//      app on every platform. The user interface keeps its nice glyphs.

import Foundation

enum CSVExport {

    // Screen glyph on the left, file-safe ASCII on the right.
    private static let plainSwaps: [(String, String)] = [
        ("\u{203A}", ">"),      // ›  path separator
        ("\u{2039}", "<"),      // ‹
        ("\u{25B8}", ">"),      // ▸  menu separator
        ("\u{25BE}", ""),       // ▾  dropdown marker
        ("\u{2192}", "->"),     // →
        ("\u{2026}", "..."),    // …
        ("\u{201C}", "\""),     // “
        ("\u{201D}", "\""),     // ”
        ("\u{2018}", "'"),      // ‘
        ("\u{2019}", "'"),      // ’
        ("\u{00A0}", " "),      // non-breaking space
    ]

    /// Replace screen-only typography with plain ASCII.
    static func asciiFriendly(_ s: String) -> String {
        var out = s
        for (fancy, plain) in plainSwaps {
            if out.contains(fancy) { out = out.replacingOccurrences(of: fancy, with: plain) }
        }
        return out
    }

    /// A quoted CSV field. Quotes inside are doubled, and any newline
    /// or tab inside a cell becomes a space so one record stays on one
    /// line.
    ///
    /// `foldTypography` is for strings THIS APP composed, such as a tree
    /// path built with "›" separators. Leave it off for anything lifted
    /// out of the user's file: that has to reach the sheet unchanged,
    /// and the byte-order mark already makes it read correctly.
    static func field(_ s: String, foldTypography: Bool = false) -> String {
        var v = foldTypography ? asciiFriendly(s) : s
        v = v.replacingOccurrences(of: "\r\n", with: " ")
        v = v.replacingOccurrences(of: "\n", with: " ")
        v = v.replacingOccurrences(of: "\r", with: " ")
        v = v.replacingOccurrences(of: "\t", with: " ")
        v = v.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"" + v + "\""
    }

    /// A number cell. A value that is not finite would otherwise land in
    /// the sheet as the bare word nan or inf, which every spreadsheet
    /// reads as text and which quietly poisons a column of numbers.
    static func number(_ v: Double) -> String {
        v.isFinite ? "\(v)" : ""
    }

    /// Write a table. `header` and each row hold cells that are already
    /// quoted with `field(_:)` where they are text, or left bare where
    /// they are numbers. Rows end with CRLF, which is what spreadsheets
    /// expect, and the file opens with a UTF-8 mark.
    @discardableResult
    static func write(header: [String], rows: [[String]], to url: URL) -> Bool {
        var text = header.joined(separator: ",")
        text += "\r\n"
        for r in rows {
            text += r.joined(separator: ",")
            text += "\r\n"
        }
        var data = Data([0xEF, 0xBB, 0xBF])           // UTF-8 byte-order mark
        data.append(Data(text.utf8))
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
