// LevelIndex.swift
//
// Which elements the minimap's magnet lane latches onto.
//
// The lane used to be built from the selected element's immediate
// family: its parent, its siblings and its children. The furthest it
// could ever reach was therefore the parent's span. On a region that
// looked right, because the 32 regions between them span the whole
// file. One level down the span collapsed to a single region, so every
// hover snapped straight back into the region you were already in.
//
// A "level" here is a depth plus a tag name, so region at depth 2 and
// supplysector at depth 3 are different levels, and so are two tags
// sitting at the same depth under the same parent. The magnets for a
// selection are every element in the FILE at that level: all regions
// when you are on a region, all supplysectors when you are on a
// supplysector.
//
// Levels are gathered on demand rather than for the whole tree up
// front. A 655 MB file carries millions of nodes, and walking all of
// them at parse time would add a pause to opening it; a single level's
// walk never descends past that level's depth, which on a deep GCAM
// tree visits a small fraction of the nodes. Results are cached for the
// life of one parse, so moving around inside a level costs nothing.

import Foundation

struct XMLLevel: Hashable {
    let depth: Int      // element ancestors above this node; root element is 0
    let name: String
}

final class LevelIndex {

    /// A level with more elements than this is too dense to aim at, and
    /// too dense to draw as separate ticks, so the lane climbs to the
    /// parent level instead.
    static let crowdedLevel = 4_000

    /// How many times the lane may step down looking for a level with
    /// something to aim at. Only matters at the top of the document,
    /// where the root element is alone at its level.
    private static let maxDescend = 6

    /// How many nodes one level's walk may visit before the level is
    /// written off as too expensive to enumerate.
    ///
    /// A level's walk never descends past its own depth, and it stops as
    /// soon as it has found one more than `crowdedLevel`, so in practice
    /// it is cheap: on a 686 MB GCAM file every deep level is crowded and
    /// bails within a fraction of the tree. The pathological shape is a
    /// level that is deep AND has just under 4000 elements, where the
    /// walk would have to visit nearly all ~9 million nodes at roughly
    /// 70 ns each, i.e. most of a second, and this runs on the main
    /// thread from the caret timer. The budget makes that impossible; a
    /// level that hits it is treated exactly like a crowded one, so the
    /// lane climbs to its parent.
    private static let maxWalkVisits = 300_000

    private enum Resolved {
        case lines([Int])
        case tooMany        // crowded, or too expensive to enumerate
    }

    private weak var root: XMLTreeNode?
    private var cache: [XMLLevel: Resolved] = [:]

    init(root: XMLTreeNode?) { self.root = root }

    /// The level an element sits at, or nil for anything that is not an
    /// element.
    static func level(of node: XMLTreeNode) -> XMLLevel? {
        guard node.kind == .element else { return nil }
        var depth = 0
        var cur = node.parent
        while let p = cur {
            if p.kind == .element { depth += 1 }
            cur = p.parent
        }
        return XMLLevel(depth: depth, name: node.name)
    }

    private static func elementParent(of node: XMLTreeNode) -> XMLTreeNode? {
        var cur = node.parent
        while let p = cur {
            if p.kind == .element { return p }
            cur = p.parent
        }
        return nil
    }

    /// Start lines of every element at `level`, in document order, or an
    /// empty array when the level is too dense or too costly to walk.
    func startLines(for level: XMLLevel) -> [Int] {
        if case .lines(let l) = resolve(level) { return l }
        return []
    }

    func isCrowded(_ level: XMLLevel) -> Bool {
        if case .tooMany = resolve(level) { return true }
        return false
    }

    private func resolve(_ level: XMLLevel) -> Resolved {
        if let hit = cache[level] { return hit }
        guard let root, level.depth >= 0 else { return .lines([]) }
        var out: [Int] = []
        var visits = 0
        var answer: Resolved? = nil
        // The document node is not an element, so its own children are
        // the depth-0 elements.
        var stack: [(node: XMLTreeNode, depth: Int)] = [(root, root.kind == .element ? 0 : -1)]
        walk: while let (node, depth) = stack.popLast() {
            visits += 1
            if visits > Self.maxWalkVisits { answer = .tooMany; break walk }
            if depth == level.depth {
                if node.kind == .element, node.name == level.name {
                    out.append(node.startLine)
                    // One past the cap is enough to know the lane should
                    // climb; the rest would be work nobody reads.
                    if out.count > Self.crowdedLevel { answer = .tooMany; break walk }
                }
                continue                       // never descend past the level
            }
            for c in node.children where c.kind == .element {
                stack.append((c, depth + 1))
            }
        }
        if answer == nil {
            out.sort()                         // the lane binary-searches these
            answer = .lines(out)
        }
        cache[level] = answer
        return answer!
    }

    /// The magnets for a selection, and the level they came from.
    ///
    /// Climbs to the parent level while a level is too crowded, and
    /// steps down into its own children when its level has nothing to
    /// aim at, which is the case for the root element.
    func magnets(for node: XMLTreeNode) -> (level: XMLLevel?, lines: [Int]) {
        var current: XMLTreeNode? = node.kind == .element
            ? node
            : node.children.first(where: { $0.kind == .element })
        var descended = 0

        while let n = current, let lvl = Self.level(of: n) {
            guard case .lines(let lines) = resolve(lvl) else {
                // Too dense or too costly to enumerate: aim one level up.
                guard let up = Self.elementParent(of: n) else { return (nil, []) }
                current = up
                continue
            }
            if lines.count >= 2 { return (lvl, lines) }

            // One element at this level, so there is nothing to hop
            // between. Step into its children rather than leave the
            // lane empty.
            guard descended < Self.maxDescend,
                  let child = n.children.first(where: { $0.kind == .element }) else {
                return (lvl, lines)
            }
            descended += 1
            current = child
        }
        return (nil, [])
    }
}
