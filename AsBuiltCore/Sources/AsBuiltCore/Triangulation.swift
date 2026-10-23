import Foundation

/// Ear-clipping triangulation for simple polygons (convex or concave, e.g. L-shaped rooms).
public enum Triangulator {
    /// Triangulates a simple polygon (open point list, either winding).
    ///
    /// Returns index triples into `polygon`, each wound counter-clockwise in plan space.
    /// Duplicate and collinear vertices are skipped. A polygon with n distinct, non-collinear
    /// corners yields n - 2 triangles whose areas sum to the polygon's area.
    public static func triangulate(_ polygon: [Point2D]) -> [[Int]] {
        guard polygon.count >= 3 else { return [] }
        let scale = max(Rect2D.enclosing(polygon).map { max($0.width, $0.height) } ?? 1, 1e-9)
        let eps = 1e-12 * scale * scale

        var ordered = Array(polygon.indices)
        if Polygon2D.signedArea(polygon) < 0 { ordered.reverse() }

        // Drop consecutive duplicates (including last == first).
        var indices: [Int] = []
        for i in ordered {
            if let last = indices.last, polygon[last].distance(to: polygon[i]) <= 1e-9 * scale { continue }
            indices.append(i)
        }
        while indices.count > 1, polygon[indices[0]].distance(to: polygon[indices[indices.count - 1]]) <= 1e-9 * scale {
            indices.removeLast()
        }

        func cross(_ a: Int, _ b: Int, _ c: Int) -> Double {
            (polygon[b] - polygon[a]).cross(polygon[c] - polygon[a])
        }

        var triangles: [[Int]] = []
        while indices.count > 3 {
            let n = indices.count
            var clipped = false
            for k in 0..<n {
                let a = indices[(k - 1 + n) % n]
                let b = indices[k]
                let c = indices[(k + 1) % n]
                let turn = cross(a, b, c)
                if abs(turn) <= eps {
                    // Collinear vertex (or a zero-width spike): it contributes no area, drop it.
                    indices.remove(at: k)
                    clipped = true
                    break
                }
                guard turn > 0 else { continue } // reflex corner, not an ear
                let blocked = indices.contains { other in
                    other != a && other != b && other != c &&
                        pointInTriangle(polygon[other], polygon[a], polygon[b], polygon[c], eps: eps)
                }
                if blocked { continue }
                triangles.append([a, b, c])
                indices.remove(at: k)
                clipped = true
                break
            }
            if !clipped {
                // Self-intersecting or numerically degenerate input: fan the remainder instead of looping.
                for k in 1..<(indices.count - 1) {
                    let t = [indices[0], indices[k], indices[k + 1]]
                    let turn = cross(t[0], t[1], t[2])
                    if abs(turn) > eps { triangles.append(turn > 0 ? t : [t[0], t[2], t[1]]) }
                }
                return triangles
            }
        }
        if indices.count == 3, cross(indices[0], indices[1], indices[2]) > eps {
            triangles.append(indices)
        }
        return triangles
    }

    /// True when `p` is inside or on the boundary of the counter-clockwise triangle (a, b, c).
    static func pointInTriangle(_ p: Point2D, _ a: Point2D, _ b: Point2D, _ c: Point2D, eps: Double) -> Bool {
        (b - a).cross(p - a) >= -eps && (c - b).cross(p - b) >= -eps && (a - c).cross(p - c) >= -eps
    }
}
