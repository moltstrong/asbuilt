import Foundation

extension WallLoopBuilder {
    /// Orders walls along the closed loop (counter-clockwise), flipping wall direction where needed.
    /// Returns `nil` when the walls do not form a closed loop.
    public static func orderedLoop(for walls: [WallSegment], tolerance: Double = 0.35) -> [(wall: WallSegment, flipped: Bool)]? {
        var remaining = walls.filter { $0.length > 0.05 }
        guard remaining.count >= 3 else { return nil }
        let startIndex = remaining.indices.max { remaining[$0].length < remaining[$1].length }!
        var chain: [(wall: WallSegment, flipped: Bool)] = [(remaining.remove(at: startIndex), false)]

        func a(_ item: (wall: WallSegment, flipped: Bool)) -> Point2D { item.flipped ? item.wall.end : item.wall.start }
        func b(_ item: (wall: WallSegment, flipped: Bool)) -> Point2D { item.flipped ? item.wall.start : item.wall.end }

        while true {
            let tail = b(chain[chain.count - 1])
            if chain.count >= 3 && tail.distance(to: a(chain[0])) <= tolerance { break }
            var best: (index: Int, flipped: Bool, distance: Double)?
            for (i, wall) in remaining.enumerated() {
                let toStart = tail.distance(to: wall.start)
                let toEnd = tail.distance(to: wall.end)
                let d = min(toStart, toEnd)
                if best == nil || d < best!.distance { best = (i, toEnd < toStart, d) }
            }
            guard let next = best, next.distance <= tolerance else { return nil }
            chain.append((remaining.remove(at: next.index), next.flipped))
        }

        // Make the loop counter-clockwise.
        let points = chain.map { a($0) }
        if Polygon2D.signedArea(points) < 0 {
            chain = chain.reversed().map { ($0.wall, !$0.flipped) }
        }
        // Start at the wall whose start corner is lowest (then left-most): the south-west corner.
        let starts = chain.map { a($0) }
        let first = starts.indices.min { lhs, rhs in
            let p = starts[lhs], q = starts[rhs]
            if abs(p.y - q.y) > 0.05 { return p.y < q.y }
            return p.x < q.x
        }!
        return Array(chain[first...] + chain[..<first])
    }
}

extension FloorPlan {
    /// A copy with walls in loop order (counter-clockwise from the south-west corner) and every
    /// wall pointing along the loop, so W1, W2... are numbered predictably around the room.
    /// Opening offsets are remapped when their host wall is flipped. Walls that are not part
    /// of the loop (partitions, partial walls) keep their geometry and follow at the end.
    public func normalized(tolerance: Double = 0.35) -> FloorPlan {
        guard let loop = WallLoopBuilder.orderedLoop(for: walls, tolerance: tolerance) else { return self }
        var result = self
        var flippedIDs = Set<UUID>()
        var ordered: [WallSegment] = []
        for item in loop {
            var wall = item.wall
            if item.flipped {
                swap(&wall.start, &wall.end)
                flippedIDs.insert(wall.id)
            }
            ordered.append(wall)
        }
        let used = Set(ordered.map(\.id))
        ordered.append(contentsOf: walls.filter { !used.contains($0.id) })
        result.walls = ordered
        result.openings = openings.map { opening in
            guard flippedIDs.contains(opening.wallID), let wall = wall(withID: opening.wallID) else { return opening }
            var o = opening
            o.offset = wall.length - opening.offset
            return o
        }
        return result
    }
}
