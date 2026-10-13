import Foundation

/// An E-mote pose evaluated for a GPU: the layer tree's transforms as a flat list of nodes
/// (each pointing at its parent), the images to draw back to front, and the stencils that
/// clip them. Vertices aren't computed here: a grid point of an item is carried up its
/// node chain (patch, then transform, at each node) by the vertex shader.
public struct EmoteDrawList {
    /// One transform of the tree: local → parent is `p' = M · patch(p) + t`, with the patch
    /// (when there is one) taken in the node's box (`boxX`, `boxY` = the box's origin).
    public struct Node {
        public var a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float
        public var boxX: Float, boxY: Float, boxW: Float, boxH: Float
        /// The parent's index, or -1 at the root.
        public var parent: Int32
        /// The first of the patch's 16 points in `meshes`, or -1.
        public var mesh: Int32
    }

    public struct Item {
        public var node: Int
        public var texture: Int
        /// The image's rectangle in its texture.
        public var left: Int, top: Int, width: Int, height: Int
        public var originX: Float, originY: Float
        /// Grid cells along each side.
        public var divisions: Int
        public var opacity: Float
        /// Stencils (indices in `stencils`) that clip this item.
        public var clips: [Int]
        /// Bounds of the item's grid in root coordinates (filled for mask items only).
        public var bounds: (minX: Float, minY: Float, maxX: Float, maxY: Float)?
    }

    /// A stencil's mask: the coverage of these items.
    public struct Stencil {
        public var items: [Item]
        /// The items' bounds in root coordinates, a little padded.
        public var minX: Float, minY: Float, maxX: Float, maxY: Float
    }

    public var nodes: [Node] = []
    /// Patch points, (x, y) pairs, 16 per patch.
    public var meshes: [Float] = []
    public var items: [Item] = []
    public var stencils: [Stencil] = []

    /// Every vertex of every grid (for comparisons and for working out bounds).
    public func gridCount() -> Int { items.reduce(0) { $0 + ($1.divisions + 1) * ($1.divisions + 1) } }
}

extension EmoteRenderer {
    /// The pose for `variables` at `time`, under `transform` (a, b, c, d, tx, ty: the model's
    /// origin and axes in the target's pixels).
    public func drawList(variables: [String: Double], time: Double = 0,
                         transform: (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)) -> EmoteDrawList {
        let root = Node(parent: nil, bends: false)
        root.a = transform.a; root.b = transform.b; root.c = transform.c; root.d = transform.d
        root.tx = transform.tx; root.ty = transform.ty
        let (unsorted, instances) = items(variables: variables, time: time, root: root)
        defer { for instance in instances { instance.subtree = [:] } }
        let sorted = unsorted.enumerated().sorted { ($0.element.node.z, $0.offset) < ($1.element.node.z, $1.offset) }.map(\.element)

        var list = EmoteDrawList()
        var nodeIndex: [ObjectIdentifier: Int32] = [:]
        func index(_ node: Node) -> Int32 {
            let key = ObjectIdentifier(node)
            if let hit = nodeIndex[key] { return hit }
            let parent = node.parent.map(index) ?? -1
            var mesh: Int32 = -1
            if let m = node.mesh {
                mesh = Int32(list.meshes.count / 2)
                list.meshes += m.map { Float($0) }
            }
            let i = Int32(list.nodes.count)
            list.nodes.append(.init(a: Float(node.a), b: Float(node.b), c: Float(node.c), d: Float(node.d),
                                    tx: Float(node.tx), ty: Float(node.ty),
                                    boxX: Float(node.boxX), boxY: Float(node.boxY), boxW: Float(node.boxW), boxH: Float(node.boxH),
                                    parent: parent, mesh: mesh))
            nodeIndex[key] = i
            return i
        }
        var stencilIndex: [ObjectIdentifier: Int] = [:]
        func flat(_ item: Item, clips: [Int]) -> EmoteDrawList.Item {
            .init(node: Int(index(item.node)), texture: item.textureIndex,
                  left: item.icon.left, top: item.icon.top, width: item.icon.width, height: item.icon.height,
                  originX: Float(item.icon.originX), originY: Float(item.icon.originY),
                  divisions: item.divisions, opacity: Float(item.opacity), clips: clips, bounds: nil)
        }
        func stencil(_ s: Stencil) -> Int {
            let key = ObjectIdentifier(s)
            if let hit = stencilIndex[key] { return hit }
            var maskItems: [EmoteDrawList.Item] = []
            var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
            for label in s.labels {
                for item in s.instance.subtree[label] ?? [] {
                    var flatItem = flat(item, clips: [])
                    // The mask's extent, from its grid (masks are few and small).
                    let n = item.divisions
                    var b = (minX: Float.infinity, minY: Float.infinity, maxX: -Float.infinity, maxY: -Float.infinity)
                    // The grid's edge at every point, its inside every fourth: the bounds come
                    // from the edge (inner points rarely reach past it) at an eighth of the cost,
                    // which counted with several characters on screen.
                    for j in 0...n {
                        let edgeRow = j == 0 || j == n
                        for i in 0...n where edgeRow || i == 0 || i == n || (i % 4 == 0 && j % 4 == 0) {
                            let p = item.node.toRoot(Double(item.icon.width) * Double(i) / Double(n) - item.icon.originX,
                                                     Double(item.icon.height) * Double(j) / Double(n) - item.icon.originY)
                            b.minX = min(b.minX, Float(p.0)); b.maxX = max(b.maxX, Float(p.0))
                            b.minY = min(b.minY, Float(p.1)); b.maxY = max(b.maxY, Float(p.1))
                        }
                    }
                    flatItem.bounds = b
                    minX = min(minX, b.minX); minY = min(minY, b.minY); maxX = max(maxX, b.maxX); maxY = max(maxY, b.maxY)
                    maskItems.append(flatItem)
                }
            }
            let i = list.stencils.count
            list.stencils.append(.init(items: maskItems, minX: minX - 4, minY: minY - 4, maxX: maxX + 4, maxY: maxY + 4))
            stencilIndex[key] = i
            return i
        }
        for item in sorted {
            let clips = item.clips.map(stencil)
            list.items.append(flat(item, clips: clips))
        }
        return list
    }
}
