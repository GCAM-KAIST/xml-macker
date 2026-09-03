import Foundation

// Chart Builder (v1.0.5). It covers the whole file, with every
// attribute reachable from the lists, and still follows the shape of
// the tree: the builder is a PATH OF DROPDOWNS that mirrors it.
//
//   region ▾ › supplysector ▾ › subsector ▾ › stub-technology ▾ › period ▾ › Value ▾
//
// A level is a place in the tree where CONTAINER elements carry a key
// attribute (name=, year=, …). Each dropdown lists every such sibling
// under the parents chosen above it, so any part of the file is
// reachable without the tree. "across all N <tag>s" turns a level into
// the X axis. Plain values (share-weight, efficiency) are never levels;
// they are what the Value dropdown offers under the chosen path.
// Every list is one walk down the chosen path: nothing is scanned
// file-wide, so it stays instant on the 655 MB file.
final class ChartPathBuilder {
    struct Option {
        let tag: String
        let key: String
        let node: XMLTreeNode
        var label: String { "\(tag) · \(key)" }
    }

    struct Level {
        let options: [Option]        // keyed container children of the parent
        var choice: Int              // pinned, or representative member of the axis
        var isAxis: Bool
        var current: Option { options[choice] }
        var tag: String { current.tag }
        /// The axis population: every option sharing the chosen tag.
        var members: [Option] { options.filter { $0.tag == current.tag } }
        var repeats: Bool { members.count >= 2 }
        var mixedTags: Bool { Set(options.map(\.tag)).count > 1 }
    }

    static let keyAttrs = ["name", "year", "type", "id", "key"]
    static let scanCap = 200_000

    let root: XMLTreeNode
    private(set) var levels: [Level] = []
    private(set) var valueNames: [String] = []
    private(set) var valueScanTruncated = false
    /// Pinned choices of the last compute, for the pop-out subtitle.
    private(set) var lastPathSummary = ""
    var valueName: String?

    init(root: XMLTreeNode) { self.root = root }

    // MARK: Structure

    static func key(of n: XMLTreeNode) -> String? {
        for k in keyAttrs {
            if let v = n.attributes.first(where: { $0.name == k })?.value, !v.isEmpty { return v }
        }
        return nil
    }

    static func isContainer(_ n: XMLTreeNode) -> Bool {
        n.children.contains { $0.kind == .element }
    }

    /// Keyed CONTAINER children, in document order. A keyed leaf such as
    /// <share-weight year="1975"> is a value, not a place to go.
    static func levelOptions(under node: XMLTreeNode) -> [Option] {
        node.children.compactMap { c in
            guard c.kind == .element, isContainer(c), let k = key(of: c) else { return nil }
            return Option(tag: c.name, key: k, node: c)
        }
    }

    /// <scenario> and <world> carry no key: fall through single keyless
    /// containers until keyed containers appear.
    static func passThrough(_ node: XMLTreeNode) -> XMLTreeNode {
        var cur = node
        var hops = 0
        while hops < 8, levelOptions(under: cur).isEmpty {
            let containers = cur.children.filter { $0.kind == .element && isContainer($0) }
            guard containers.count == 1 else { break }
            cur = containers[0]
            hops += 1
        }
        return cur
    }

    // MARK: Building the path

    /// Build the whole path. `seed` is the tree selection: its ancestors
    /// pin each level, and the axis defaults to the first repeating
    /// level below the selection (a technology → its periods), else the
    /// selection's own level when it repeats, else the last repeating one.
    func rebuild(seed: XMLTreeNode?) {
        var onPath = Set<ObjectIdentifier>()
        var cur: XMLTreeNode? = seed
        while let n = cur, n.kind == .element { onPath.insert(ObjectIdentifier(n)); cur = n.parent }
        levels = Self.buildLevels(from: root, keeping: [], onPath: onPath)
        let deepestSeeded = levels.lastIndex { onPath.contains(ObjectIdentifier($0.current.node)) } ?? -1
        let axis = levels.indices.first { $0 > deepestSeeded && levels[$0].repeats }
            ?? (deepestSeeded >= 0 && levels[deepestSeeded].repeats ? deepestSeeded : nil)
            ?? levels.indices.last { levels[$0].repeats }
        setAxis(preferring: axis)
        refreshValues()
    }

    /// Walk down from `start`, one level per keyed-container generation.
    /// Earlier choices at the same depth are kept when the same tag+key
    /// exists; nodes on the seed path win.
    private static func buildLevels(from start: XMLTreeNode, keeping old: [Level],
                                    onPath: Set<ObjectIdentifier>) -> [Level] {
        var out: [Level] = []
        var cursor = start
        var hops = 0
        while hops < 40 {
            hops += 1
            let options = levelOptions(under: passThrough(cursor))
            guard !options.isEmpty else { break }
            let previous = old.indices.contains(out.count) ? old[out.count] : nil
            let choice = options.firstIndex { onPath.contains(ObjectIdentifier($0.node)) }
                ?? options.firstIndex { $0.tag == previous?.tag && $0.key == previous?.current.key }
                ?? 0
            out.append(Level(options: options, choice: choice, isAxis: previous?.isAxis ?? false))
            cursor = options[choice].node
        }
        return out
    }

