import Foundation

/// Chains wall segments end-to-end into a closed room outline.
public enum WallLoopBuilder {
    /// Returns the corner points of a closed loop of walls, or `nil` if the walls do not close.
    ///
    /// Walls may be in any order and either direction. Starting from the longest wall the builder
    /// repeatedly attaches the wall whose nearest endpoint is within `tolerance` of the chain's tail.
    /// Walls that never join the loop (e.g. an interior partition) are ignored. Corners are the
    /// intersection of consecutive wall lines, which absorbs small overshoots and gaps from scanning.
    public static func loop(for walls: [WallSegment], tolerance: Double = 0.35) -> [Point2D]? {
        var remaining = walls.filter { $0.length > 0.05 }
        guard remaining.count >= 3 else { return nil }

        let startIndex = remaining.indices.max { remaining[$0].length < remaining[$1].length }!
        let first = remaining.remove(at: startIndex)
        var chain: [(a: Point2D, b: Point2D)] = [(first.start, first.end)]

        while true {
            let tail = chain[chain.count - 1].b
            let head = chain[0].a
            if chain.count >= 3 && tail.distance(to: head) <= tolerance { break }

            var best: (index: Int, reversed: Bool, distance: Double)?
            for (i, wall) in remaining.enumerated() {
                let toStart = tail.distance(to: wall.start)
                let toEnd = tail.distance(to: wall.end)
                let d = min(toStart, toEnd)
                if best == nil || d < best!.distance {
                    best = (i, toEnd < toStart, d)
                }
            }
            guard let next = best, next.distance <= tolerance else { return nil }
            let wall = remaining.remove(at: next.index)
            chain.append(next.reversed ? (wall.end, wall.start) : (wall.start, wall.end))
        }

        let n = chain.count
        var corners: [Point2D] = []
        for i in 0..<n {
            let previous = chain[(i - 1 + n) % n]
            let current = chain[i]
            if let p = intersection(previous.a, previous.b, current.a, current.b) {
                corners.append(p)
            } else {
                corners.append((previous.b + current.a) * 0.5)
            }
        }
        return corners
    }

    /// Intersection of line p1-p2 with line p3-p4 near the joint (p2/p3). `nil` when nearly parallel.
    static func intersection(_ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D) -> Point2D? {
        let d1 = p2 - p1
        let d2 = p4 - p3
        let denom = d1.cross(d2)
        let scale = d1.length * d2.length
        guard scale > 0, abs(denom) / scale > 0.05 else { return nil }
        let t = (p3 - p1).cross(d2) / denom
        let point = p1 + d1 * t
        guard point.distance(to: p2) < 1.0 else { return nil }
        return point
    }
}

/// A rectangular solid piece of a wall in elevation (used for 3D extrusion and area checks).
public struct WallPiece: Hashable, Sendable {
    /// Along-wall start/end offsets from the wall start (meters).
    public var start: Double
    public var end: Double
    /// Bottom/top heights above the floor (meters).
    public var bottom: Double
    public var top: Double

    public var area: Double { (end - start) * (top - bottom) }
}

public enum WallElevation {
    /// The along-wall interval an opening occupies, clamped to the wall.
    public static func interval(of opening: Opening, wallLength: Double) -> ClosedRange<Double>? {
        let a = max(0, opening.offset - opening.width / 2)
        let b = min(wallLength, opening.offset + opening.width / 2)
        return b > a ? a...b : nil
    }

    /// `0...length` minus the union of `cuts`.
    public static func solidSpans(length: Double, cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard length > 0 else { return [] }
        let sorted = cuts.map { max(0, $0.lowerBound)...min(length, $0.upperBound) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var spans: [ClosedRange<Double>] = []
        var cursor = 0.0
        for cut in sorted {
            if cut.lowerBound - cursor > 1e-6 { spans.append(cursor...cut.lowerBound) }
            cursor = max(cursor, cut.upperBound)
        }
        if length - cursor > 1e-6 { spans.append(cursor...length) }
        return spans
    }

    /// Vertical span an opening removes from the wall, clamped to the wall height.
    public static func verticalCut(of opening: Opening, wallHeight: Double) -> ClosedRange<Double>? {
        let bottom = max(0, opening.sillHeight)
        let top = min(wallHeight, opening.sillHeight + opening.height)
        return top > bottom ? bottom...top : nil
    }

    /// Solid rectangles of the wall after removing every opening.
    public static func pieces(for wall: WallSegment, openings: [Opening]) -> [WallPiece] {
        let length = wall.length
        guard length > 0, wall.height > 0 else { return [] }
        var edges: Set<Double> = [0, length]
        for opening in openings {
            if let iv = interval(of: opening, wallLength: length) {
                edges.insert(iv.lowerBound)
                edges.insert(iv.upperBound)
            }
        }
        let xs = edges.sorted()
        var pieces: [WallPiece] = []
        for i in 0..<(xs.count - 1) {
            let x0 = xs[i]
            let x1 = xs[i + 1]
            guard x1 - x0 > 1e-6 else { continue }
            let mid = (x0 + x1) / 2
            let cuts = openings.compactMap { opening -> ClosedRange<Double>? in
                guard let iv = interval(of: opening, wallLength: length), iv.contains(mid) else { return nil }
                return verticalCut(of: opening, wallHeight: wall.height)
            }
            for v in solidSpans(length: wall.height, cuts: cuts) {
                pieces.append(WallPiece(start: x0, end: x1, bottom: v.lowerBound, top: v.upperBound))
            }
        }
        return pieces
    }
}
