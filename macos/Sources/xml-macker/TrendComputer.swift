import Foundation

// Compute a trend series for the selected element, or nil if the
// selection doesn't have a meaningful numeric comparison to show.
//
// The rule (reinforced after the config.xml false-positive):
//   • LINE chart: when the repeating axis itself has a `year` /
//     `period` / `time` attribute (classic time series, 
//     e.g. <period year="1975">, <period year="1990">, ...).
//   • BAR chart: when the repeater has a non-time key (e.g. `name`)
//     BUT the leaf (or an ancestor on the path-down) is fixed to a
//     specific year. That is the "same year, different subsector"
//     comparison a transportation file calls for.
//     The contextYear is surfaced in the title so the chart reads
//     e.g. "logit-exponent · 2 tranSubsectors (year 1975)".
//   • No chart: everything else, e.g. <Value name="CalibrationActive">
//     in config.xml, where 11 same-tag siblings are unrelated flags
//     that happen to share a tag name.
enum TrendKind {
    case line     // time series, left→right progression
    case bar      // categorical comparison at a fixed moment
}

struct TrendSeries {
    let title: String
    let xLabels: [String]
    // Real x coordinates for line series whose labels are numbers
    // (years), so irregular GCAM periods (1975, 1990, 2005, 2010…) are
    // spaced by their true distance. Nil for categorical bars.
    let xPositions: [Double]?
    let values: [Double]
    let min: Double
    let max: Double
    let kind: TrendKind
}

enum TrendComputer {