    /// Pin one member at a level; everything below is rebuilt from it.
    /// Pinning the axis level moves the axis to the next repeating level
    /// below (else the nearest one above), never back to the same level.
    func setChoice(level i: Int, option index: Int) {
        guard levels.indices.contains(i), levels[i].options.indices.contains(index) else { return }
        let wasAxis = levels[i].isAxis
        levels[i].choice = index
        levels[i].isAxis = false
        let below = Self.buildLevels(from: levels[i].current.node,
                                     keeping: Array(levels.dropFirst(i + 1)), onPath: [])
        levels = Array(levels.prefix(i + 1)) + below
        if wasAxis || !levels.contains(where: \.isAxis) {
            setAxis(preferring: levels.indices.first { $0 > i && levels[$0].repeats }
                    ?? levels.indices.last { $0 < i && levels[$0].repeats })
        }
        refreshValues()
    }

    /// Make a level the X axis (one axis at a time).
    func setAxis(level i: Int) {
        guard levels.indices.contains(i) else { return }
        setAxis(preferring: i)
        refreshValues()
    }

    private func setAxis(preferring i: Int?) {
        for j in levels.indices { levels[j].isAxis = (j == i) }
    }

    var axisIndex: Int? { levels.firstIndex(where: \.isAxis) }

    /// The node whose subtree the Value list and the chart come from:
    /// the representative member at the axis, else the deepest pin.
    var baseNode: XMLTreeNode? {
        (axisIndex.map { levels[$0] } ?? levels.last)?.current.node
    }

    /// Deepest pinned node, for "Show in Tree".
    var deepestPinnedNode: XMLTreeNode? { levels.last?.current.node }

    // MARK: Values

    /// Numeric leaf tags under the base node, most frequent first.
    func refreshValues() {
        valueNames = []
        valueScanTruncated = false
        guard let base = baseNode else { valueName = nil; return }
        var count: [String: Int] = [:]
        var visited = 0
        var stack: [XMLTreeNode] = [base]
        while let n = stack.popLast() {
            visited += 1
            if visited > Self.scanCap { valueScanTruncated = true; break }
            let kids = n.children.filter { $0.kind == .element }
            if kids.isEmpty {
                if n !== base, Double(n.textValue.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    count[n.name, default: 0] += 1
                }
                continue
            }
            for c in kids.reversed() { stack.append(c) }
        }
        valueNames = count.keys.sorted { (count[$0]!, $1) > (count[$1]!, $0) }
        if let v = valueName, !valueNames.contains(v) { valueName = nil }
        if valueName == nil { valueName = valueNames.first }
    }

    // MARK: Compute

    func compute() -> TrendSeries? {
        guard let value = valueName, let a = axisIndex else { return nil }
        let axisLevel = levels[a]
        // Pins below the axis constrain the walk inside each member.
        var filters: [String: String] = [:]
        for lvl in levels[(a + 1)...] { filters[lvl.tag] = lvl.current.key }
        var points: [(label: String, value: Double)] = []
        for m in axisLevel.members {
            if let v = firstValue(named: value, under: m.node, filters: filters) {
                points.append((m.key, v))
            }
        }
        guard points.count >= 2 else { return nil }
        let numeric = points.allSatisfy { Double($0.label) != nil }
        if numeric { points.sort { Double($0.label)! < Double($1.label)! } }
        let labels = points.map(\.label)
        let ys = points.map(\.value)
        var positions: [Double]? = nil
        if numeric {
            let nums = labels.compactMap { Double($0) }
            if nums.count == labels.count, zip(nums, nums.dropFirst()).allSatisfy({ $0 < $1 }) { positions = nums }
        }
        let title = "\(value) across \(axisLevel.tag)"
        var parts: [String] = []
        for lvl in levels[..<a] { parts.append("\(lvl.tag) \(lvl.current.key)") }
        for lvl in levels[(a + 1)...] { parts.append("\(lvl.tag) \(lvl.current.key)") }
        lastPathSummary = parts.joined(separator: " › ")
        return TrendSeries(title: title, xLabels: labels, xPositions: positions,
                           values: ys, min: ys.min() ?? 0, max: ys.max() ?? 0,
                           kind: numeric ? .line : .bar)
    }

    /// First numeric leaf named `name` under `node`, honoring pins for
    /// the tags that appear on the way down. A tag absent from a branch
    /// does not block it, so a subsector-level share-weight is still
    /// found when technology and period pins exist.
    private func firstValue(named name: String, under node: XMLTreeNode,
                            filters: [String: String]) -> Double? {
        var visited = 0
        var stack: [XMLTreeNode] = [node]
        while let n = stack.popLast() {
            visited += 1
            if visited > Self.scanCap { return nil }
            let kids = n.children.filter { $0.kind == .element }
            if kids.isEmpty {
                if n.name == name,
                   let v = Double(n.textValue.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite {
                    return v
                }
                continue
            }
            if n !== node, let want = filters[n.name], let k = Self.key(of: n), k != want {
                continue   // pruned: a pinned level with the wrong member
            }
            for c in kids.reversed() { stack.append(c) }
        }
        return nil
    }
}
