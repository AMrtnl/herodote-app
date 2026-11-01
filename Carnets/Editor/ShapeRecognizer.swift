import Foundation
import CoreGraphics
import PencilKit

// MARK: - ShapeRecognizer
// Turns a hand-drawn stroke into a clean line, ellipse/circle, triangle, rectangle
// or polygon, keeping the stroke's ink. Used for "draw and hold" and the Formes toggle.

nonisolated enum ShapeRecognizer {

    nonisolated enum Shape {
        case line(CGPoint, CGPoint)
        case polygon([CGPoint])
        case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat)
    }

    /// Returns a replacement stroke, or `nil` when the stroke doesn't look like a shape.
    static func snap(_ stroke: PKStroke) -> PKStroke? {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(3)))
        guard samples.count >= 4 else { return nil }
        let points = samples.map { $0.location.applying(stroke.transform) }
        guard let shape = recognize(points) else { return nil }
        let template = representativePoint(samples, transform: stroke.transform)
        let controlPoints = build(shape, template: template)
        guard controlPoints.count >= 2 else { return nil }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
    }

    // MARK: Recognition

    static func recognize(_ p: [CGPoint]) -> Shape? {
        guard let first = p.first, let last = p.last else { return nil }
        let box = boundingBox(p)
        let diagonal = hypot(box.width, box.height)
        guard diagonal >= 14 else { return nil }

        let length = pathLength(p)
        let chord = distance(first, last)

        // Straight line
        if chord > 0.86 * length {
            let deviation = p.map { perpendicularDistance($0, first, last) }.max() ?? 0
            if deviation < max(4, chord * 0.06) {
                return .line(first, snappedEnd(from: first, to: last))
            }
        }

        // Everything else must be (nearly) closed.
        guard chord < max(0.22 * length, 18) else { return nil }

        let epsilon = max(5, diagonal * 0.06)
        var vertices = rdp(p + [first], epsilon: epsilon)
        if vertices.count > 1, let a = vertices.first, let b = vertices.last, distance(a, b) < epsilon * 1.5 {
            vertices.removeLast()
        }
        vertices = removeCollinear(vertices, minTurn: 22)
        let polygonError = vertices.count >= 3 ? meanDistance(p, toPolygon: vertices) / diagonal : .infinity

        let ellipse = fitEllipse(p)
        let ellipseError = ellipse.map { ellipseFitError(p, $0) } ?? .infinity

        if (3...6).contains(vertices.count), polygonError < 0.03, polygonError <= ellipseError * 1.15 {
            if vertices.count == 4, let rect = rectangle(from: vertices) { return .polygon(rect) }
            return .polygon(vertices)
        }
        if let ellipse, ellipseError < 0.075 {
            return ellipse
        }
        return nil
    }

    /// Snaps nearly horizontal / vertical / 45° lines.
    private static func snappedEnd(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let nearest = (angle / step).rounded() * step
        guard abs(angle - nearest) < 4 * .pi / 180 else { return b }
        return CGPoint(x: a.x + cos(nearest) * length, y: a.y + sin(nearest) * length)
    }

    private static func rectangle(from v: [CGPoint]) -> [CGPoint]? {
        for i in 0..<4 {
            let prev = v[(i + 3) % 4], cur = v[i], next = v[(i + 1) % 4]
            let a1 = atan2(prev.y - cur.y, prev.x - cur.x)
            let a2 = atan2(next.y - cur.y, next.x - cur.x)
            var turn = abs(a1 - a2) * 180 / .pi
            if turn > 180 { turn = 360 - turn }
            if abs(turn - 90) > 18 { return nil }
        }
        // Axis-aligned when the first edge is within 10° of horizontal or vertical.
        let edge = atan2(v[1].y - v[0].y, v[1].x - v[0].x) * 180 / .pi
        let offAxis = abs(edge.truncatingRemainder(dividingBy: 90))
        if offAxis < 10 || offAxis > 80 {
            let box = boundingBox(v)
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }
        // Tilted: square the corners around the centre using the two mean edge directions.
        let c = CGPoint(x: v.map(\.x).reduce(0, +) / 4, y: v.map(\.y).reduce(0, +) / 4)
        let u = normalize(CGPoint(x: (v[1].x - v[0].x) + (v[2].x - v[3].x), y: (v[1].y - v[0].y) + (v[2].y - v[3].y)))
        let n = CGPoint(x: -u.y, y: u.x)
        let halfW = (distance(v[0], v[1]) + distance(v[3], v[2])) / 4
        let halfH = (distance(v[1], v[2]) + distance(v[0], v[3])) / 4
        let sign: CGFloat = dot(CGPoint(x: v[3].x - v[0].x, y: v[3].y - v[0].y), n) >= 0 ? 1 : -1
        func corner(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x + u.x * a + n.x * b * sign, y: c.y + u.y * a + n.y * b * sign)
        }
        return [corner(-halfW, -halfH), corner(halfW, -halfH), corner(halfW, halfH), corner(-halfW, halfH)]
    }

    // MARK: Ellipse fitting (principal axes)

    private static func fitEllipse(_ p: [CGPoint]) -> Shape? {
        let n = CGFloat(p.count)
        let cx = p.map(\.x).reduce(0, +) / n
        let cy = p.map(\.y).reduce(0, +) / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for q in p {
            let dx = q.x - cx, dy = q.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let cosA = cos(-angle), sinA = sin(-angle)
        var minU = CGFloat.infinity, maxU = -CGFloat.infinity, minV = CGFloat.infinity, maxV = -CGFloat.infinity
        for q in p {
            let dx = q.x - cx, dy = q.y - cy
            let u = dx * cosA - dy * sinA
            let v = dx * sinA + dy * cosA
            minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        var rx = (maxU - minU) / 2, ry = (maxV - minV) / 2
        guard rx > 4, ry > 4 else { return nil }
        let center = CGPoint(x: cx + ((minU + maxU) / 2) * cos(angle) - ((minV + maxV) / 2) * sin(angle),
                             y: cy + ((minU + maxU) / 2) * sin(angle) + ((minV + maxV) / 2) * cos(angle))
        if abs(rx - ry) / max(rx, ry) < 0.12 {
            let r = (rx + ry) / 2
            rx = r; ry = r
            return .ellipse(center: center, rx: r, ry: r, angle: 0)
        }
        // Snap nearly axis-aligned ellipses.
        var a = angle
        let degrees = abs(angle * 180 / .pi).truncatingRemainder(dividingBy: 90)
        if degrees < 6 || degrees > 84 { a = (angle / (.pi / 2)).rounded() * (.pi / 2) }
        return .ellipse(center: center, rx: rx, ry: ry, angle: a)
    }

    private static func ellipseFitError(_ p: [CGPoint], _ shape: Shape) -> CGFloat {
        guard case let .ellipse(c, rx, ry, angle) = shape else { return .infinity }
        let cosA = cos(-angle), sinA = sin(-angle)
        var total: CGFloat = 0
        for q in p {
            let dx = q.x - c.x, dy = q.y - c.y
            let u = (dx * cosA - dy * sinA) / rx
            let v = (dx * sinA + dy * cosA) / ry
            total += abs(sqrt(u * u + v * v) - 1)
        }
        return total / CGFloat(p.count)
    }

    // MARK: Building replacement control points

    private static func build(_ shape: Shape, template: PKStrokePoint) -> [PKStrokePoint] {
        var locations: [(CGPoint, Bool)] = []   // (point, isCorner)
        func edge(_ a: CGPoint, _ b: CGPoint, includeEnd: Bool) {
            let steps = max(1, Int(distance(a, b) / 6))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                locations.append((CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), i == 0))
            }
            if includeEnd { locations.append((b, true)) }
        }
        switch shape {
        case let .line(a, b):
            edge(a, b, includeEnd: true)
        case let .polygon(vertices):
            for i in vertices.indices {
                edge(vertices[i], vertices[(i + 1) % vertices.count], includeEnd: i == vertices.count - 1)
            }
        case let .ellipse(c, rx, ry, angle):
            let perimeter = 2 * CGFloat.pi * sqrt((rx * rx + ry * ry) / 2)
            let count = max(40, Int(perimeter / 5))
            let cosA = cos(angle), sinA = sin(angle)
            for i in 0...(count + 2) {
                let t = CGFloat(i) / CGFloat(count) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                locations.append((CGPoint(x: c.x + x * cosA - y * sinA, y: c.y + x * sinA + y * cosA), false))
            }
        }

        var result: [PKStrokePoint] = []
        var time: TimeInterval = 0
        for (location, isCorner) in locations {
            let point = PKStrokePoint(location: location, timeOffset: time, size: template.size,
                                      opacity: template.opacity, force: template.force,
                                      azimuth: template.azimuth, altitude: template.altitude)
            result.append(point)
            // Repeating a B-spline control point pulls the curve through it: sharp corners.
            if isCorner { result.append(point); result.append(point) }
            time += 0.004
        }
        return result
    }

    /// Median attributes of the original stroke so the clean shape keeps its look.
    private static func representativePoint(_ samples: [PKStrokePoint], transform: CGAffineTransform) -> PKStrokePoint {
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        let s = scale > 0 ? scale : 1
        let size = CGSize(width: median(samples.map(\.size.width)) * s, height: median(samples.map(\.size.height)) * s)
        return PKStrokePoint(location: .zero, timeOffset: 0, size: size,
                             opacity: median(samples.map(\.opacity)),
                             force: median(samples.map(\.force)),
                             azimuth: median(samples.map(\.azimuth)),
                             altitude: median(samples.map(\.altitude)))
    }

    // MARK: Geometry helpers

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    private static func normalize(_ v: CGPoint) -> CGPoint {
        let l = hypot(v.x, v.y)
        return l > 0 ? CGPoint(x: v.x / l, y: v.y / l) : CGPoint(x: 1, y: 0)
    }

    private static func boundingBox(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .zero }
        var r = CGRect(origin: f, size: .zero)
        for q in p { r = r.union(CGRect(origin: q, size: .zero)) }
        return r
    }

    private static func pathLength(_ p: [CGPoint]) -> CGFloat {
        zip(p, p.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func perpendicularDistance(_ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let l = distance(a, b)
        guard l > 0 else { return distance(q, a) }
        return abs((b.x - a.x) * (a.y - q.y) - (a.x - q.x) * (b.y - a.y)) / l
    }

    private static func segmentDistance(_ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = dot(ab, ab)
        guard lengthSquared > 0 else { return distance(q, a) }
        let t = max(0, min(1, dot(CGPoint(x: q.x - a.x, y: q.y - a.y), ab) / lengthSquared))
        return distance(q, CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
    }

    private static func meanDistance(_ p: [CGPoint], toPolygon v: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for q in p {
            var best = CGFloat.infinity
            for i in v.indices {
                best = min(best, segmentDistance(q, v[i], v[(i + 1) % v.count]))
            }
            total += best
        }
        return total / CGFloat(max(p.count, 1))
    }

    /// Ramer–Douglas–Peucker simplification.
    private static func rdp(_ p: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard p.count > 2, let a = p.first, let b = p.last else { return p }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(p.count - 1) {
            let d = a == b ? distance(p[i], a) : perpendicularDistance(p[i], a, b)
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > epsilon else { return [a, b] }
        let left = rdp(Array(p[0...index]), epsilon: epsilon)
        let right = rdp(Array(p[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// Drops vertices where the outline barely turns (treats the polygon as closed).
    private static func removeCollinear(_ v: [CGPoint], minTurn degrees: CGFloat) -> [CGPoint] {
        var result = v
        var changed = true
        while changed && result.count > 3 {
            changed = false
            for i in result.indices {
                let prev = result[(i + result.count - 1) % result.count]
                let cur = result[i]
                let next = result[(i + 1) % result.count]
                let a1 = atan2(cur.y - prev.y, cur.x - prev.x)
                let a2 = atan2(next.y - cur.y, next.x - cur.x)
                var turn = abs(a2 - a1) * 180 / .pi
                if turn > 180 { turn = 360 - turn }
                if turn < degrees || distance(prev, cur) < 4 {
                    result.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return result
    }
}