    // Every numeric-leaf name available under `node` that could be
    // turned into a trend series. Feeds the "variable" dropdown that
    // sits above the inline chart in v0.16.0, GCAM files often have
    // several numeric children under one element (emiss-coef,
    // share-weight, input-emissions, intensity, …) and the user
    // wants to pick which one to plot.
    static func availableTargets(for node: XMLTreeNode) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        if isNumericLeaf(node) {
            if seen.insert(node.name).inserted { out.append(node.name) }
        }
        for c in node.children where c.kind == .element && isNumericLeaf(c) {
            if seen.insert(c.name).inserted { out.append(c.name) }
        }
        // One level deeper too (v1.0.5): the values a <period> keeps inside
        // its inputs, <minicam-energy-input> → efficiency, calibrated-value.
        // Without this, share-weight would be the only variable offered.
        for c in node.children where c.kind == .element {
            for g in c.children where g.kind == .element && isNumericLeaf(g) {
                if seen.insert(g.name).inserted { out.append(g.name) }
            }
        }
        // Universal layer (v0.43.0): variables discovered by the
        // generic repeat-detector below, deduped against the GCAM
        // ones. Generic-only spellings start with @ / = / #, all
        // illegal as XML tag starts, so they can never collide with
        // a real leaf name.
        for g in genericGroups(for: node) {
            for v in genericVars(in: g) {
                if seen.insert(v.display).inserted { out.append(v.display) }
            }
        }
        return out
    }

    // Router (v0.43.0): the GCAM rules keep first claim, identical
    // behavior on GCAM files, and the universal layer answers
    // whenever they come up empty, so a chart can appear in any file,
    // whatever its shape, not only in GCAM ones.
    static func compute(for node: XMLTreeNode,
                        preferring preferred: String? = nil) -> TrendSeries? {
        if let p = preferred, p.hasPrefix("@") || p.hasPrefix("=") || p.hasPrefix("#") {
            return genericCompute(for: node, preferring: p)
        }
        if let s = gcamCompute(for: node, preferring: preferred) { return s }
        return genericCompute(for: node, preferring: preferred)
    }

    private static let insideMaxDepth = 8
    private static let insideMaxContainers = 4000

    /// The chain of elements from just below `start` down to the first
    /// numeric leaf, shallowest first. Empty when `start` is that leaf,
    /// nil when there is none within reach.
    private static func leafPathBelow(_ start: XMLTreeNode, preferring preferred: String?) -> [XMLTreeNode]? {
        func wanted(_ n: XMLTreeNode) -> Bool {
            isNumericLeaf(n) && (preferred == nil || preferred!.isEmpty || n.name == preferred!)
        }
        if wanted(start) { return [] }
        var queue: [(node: XMLTreeNode, depth: Int)] = [(start, 0)]
        var parentOf: [ObjectIdentifier: XMLTreeNode] = [:]
        var head = 0, seen = 0
        while head < queue.count, seen < 2000 {
            let (n, depth) = queue[head]; head += 1; seen += 1
            for c in n.children where c.kind == .element {
                parentOf[ObjectIdentifier(c)] = n
                if wanted(c) {
                    var chain: [XMLTreeNode] = []
                    var x: XMLTreeNode = c
                    while x !== start {
                        chain.insert(x, at: 0)
                        guard let p = parentOf[ObjectIdentifier(x)] else { break }
                        x = p
                    }
                    return chain
                }
                if depth + 1 < 6 { queue.append((c, depth + 1)) }
            }
        }
        return nil
    }

    /// Chart what is INSIDE the selection first.
    ///
    /// Selecting a supplysector called "iron and steel" used to give a
    /// chart of 32 regions, because the old rule walked UP from the first
    /// numeric leaf until it found a repeating level, and the nearest one
    /// above was the regions. The shallowest repeating level BELOW the
    /// selection is the one being read, so that is tried first: a
    /// level keyed by year or period becomes a line, otherwise the
    /// shallowest plain level with a year pinned becomes a bar.
    private static func insideCompute(for node: XMLTreeNode, preferring preferred: String?) -> TrendSeries? {
        if isNumericLeaf(node) { return nil }        // a value has nothing inside
        var queue: [(container: XMLTreeNode, depth: Int)] = [(node, 0)]
        var head = 0, seen = 0
        var timeHit: (group: Group, path: [XMLTreeNode], target: XMLTreeNode)?
        var barHit: (group: Group, path: [XMLTreeNode], target: XMLTreeNode, year: String)?

        while head < queue.count, seen < insideMaxContainers {
            let (container, depth) = queue[head]; head += 1; seen += 1
            for g in sameNameGroups(in: container.children) {
                guard let first = g.members.first,
                      let path = leafPathBelow(first, preferring: preferred) else { continue }
                let target = path.last ?? first
                if hasTimeKey(first) {
                    if timeHit == nil { timeHit = (g, path, target) }
                } else if barHit == nil,
                          let year = collectContextYear(target: target, path: path) {
                    barHit = (g, path, target, year)
                }
            }
            if timeHit != nil { break }              // the shallowest time level wins outright
            if depth < insideMaxDepth {
                for c in container.children where c.kind == .element {
                    queue.append((c, depth + 1))
                }
            }
        }

        if let t = timeHit, let first = t.group.members.first {
            return buildSeries(target: t.target, path: t.path, siblings: t.group.members,
                               repeater: first, kind: .line, context: nil)
        }
        if let b = barHit, let first = b.group.members.first {
            return buildSeries(target: b.target, path: b.path, siblings: b.group.members,
                               repeater: first, kind: .bar, context: "year \(b.year)")
        }
        return nil
    }

    /// The attributes GCAM uses to name a thing. An ancestor carrying one
    /// of these is a place the user is "in", region USA for instance.
    private static let keyAttributes = ["name", "year", "type", "id", "key"]

    private static func isKeyed(_ n: XMLTreeNode) -> Bool {
        n.attributes.contains { keyAttributes.contains($0.name) }
    }

    /// Nothing repeats inside the selection, so look just OUTSIDE it, but
    /// without leaving the named thing it belongs to.
    ///
    /// The case that drives this: relative-cost-logit inside the "iron
    /// and steel" supplysector inside region USA. Nothing repeats inside
    /// it, and the plain climb ran all the way up to the 32 regions,
    /// which is not what someone reading one region is asking about.
    /// This walks up instead, one ancestor at a time, charting the first
    /// level that repeats inside that ancestor, and stops at the first
    /// ancestor with a name of its own, so a chart taken inside USA stays
    /// inside USA.
    /// Comparing regions is still one click away: select world.
    private static func nearbyCompute(for node: XMLTreeNode, preferring preferred: String?) -> TrendSeries? {
        guard let wanted = preferred ?? findNumericLeafTarget(from: node, preferring: preferred)?.name
        else { return nil }
        var ancestor = node.parent
        var climbed = 0
        while let here = ancestor, climbed < 12 {
            if let series = insideCompute(for: here, preferring: wanted) { return series }
            if isKeyed(here) { return nil }         // do not leave this named thing
            ancestor = here.parent
            climbed += 1
        }
        return nil
    }

    private static func gcamCompute(for node: XMLTreeNode,
                                    preferring preferred: String? = nil) -> TrendSeries? {
        // Inside the selection first; only then climb.
        if let inside = insideCompute(for: node, preferring: preferred) { return inside }
        // Then just outside it, without leaving the named thing it is in.
        if let nearby = nearbyCompute(for: node, preferring: preferred) { return nearby }

        guard let target = findNumericLeafTarget(from: node, preferring: preferred) else {
            return nil
        }

        var pathDown: [XMLTreeNode] = []
        struct Candidate { let siblings: [XMLTreeNode]; let path: [XMLTreeNode]; let repeater: XMLTreeNode }
        var timeRepeater: Candidate?
        var fallbackRepeater: Candidate?

        var cursor: XMLTreeNode? = target
        while let here = cursor, let parent = here.parent {
            let siblings = parent.children.filter {
                $0.kind == .element && $0.name == here.name
            }
            if siblings.count >= 2 {
                let cand = Candidate(siblings: siblings, path: pathDown, repeater: here)
                if hasTimeKey(here), timeRepeater == nil {
                    timeRepeater = cand
                } else if fallbackRepeater == nil {
                    fallbackRepeater = cand
                }
            }
            pathDown.insert(here, at: 0)
            cursor = parent
        }

        // Prefer a true time-axis repeater.
        if let r = timeRepeater {
            return buildSeries(target: target,
                               path: r.path,
                               siblings: r.siblings,
                               repeater: r.repeater,
                               kind: .line,
                               context: nil)
        }

        // Non-time repeater: only accept if the target (or something
        // on the way down) has a year/period attribute. That gives
        // us a legitimate "at year X, across categories" comparison.
        if let r = fallbackRepeater,
           let contextYear = collectContextYear(target: target, path: r.path) {
            return buildSeries(target: target,
                               path: r.path,
                               siblings: r.siblings,
                               repeater: r.repeater,
                               kind: .bar,
                               context: "year \(contextYear)")
        }
        return nil
    }

    private static func findNumericLeafTarget(from node: XMLTreeNode,
                                              preferring preferred: String? = nil) -> XMLTreeNode? {
        // If the user picked a specific variable from the chart's
        // dropdown, that choice is BINDING: either we chart exactly
        // that leaf or we chart nothing. The old fall-through to "any
        // numeric leaf" silently swapped variables, dropdown said
        // addTimeValue (a 0/1 flag), chart showed speed values of 450.
        if let preferred = preferred {
            if isNumericLeaf(node), node.name == preferred { return node }
            if let c = node.children.first(where: {
                $0.kind == .element && $0.name == preferred && isNumericLeaf($0)
            }) { return c }
            for c in node.children where c.kind == .element {
                if let g = c.children.first(where: {
                    $0.kind == .element && $0.name == preferred && isNumericLeaf($0)
                }) { return g }
            }
            return nil
        }
        if isNumericLeaf(node) { return node }
        for c in node.children where c.kind == .element {
            if isNumericLeaf(c) { return c }
        }
        for c in node.children where c.kind == .element {
            for g in c.children where g.kind == .element && isNumericLeaf(g) { return g }
        }
        return nil
    }

    private static func isNumericLeaf(_ n: XMLTreeNode) -> Bool {
        let hasKids = n.children.contains(where: { $0.kind == .element })
        if hasKids { return false }
        let trimmed = n.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed) != nil
    }

    private static func hasTimeKey(_ node: XMLTreeNode) -> Bool {
        for (name, _) in node.attributes {
            let lc = name.lowercased()
            if lc == "year" || lc == "period" || lc == "time" { return true }
        }
        return false
    }

    // Look for a `year` attribute on the target itself or on any of
    // the intermediate path-down nodes (typically <logit-exponent
    // year="1975"> sits below the repeater). Returns the year value
    // as a string, or nil if none was found.
    private static func collectContextYear(target: XMLTreeNode, path: [XMLTreeNode]) -> String? {
        for node in [target] + path {
            for (name, value) in node.attributes {
                let lc = name.lowercased()
                if lc == "year" || lc == "period" { return value }
            }
        }
        return nil
    }

    private static func buildSeries(target: XMLTreeNode,
                                    path: [XMLTreeNode],
                                    siblings: [XMLTreeNode],
                                    repeater: XMLTreeNode,
                                    kind: TrendKind,
                                    context: String?) -> TrendSeries? {
        var points: [(label: String, value: Double)] = []
        for sib in siblings {
            guard let leaf = walk(from: sib, matching: path) else { continue }
            let str = leaf.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Swift parses "nan" and "inf" happily. One of those in the
            // file made the whole chart render blank, so reject them here.
            guard let val = Double(str), val.isFinite else { continue }
            points.append((labelFor(sib), val))
        }
        guard points.count >= 2 else { return nil }
        if kind == .line, points.allSatisfy({ Int($0.label) != nil }) {
            points.sort { Int($0.label)! < Int($1.label)! }
        }
        let xs = points.map { $0.label }
        let ys = points.map { $0.value }
        let minV = ys.min() ?? 0
        let maxV = ys.max() ?? 0
        let repeaterName = repeater.name
        var title = "\(target.name) · \(ys.count) \(repeaterName)\(ys.count == 1 ? "" : "s")"
        if let ctx = context { title += " (\(ctx))" }
        return TrendSeries(title: title, xLabels: xs,
                           xPositions: kind == .line ? numericPositions(xs) : nil,
                           values: ys, min: minV, max: maxV, kind: kind)
    }

    // Only when every label parses and they strictly increase; anything
    // else falls back to even spacing.
    private static func numericPositions(_ labels: [String]) -> [Double]? {
        let nums = labels.compactMap { Double($0) }
        guard nums.count == labels.count, nums.count >= 2 else { return nil }
        for i in 1..<nums.count where nums[i] <= nums[i - 1] { return nil }
        return nums
    }

    private static let keyAttributeNames = ["name", "year", "type", "id", "key"]

    private static func walk(from start: XMLTreeNode, matching path: [XMLTreeNode]) -> XMLTreeNode? {
        var cur = start
        for step in path {
            let candidates = cur.children.filter { $0.kind == .element && $0.name == step.name }
            if candidates.isEmpty { return nil }
            if candidates.count == 1 {
                // Single candidate, but if the step carries a key
                // attribute (year/name/…), the candidate must carry the
                // SAME key. Without this check, comparing e.g.
                // share-weight year="1975" across technologies silently
                // picked up a sibling's share-weight for a DIFFERENT
                // year when it only had one, mixing years in a chart
                // titled "(year 1975)". Wrong data, so the sibling is
                // excluded instead.
                if stepHasKey(step) && !keysMatch(candidates[0], step) {
                    return nil
                }
                cur = candidates[0]
                continue
            }
            if let match = candidates.first(where: { keysMatch($0, step) }) {
                cur = match
            } else {
                return nil
            }
        }
        return cur
    }

    private static func stepHasKey(_ node: XMLTreeNode) -> Bool {
        node.attributes.contains { keyAttributeNames.contains($0.name) }
    }

    private static func keysMatch(_ a: XMLTreeNode, _ b: XMLTreeNode) -> Bool {
        for keyName in keyAttributeNames {
            let av = a.attributes.first(where: { $0.name == keyName })?.value
            let bv = b.attributes.first(where: { $0.name == keyName })?.value
            if av != nil || bv != nil { return av == bv }
        }
        return false
    }

    private static func labelFor(_ node: XMLTreeNode) -> String {
        for key in ["year", "name", "period", "id"] {
            if let v = node.attributes.first(where: { $0.name == key })?.value {
                return v
            }
        }
        return node.attributes.first?.value ?? node.name
    }

    // MARK: - Universal chart layer (v0.43.0)
    //
    // The universal shape of chartable XML, in ANY format, is:
    // a structure that REPEATS (≥2 same-tag element siblings)
    // carrying a NUMBER (numeric attribute, numeric text, or numeric
    // leaf child) plus some LABEL (a key attribute, a <title>/<name>
    // child, or simply position 1…N). GPX track points, plist arrays,
    // SVG shapes, verses per chapter, all reduce to this.

    private struct Group {
        let name: String
        let members: [XMLTreeNode]
    }

    private enum GenericVar: Equatable {
        case attribute(String)   // "@lat", numeric attribute on each member
        case ownText             // "= value", the member's own text is the number
        case valueChild(String)  // numeric leaf child of each member

        var display: String {
            switch self {
            case .attribute(let n):  return "@\(n)"
            case .ownText:           return "= value"
            case .valueChild(let n): return n
            }
        }
    }

    // Attributes that act as LABELS, never as values to plot, 
    // charting "@year" against year would be nonsense.
    private static let labelAttrNames: Set<String> =
        ["year", "period", "time", "date", "id", "name", "key", "label", "title"]

    private static let childScanCap = 2000

    private static func sameNameGroups(in children: [XMLTreeNode]) -> [Group] {
        var order: [String] = []
        var byName: [String: [XMLTreeNode]] = [:]
        for c in children.prefix(childScanCap) where c.kind == .element {
            if byName[c.name] == nil { order.append(c.name) }
            byName[c.name, default: []].append(c)
        }
        return order.compactMap { name in
            guard let m = byName[name], m.count >= 2 else { return nil }
            return Group(name: name, members: m)
        }.sorted { $0.members.count > $1.members.count }
    }

    // Candidate repeats, nearest first: the node's own repeating
    // children (user selected the container), then the node and its
    // same-name siblings (user selected one member). Nothing deeper
    // (v0.44.4): a grandchild group made a region show one supply
    // sector's subsectors, "Domestic Ship at the level of USA", which
    // broke the rule that a chart belongs to the selected element
    // and its own family.
    private static func genericGroups(for node: XMLTreeNode) -> [Group] {
        var out: [Group] = []
        out.append(contentsOf: sameNameGroups(in: node.children).prefix(2))
        if let parent = node.parent {
            let sibs = parent.children.filter { $0.kind == .element && $0.name == node.name }
            if sibs.count >= 2 { out.append(Group(name: node.name, members: sibs)) }
        }
        return out
    }

    // What can be plotted for this repeat? Sampled over the first 40
    // members; a variable qualifies when ≥80% of the sample carries
    // a parseable number for it.
    private static func genericVars(in g: Group) -> [GenericVar] {
        let sample = Array(g.members.prefix(40))
        let need = max(2, (sample.count * 4 + 4) / 5)
        var out: [GenericVar] = []

        var childNames: [String] = []
        var seenChild = Set<String>()
        for m in sample {
            for c in m.children where c.kind == .element {
                if seenChild.insert(c.name).inserted { childNames.append(c.name) }
            }
        }
        for name in childNames {
            let hits = sample.filter { m in
                m.children.contains { $0.kind == .element && $0.name == name && isNumericLeaf($0) }
            }
            if hits.count >= need { out.append(.valueChild(name)) }
        }

        if sample.filter({ isNumericLeaf($0) }).count >= need {
            out.append(.ownText)
        }

        var attrNames: [String] = []
        var seenAttr = Set<String>()
        for m in sample {
            for a in m.attributes where !labelAttrNames.contains(a.name.lowercased()) {
                if seenAttr.insert(a.name).inserted { attrNames.append(a.name) }
            }
        }
        for name in attrNames {
            let values = sample.compactMap { m -> String? in
                guard let v = m.attributes.first(where: { $0.name == name })?.value else { return nil }
                let t = v.trimmingCharacters(in: .whitespaces)
                return Double(t) != nil ? t : nil
            }
            // A flag (nocreate="1" on every member) or a constant is not
            // a comparison, as the aglu files showed: the values must
            // actually vary, and a pure 0/1 set is a switch, not a quantity.
            let distinct = Set(values)
            guard values.count >= need, distinct.count >= 2,
                  !distinct.isSubset(of: ["0", "1"]) else { continue }
            out.append(.attribute(name))
        }

        // (v0.44.4: the old "# children" structural fallback is gone.
        // A child count is not a value; a chart shows numbers that
        // sit between <> or in an attribute, nothing else.)
        return out
    }

    private static func genericCompute(for node: XMLTreeNode,
                                       preferring preferred: String?) -> TrendSeries? {
        for g in genericGroups(for: node) {
            let vars = genericVars(in: g)
            guard !vars.isEmpty else { continue }
            let chosen: GenericVar?
            if let p = preferred {
                chosen = vars.first(where: { $0.display == p })
            } else {
                chosen = vars.first
            }
            guard let v = chosen else { continue }
            if let s = buildGenericSeries(group: g, variable: v) { return s }
        }
        return nil
    }

    private static func genericValue(of v: GenericVar, on m: XMLTreeNode) -> Double? {
        // "nan" and "inf" parse as Doubles and then poison every scale
        // computed from them, so they never leave this function.
        func finite(_ s: String) -> Double? {
            guard let d = Double(s), d.isFinite else { return nil }
            return d
        }
        switch v {
        case .attribute(let name):
            guard let s = m.attributes.first(where: { $0.name == name })?.value else { return nil }
            return finite(s.trimmingCharacters(in: .whitespaces))
        case .ownText:
            return finite(m.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .valueChild(let name):
            guard let c = m.children.first(where: {
                $0.kind == .element && $0.name == name && isNumericLeaf($0)
            }) else { return nil }
            return finite(c.textValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func genericLabel(_ m: XMLTreeNode, index: Int) -> String {
        for key in ["year", "name", "period", "id", "date", "label", "title", "key"] {
            if let v = m.attributes.first(where: { $0.name.lowercased() == key })?.value,
               !v.isEmpty {
                return String(v.prefix(24))
            }
        }
        // A short text-bearing child often carries the human name
        // (<title> in RSS items, <name> in GPX waypoints).
        for c in m.children where c.kind == .element {
            if ["title", "name", "label"].contains(c.name.lowercased()) {
                let t = c.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return String(t.prefix(24)) }
            }
        }
        if let first = m.attributes.first, !first.value.isEmpty {
            return String(first.value.prefix(24))
        }
        return String(index + 1)
    }

    private static func buildGenericSeries(group g: Group,
                                           variable v: GenericVar) -> TrendSeries? {
        var pts: [(label: String, value: Double)] = []
        for (i, m) in g.members.enumerated() {
            guard let val = genericValue(of: v, on: m) else { continue }
            pts.append((genericLabel(m, index: i), val))
        }
        guard pts.count >= 2 else { return nil }

        let numericLabels = pts.allSatisfy { Double($0.label) != nil }
        if numericLabels { pts.sort { Double($0.label)! < Double($1.label)! } }
        // Many categorical bars are unreadable, flow into a line.
        let kind: TrendKind = (numericLabels || pts.count > 40) ? .line : .bar

        // Very long series (GPX tracks can carry thousands of points):
        // stride-sample so drawing stays instant. Shape survives.
        if pts.count > 1500 {
            let step = Double(pts.count) / 1500.0
            pts = stride(from: 0.0, to: Double(pts.count), by: step).map { pts[Int($0)] }
        }

        let ys = pts.map(\.value)
        let title = "\(v.display) · \(pts.count) \(g.name)\(pts.count == 1 ? "" : "s")"
        return TrendSeries(title: title,
                           xLabels: pts.map(\.label),
                           xPositions: (kind == .line && numericLabels) ? numericPositions(pts.map(\.label)) : nil,
                           values: ys,
                           min: ys.min() ?? 0,
                           max: ys.max() ?? 0,
                           kind: kind)
    }
}
