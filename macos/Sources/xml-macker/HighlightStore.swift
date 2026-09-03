// HighlightStore.swift
//
// Marker strokes remembered per file, ported from the Windows edition's
// Shared/HighlightStore.cs.
//
// A stroke is stored as the line and column it starts on, its length, its
// colour, and the text it covers. Offsets alone would be wrong the moment
// the file is edited by anything else, so on load a mark is first tried
// where it was and, if the text there no longer matches, looked for on
// the nearest lines. A mark whose text cannot be found is dropped rather
// than left pointing at the wrong words.

import Foundation
import CryptoKit

enum HighlightStore {

    private struct Mark: Codable {
        var line: Int          // 1-based
        var column: Int        // 0-based within the line
        var length: Int
        var color: Int
        var text: String       // up to 200 characters, for re-anchoring
    }

    /// How far to look when the file changed outside the app.
    private static let searchRadius = 400

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("xml-macker/highlights", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(for url: URL) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(url.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(name).json")
    }

    /// Line start offsets, so a stroke can be described by line and column.
    private static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        let n = text.length
        while i < n {
            if text.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private static func lineIndex(_ starts: [Int], _ offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func save(_ strokes: TextHighlights, for url: URL, text: String) {
        let path = file(for: url)
        guard !strokes.isEmpty else {
            try? FileManager.default.removeItem(at: path)
            return
        }
        let ns = text as NSString
        let starts = lineStarts(ns)
        var marks: [Mark] = []
        for r in strokes.ranges {
            guard r.start >= 0, r.start < ns.length else { continue }
            let li = lineIndex(starts, r.start)
            let len = min(r.length, ns.length - r.start)
            guard len > 0 else { continue }
            marks.append(Mark(line: li + 1,
                              column: r.start - starts[li],
                              length: r.length,
                              color: r.color.rawValue,
                              text: ns.substring(with: NSRange(location: r.start, length: min(len, 200)))))
        }
        if let data = try? JSONEncoder().encode(marks) {
            try? data.write(to: path, options: .atomic)
        }
    }

    static func load(into strokes: TextHighlights, for url: URL, text: String) {
        guard let data = try? Data(contentsOf: file(for: url)),
              let marks = try? JSONDecoder().decode([Mark].self, from: data) else { return }
        let ns = text as NSString
        let starts = lineStarts(ns)
        var out: [HighlightRange] = []
        for m in marks {
            guard let colour = HighlightColor(rawValue: m.color), colour != .none, m.length > 0 else { continue }
            let want = m.text
            let probe = min(want.count, m.length)
            func matches(_ at: Int) -> Bool {
                guard probe > 0 else { return true }
                guard at >= 0, at + probe <= ns.length else { return false }
                return ns.substring(with: NSRange(location: at, length: probe)) == String(want.prefix(probe))
            }
            // Where it was.
            var offset = -1
            let li = m.line - 1
            if li >= 0, li < starts.count {
                let at = starts[li] + max(0, m.column)
                if matches(at) { offset = at }
            }
            // Otherwise the nearest line carrying the same text.
            if offset < 0, !want.isEmpty {
                var best = -1
                var bestDistance = Int.max
                let from = max(0, li - searchRadius)
                let to = min(starts.count - 1, li + searchRadius)
                if from <= to {
                    for l in from...to {
                        let lineEnd = l + 1 < starts.count ? starts[l + 1] : ns.length
                        let lineRange = NSRange(location: starts[l], length: max(0, lineEnd - starts[l]))
                        let found = ns.range(of: String(want.prefix(probe)), options: [], range: lineRange)
                        if found.location != NSNotFound {
                            let d = abs(l - li)
                            if d < bestDistance { bestDistance = d; best = found.location }
                        }
                    }
                }
                offset = best
            }
            guard offset >= 0 else { continue }   // its text is gone; drop it
            out.append(HighlightRange(start: offset,
                                      length: min(m.length, max(0, ns.length - offset)),
                                      color: colour))
        }
        strokes.replaceAll(out)
    }
}
