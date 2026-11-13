import Foundation
import Testing
@testable import CatSystemKit

private indirect enum Plain {
    case int(Int)
    case double(Double)
    case string(String)
    case list([Plain])
    case dict([(String, Plain)])
    case resource(Int)
}

private func integers(_ a: [Int]) -> [UInt8] {
    func size(_ v: Int) -> Int {
        var n = 1
        while n < 8, v >> (8 * n) != 0 { n += 1 }
        return n
    }
    let w = size(a.max() ?? 0), n = size(a.count)
    var out: [UInt8] = [UInt8(0xC + n)]
    for i in 0..<n { out.append(UInt8(truncatingIfNeeded: a.count >> (8 * i))) }
    out.append(UInt8(0xC + w))
    for v in a {
        for i in 0..<w { out.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
    return out
}

private func psb(_ root: Plain, resources: [[UInt8]]) -> [UInt8] {
    var names: [String] = []
    var strings: [String] = []
    func collect(_ v: Plain) {
        switch v {
        case .string(let s):
            if !strings.contains(s) { strings.append(s) }
        case .list(let l):
            for x in l { collect(x) }
        case .dict(let d):
            for (k, x) in d {
                if !names.contains(k) { names.append(k) }
                collect(x)
            }
        default:
            break
        }
    }
    collect(root)
    names.sort()

    func packed(_ parts: [[UInt8]]) -> [UInt8] {
        var offsets: [Int] = []
        var o = 0
        for p in parts {
            offsets.append(o)
            o += p.count
        }
        return integers(offsets) + parts.flatMap { $0 }
    }
    func encode(_ v: Plain) -> [UInt8] {
        switch v {
        case .int(let i):
            var n = 1
            while n < 8, i < -(1 << (8 * n - 1)) || i >= 1 << (8 * n - 1) { n += 1 }
            return [UInt8(4 + n)] + (0..<n).map { UInt8(truncatingIfNeeded: i >> (8 * $0)) }
        case .double(let d):
            let bits = d.bitPattern
            return [0x1F] + (0..<8).map { UInt8(truncatingIfNeeded: bits >> UInt64(8 * $0)) }
        case .string(let s):
            return [0x15, UInt8(strings.firstIndex(of: s)!)]
        case .resource(let i):
            return [0x19, UInt8(i)]
        case .list(let l):
            return [0x20] + packed(l.map(encode))
        case .dict(let d):
            let sorted = d.sorted { names.firstIndex(of: $0.0)! < names.firstIndex(of: $1.0)! }
            return [0x21] + integers(sorted.map { names.firstIndex(of: $0.0)! }) + packed(sorted.map { encode($0.1) })
        }
    }

    let keys = names.map { Array($0.utf8) + [0] }
    var nameData = [0]
    var charset = [0]
    var used: Set<Int> = [0]
    var node: [[UInt8]: Int] = [[]: 0]
    for depth in 0..<(keys.map(\.count).max() ?? 0) {
        var groups: [[UInt8]: Set<UInt8>] = [:]
        for k in keys where k.count > depth { groups[Array(k[..<depth]), default: []].insert(k[depth]) }
        for prefix in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let parent = node[prefix]!
            let kids = groups[prefix]!.sorted()
            var base = 0
            while kids.contains(where: { used.contains(base + Int($0)) }) { base += 1 }
            charset[parent] = base
            let top = base + Int(kids.last!) + 1
            if nameData.count < top { nameData += [Int](repeating: 0, count: top - nameData.count) }
            if charset.count < top { charset += [Int](repeating: 0, count: top - charset.count) }
            for k in kids {
                used.insert(base + Int(k))
                nameData[base + Int(k)] = parent
                node[prefix + [k]] = base + Int(k)
            }
        }
    }
    let tree = keys.map { node[$0]! }

    var stringData: [UInt8] = []
    var stringOffsets: [Int] = []
    for s in strings {
        stringOffsets.append(stringData.count)
        stringData += Array(s.utf8) + [0]
    }
    var chunkOffsets: [Int] = []
    var chunkData: [UInt8] = []
    for r in resources {
        chunkOffsets.append(chunkData.count)
        chunkData += r
    }
    let parts = [integers(charset) + integers(nameData) + integers(tree), integers(stringOffsets), stringData, encode(root),
                 integers(chunkOffsets), integers(resources.map(\.count)), chunkData]
    var at = [0x38]
    for p in parts { at.append(at.last! + p.count) }
    var out: [UInt8] = Array("PSB".utf8) + [0, 3, 0, 0, 0]
    for v in [0x38, at[0], at[1], at[2], at[4], at[5], at[6], at[3]] {
        for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
    out += [UInt8](repeating: 0, count: 0x38 - out.count)
    return out + parts.flatMap { $0 }
}

private func layer(_ label: String, type: Int, inherit: Int, content: [(String, Plain)], children: [Plain] = []) -> Plain {
    .dict([("label", .string(label)), ("type", .int(type)), ("inheritMask", .int(inherit)), ("children", .list(children)),
           ("frameList", .list([.dict([("time", .double(0)), ("type", .int(2)), ("content", .dict(content))])]))])
}

private func renderer(_ layers: [Plain]) throws -> EmoteRenderer {
    func icon(_ w: Int, _ h: Int, _ r: Int) -> Plain {
        .dict([("width", .int(w)), ("height", .int(h)), ("originX", .double(Double(w) / 2)),
               ("originY", .double(Double(h) / 2)), ("pixel", .resource(r))])
    }
    let motion = Plain.dict([("lastTime", .double(10)), ("parameter", .list([])), ("layer", .list(layers))])
    let root = Plain.dict([
        ("id", .string("motion")),
        ("metadata", .dict([("base", .dict([("chara", .string("o")), ("motion", .string("m"))]))])),
        ("source", .dict([("s", .dict([("icon", .dict([("square", icon(8, 8, 0)), ("bar", icon(8, 2, 1))]))]))])),
        ("object", .dict([("o", .dict([("motion", .dict([("m", motion)]))]))])),
    ])
    let bytes = psb(root, resources: [[UInt8](repeating: 255, count: 8 * 8 * 4), [UInt8](repeating: 255, count: 8 * 2 * 4)])
    return EmoteRenderer(model: try EmoteModel(psb: try PSBFile(bytes)))
}

private func opaque(_ image: EmoteImage) -> Int {
    stride(from: 3, to: image.rgba.count, by: 4).filter { image.rgba[$0] >= 128 }.count
}

private func clipped(inherit: Int) throws -> EmoteImage {
    let square = layer("square", type: 0, inherit: 0x20007FC,
                       content: [("src", .string("src/s/square")), ("mask", .int(3)), ("ox", .int(0)), ("oy", .int(0)),
                                 ("coord", .list([.double(6), .double(0), .double(0)]))])
    let clip = layer("clip", type: 7, inherit: inherit,
                     content: [("src", .string("clip")), ("mask", .int(0x61)), ("ox", .int(0)), ("oy", .int(0)),
                               ("zx", .double(0.5)), ("zy", .double(0.25))],
                     children: [square])
    return try renderer([clip]).render(variables: [:])
}

private func turned(inherit: Int) throws -> EmoteImage {
    let bar = layer("bar", type: 0, inherit: inherit, content: [("src", .string("src/s/bar")), ("mask", .int(0))])
    let turn = layer("turn", type: 2, inherit: 0x20007FC, content: [("mask", .int(0x10)), ("angle", .double(90))], children: [bar])
    return try renderer([turn]).render(variables: [:])
}

@Test func clipLayersKeepTheirZoomFromChildrenAndClipThem() throws {
    #expect(opaque(try clipped(inherit: 0x240066C)) == 6 * 8)
}

@Test func clipLayersWithoutInheritParentPassTheirZoomOn() throws {
    #expect(opaque(try clipped(inherit: 0x200066C)) < 6 * 8)
}

@Test func layersInheritOnlyTheTransformsTheirMaskNames() throws {
    let kept = try turned(inherit: 0x20007EC)
    #expect(kept.width > kept.height)
    let followed = try turned(inherit: 0x20007FC)
    #expect(followed.height > followed.width)
}
