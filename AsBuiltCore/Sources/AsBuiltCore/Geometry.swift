import Foundation

/// A point or vector in plan space.
///
/// Units are meters. +x points right (east) and +y points up the page (north),
/// i.e. a top-down view looking along world -Y. RoomPlan world coordinates map
/// to plan coordinates as `(x, y) = (world.x, -world.z)`.
public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(0, 0)

    public static func + (lhs: Point2D, rhs: Point2D) -> Point2D { Point2D(lhs.x + rhs.x, lhs.y + rhs.y) }
    public static func - (lhs: Point2D, rhs: Point2D) -> Point2D { Point2D(lhs.x - rhs.x, lhs.y - rhs.y) }
    public static func * (lhs: Point2D, rhs: Double) -> Point2D { Point2D(lhs.x * rhs, lhs.y * rhs) }
    public static prefix func - (value: Point2D) -> Point2D { Point2D(-value.x, -value.y) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public var normalized: Point2D {
        let l = length
        return l > 0 ? Point2D(x / l, y / l) : .zero
    }

    /// The vector rotated 90 degrees counter-clockwise.
    public var leftNormal: Point2D { Point2D(-y, x) }

    public var angleRadians: Double { atan2(y, x) }
    public var angleDegrees: Double { angleRadians * 180 / .pi }

    public func dot(_ other: Point2D) -> Double { x * other.x + y * other.y }
    public func cross(_ other: Point2D) -> Double { x * other.y - y * other.x }
    public func distance(to other: Point2D) -> Double { (self - other).length }

    public func rotated(by radians: Double) -> Point2D {
        let c = cos(radians)
        let s = sin(radians)
        return Point2D(x * c - y * s, x * s + y * c)
    }
}

/// Axis-aligned bounding rectangle in plan space (meters).
public struct Rect2D: Codable, Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static func enclosing(_ points: [Point2D]) -> Rect2D? {
        guard let first = points.first else { return nil }
        var rect = Rect2D(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() {
            rect.minX = min(rect.minX, p.x)
            rect.minY = min(rect.minY, p.y)
            rect.maxX = max(rect.maxX, p.x)
            rect.maxY = max(rect.maxY, p.y)
        }
        return rect
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Point2D { Point2D((minX + maxX) / 2, (minY + maxY) / 2) }

    public func union(_ other: Rect2D) -> Rect2D {
        Rect2D(minX: min(minX, other.minX), minY: min(minY, other.minY),
               maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    public func contains(_ p: Point2D) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func intersects(_ other: Rect2D) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    public func expanded(by d: Double) -> Rect2D {
        Rect2D(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d)
    }
}

/// Polygon helpers. Polygons are open point lists (the last point connects to the first).
public enum Polygon2D {
    /// Shoelace signed area: positive for counter-clockwise polygons.
    public static func signedArea(_ points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    public static func area(_ points: [Point2D]) -> Double { abs(signedArea(points)) }

    public static func perimeter(_ points: [Point2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<points.count {
            total += points[i].distance(to: points[(i + 1) % points.count])
        }
        return total
    }

    public static func centroid(_ points: [Point2D]) -> Point2D {
        guard !points.isEmpty else { return .zero }
        let a = signedArea(points)
        if abs(a) < 1e-12 {
            let sum = points.reduce(Point2D.zero, +)
            return sum * (1 / Double(points.count))
        }
        var cx = 0.0
        var cy = 0.0
        for i in 0..<points.count {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            let f = p.x * q.y - q.x * p.y
            cx += (p.x + q.x) * f
            cy += (p.y + q.y) * f
        }
        return Point2D(cx / (6 * a), cy / (6 * a))
    }

    /// Andrew's monotone chain. Returns a counter-clockwise hull.
    public static func convexHull(_ points: [Point2D]) -> [Point2D] {
        let pts = Array(Set(points)).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func turn(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double { (a - o).cross(b - o) }
        var lower: [Point2D] = []
        for p in pts {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Point2D] = []
        for p in pts.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Even-odd ray casting point-in-polygon test.
    public static func contains(_ point: Point2D, in polygon: [Point2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let xCross = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
