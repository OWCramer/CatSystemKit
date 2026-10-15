// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A shape layer (an E-mote hit area such as `hit_head`) placed for a pose.
public struct EmoteShape {
    /// 0 point, 1 circle, 2 rectangle, 3 quad.
    public let kind: Int
    /// The corners of its 16-unit square (or the point, or a circle's centre), in the
    /// pose's target coordinates, in order round the square.
    public let points: [(x: Double, y: Double)]
    /// A circle's radius.
    public let radius: Double

    /// Whether (x, y) is inside (on the edge counts).
    public func contains(_ x: Double, _ y: Double) -> Bool {
        switch kind {
        case 1:
            guard let c = points.first else { return false }
            let dx = x - c.x, dy = y - c.y
            return dx * dx + dy * dy <= radius * radius
        case 2, 3:
            guard points.count == 4 else { return false }
            // Inside a convex quad: the same side of every edge as the quad turns.
            func cross(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ px: Double, _ py: Double) -> Double {
                (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)
            }
            let turn = cross(points[0], points[1], points[2].x, points[2].y) >= 0 ? 1.0 : -1.0
            for i in 0..<4 where turn * cross(points[i], points[(i + 1) % 4], x, y) < 0 { return false }
            return true
        default:
            return false
        }
    }
}

extension EmoteRenderer {
    /// The model's shape layers for the pose, by label, under `transform` (as `drawList`).
    public func shapes(variables: [String: Double], time: Double = 0,
                       transform: (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)) -> [String: [EmoteShape]] {
        let root = Node(parent: nil, bends: false)
        root.a = transform.a; root.b = transform.b; root.c = transform.c; root.d = transform.d
        root.tx = transform.tx; root.ty = transform.ty
        var out: [String: [EmoteShape]] = [:]
        withShapeSink({ layer, node in
            let kind = layer.shape ?? 0
            let corners = [(-8.0, -8.0), (8.0, -8.0), (8.0, 8.0), (-8.0, 8.0)].map { p -> (x: Double, y: Double) in
                let r = node.toRoot(p.0, p.1)
                return (r.0, r.1)
            }
            let centre = node.toRoot(0, 0)
            let shape: EmoteShape
            switch kind {
            case 1:
                let edge = node.toRoot(8, 0)
                shape = EmoteShape(kind: 1, points: [(centre.0, centre.1)], radius: hypot(edge.0 - centre.0, edge.1 - centre.1))
            case 2, 3:
                shape = EmoteShape(kind: kind, points: corners, radius: 0)
            default:
                shape = EmoteShape(kind: 0, points: [(centre.0, centre.1)], radius: 0)
            }
            out[layer.label, default: []].append(shape)
        }) {
            let (_, instances) = items(variables: variables, time: time, root: root)
            for instance in instances { instance.subtree = [:] }
        }
        return out
    }
}
