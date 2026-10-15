// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import ImageIO

/// A CatSystem2 HG-3 picture. Format as documented by GARbro
/// (`ArcFormats/CatSystem/ImageHG3.cs`, MIT).
///
/// `HG-3`, a header size (12) and version, then frames: each starts with the offset of the
/// next frame (0 for the last) and an id, followed by tagged sections (an 8-byte name, the
/// offset of the next section from this one, 0 for the last, and the payload length):
/// - `stdinfo`: width, height, bits per pixel, offset, the canvas the frame sits on, and its
///   base point (where a sprite stands).
/// - `img0000`…: rows of the picture (top row, row count, then two zlib streams: pixel
///   bytes split into four bit planes, and a bit stream of alternating zero/copy run
///   lengths). The planes are re-interleaved, sign-folded, and delta-decoded against the
///   pixel to the left on the first row and the row above elsewhere. Stored bottom-up, BGRA.
/// - `img_jpg` with `img_al`: a JPEG and its zlib-packed alpha plane.
/// - `ats`/`cptype`/`imgmode`: metadata, ignored here.
public struct HGImage: Sendable {
    public struct Frame: Sendable {
        public let id: Int
        public let width: Int
        public let height: Int
        public let bitsPerPixel: Int
        public let offsetX: Int
        public let offsetY: Int
        public let canvasWidth: Int
        public let canvasHeight: Int
        public let baseX: Int
        public let baseY: Int
        /// Section names in order, for inspection.
        public let sections: [String]
        /// The small metadata sections' payloads (`cptype`, `imgmode`, `ats`), for inspection.
        public var metadata: [String: [UInt8]] = [:]
        /// Straight (non-premultiplied) RGBA, top row first.
        public let rgba: [UInt8]
    }

    public let frames: [Frame]

    /// A frame by its id (scripts name frames by id: `sys_title_en` 9 is the logo).
    public func frame(id: Int) -> Frame? { frames.first { $0.id == id } }

    public enum Failure: Error, CustomStringConvertible {
        case notHG3
        case malformed(String)

        public var description: String {
            switch self {
            case .notHG3: "not an HG-3 picture"
            case .malformed(let why): "HG-3: \(why)"
            }
        }
    }

    public static func isHG3(_ bytes: [UInt8]) -> Bool { bytes.starts(with: Array("HG-3".utf8)) }

    /// Decodes every frame; `pixels: false` reads only the headers.
    public init(_ bytes: [UInt8], pixels: Bool = true) throws {
        guard Self.isHG3(bytes), bytes.count >= 0x14 else { throw Failure.notHG3 }
        var frames: [Frame] = []
        var frameStart = Int(bytes.le32(4))
        while frameStart + 8 <= bytes.count {
            let next = Int(bytes.le32(frameStart))
            let id = Int(bytes.le32(frameStart + 4))
            frames.append(try Self.frame(bytes, at: frameStart, id: id, pixels: pixels))
            if next == 0 { break }
            frameStart += next
        }
        guard !frames.isEmpty else { throw Failure.malformed("no frames") }
        self.frames = frames
    }

    private static func frame(_ bytes: [UInt8], at start: Int, id: Int, pixels: Bool) throws -> Frame {
        var sections: [(name: String, payload: Range<Int>)] = []
        var tag = start + 8
        while tag + 16 <= bytes.count {
            let name = String(decoding: bytes.cString(tag, max: 8), as: UTF8.self)
            let next = Int(bytes.le32(tag + 8))
            let length = Int(bytes.le32(tag + 12))
            let payload = (tag + 16)..<min(tag + 16 + length, bytes.count)
            sections.append((name, payload))
            if next == 0 { break }
            tag += next
        }
        guard let info = sections.first(where: { $0.name == "stdinfo" }), info.payload.count >= 40 else {
            throw Failure.malformed("frame \(id) has no stdinfo")
        }
        let p = info.payload.lowerBound
        let width = Int(bytes.le32(p)), height = Int(bytes.le32(p + 4)), bpp = Int(bytes.le32(p + 8))
        func signed(_ at: Int) -> Int { Int(Int32(bitPattern: bytes.le32(at))) }
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw Failure.malformed("frame \(id) size \(width)×\(height)")
        }
        var rgba: [UInt8] = []
        if pixels {
            if let jpeg = sections.first(where: { $0.name == "img_jpg" }) {
                rgba = try decodeJPEG(bytes, jpeg: jpeg.payload, alpha: sections.first { $0.name == "img_al" }?.payload,
                                      width: width, height: height)
            } else {
                let parts = sections.filter { $0.name.hasPrefix("img") && $0.name.dropFirst(3).allSatisfy(\.isNumber) }
                guard !parts.isEmpty else {
                    throw Failure.malformed("frame \(id): no image section in \(sections.map(\.name))")
                }
                guard bpp == 32 || bpp == 24 else { throw Failure.malformed("frame \(id): \(bpp) bits per pixel") }
                rgba = [UInt8](repeating: 0, count: width * height * 4)
                do {
                    for part in parts { try decodePart(bytes, part.payload, width: width, height: height, bpp: bpp, into: &rgba) }
                } catch {
                    // One odd frame (sys_meswnd's 8×8 frame 31 has a run total for 32 rows)
                    // shouldn't cost the picture its other frames: it stays transparent.
                    rgba = [UInt8](repeating: 0, count: width * height * 4)
                }
            }
        }
        var metadata: [String: [UInt8]] = [:]
        for section in sections where !section.name.hasPrefix("img") || section.name == "imgmode" {
            if section.payload.count <= 64 { metadata[section.name] = Array(bytes[section.payload]) }
        }
        return Frame(id: id, width: width, height: height, bitsPerPixel: bpp,
                     offsetX: signed(p + 12), offsetY: signed(p + 16),
                     canvasWidth: Int(bytes.le32(p + 20)), canvasHeight: Int(bytes.le32(p + 24)),
                     baseX: signed(p + 32), baseY: signed(p + 36),
                     sections: sections.map(\.name), metadata: metadata, rgba: rgba)
    }

    /// One `img0000` section: rows `top ..< top + rows` of the picture, counted from the top.
    private static func decodePart(_ bytes: [UInt8], _ payload: Range<Int>, width: Int, height: Int, bpp: Int,
                                   into rgba: inout [UInt8]) throws {
        let p = payload.lowerBound
        guard payload.count >= 24 else { throw Failure.malformed("short image section") }
        let top = Int(bytes.le32(p)), rows = Int(bytes.le32(p + 4))
        let dataPacked = Int(bytes.le32(p + 8)), dataSize = Int(bytes.le32(p + 12))
        let ctlPacked = Int(bytes.le32(p + 16)), ctlSize = Int(bytes.le32(p + 20))
        let dataStart = p + 24
        guard top >= 0, rows > 0, top + rows <= height, dataStart + dataPacked + ctlPacked <= payload.upperBound else {
            throw Failure.malformed("image section rows \(top)+\(rows) of \(height)")
        }
        let data = try Zlib.inflate(bytes[dataStart..<dataStart + dataPacked], size: dataSize)
        let ctl = try Zlib.inflate(bytes[(dataStart + dataPacked)..<(dataStart + dataPacked + ctlPacked)], size: ctlSize)

        // Zero runs and copy runs alternate; the control stream says which comes first and
        // the total length, then each run's length (Elias gamma, LSB-first bits).
        var bits = BitReader(ctl)
        var copy = bits.bit() != 0
        let total = try bits.gamma()
        let pixelSize = bpp / 8
        let stride = width * pixelSize
        guard total == stride * rows else { throw Failure.malformed("run total \(total) for \(stride)×\(rows)") }
        var planar = [UInt8](repeating: 0, count: total)
        var src = 0, dst = 0
        while dst < total {
            let count = try bits.gamma()
            guard dst + count <= total else { throw Failure.malformed("run past the end") }
            if copy {
                guard src + count <= data.count else { throw Failure.malformed("copy past the data") }
                planar.withUnsafeMutableBufferPointer { out in
                    data.withUnsafeBufferPointer { inp in
                        (out.baseAddress! + dst).update(from: inp.baseAddress! + src, count: count)
                    }
                }
                src += count
            }
            dst += count
            copy.toggle()
        }

        // Four planes of two bits each rebuild each 32-bit group; then the sign fold.
        let plane = total / 4
        var pixels = [UInt8](repeating: 0, count: total)
        planar.withUnsafeBufferPointer { inp in
            pixels.withUnsafeMutableBufferPointer { out in
                for i in 0..<plane {
                    let v = spread[Int(inp[i])] << 6 | spread[Int(inp[plane + i])] << 4
                        | spread[Int(inp[2 * plane + i])] << 2 | spread[Int(inp[3 * plane + i])]
                    out[i * 4] = unfold(UInt8(truncatingIfNeeded: v))
                    out[i * 4 + 1] = unfold(UInt8(truncatingIfNeeded: v >> 8))
                    out[i * 4 + 2] = unfold(UInt8(truncatingIfNeeded: v >> 16))
                    out[i * 4 + 3] = unfold(UInt8(truncatingIfNeeded: v >> 24))
                }
                for x in pixelSize..<stride { out[x] &+= out[x - pixelSize] }
                if rows > 1 {
                    for y in 1..<rows {
                        let line = y * stride, prev = line - stride
                        for x in 0..<stride { out[line + x] &+= out[prev + x] }
                    }
                }
            }
        }
        // Stored bottom-up and BGR(A).
        rgba.withUnsafeMutableBufferPointer { out in
            for y in 0..<rows {
                let srcRow = (rows - 1 - y) * stride
                var o = ((top + y) * width) * 4
                for x in 0..<width {
                    let s = srcRow + x * pixelSize
                    out[o] = pixels[s + 2]
                    out[o + 1] = pixels[s + 1]
                    out[o + 2] = pixels[s]
                    out[o + 3] = pixelSize == 4 ? pixels[s + 3] : 255
                    o += 4
                }
            }
        }
    }

    /// Byte i's bit pairs (7-6, 5-4, 3-2, 1-0) moved to bits 24, 16, 8 and 0, so four planes
    /// shifted by 6, 4, 2 and 0 interleave into one little-endian group of four bytes.
    private static let spread: [UInt32] = (0..<256).map { i in
        let i = UInt32(i)
        return (i & 0xC0) << 18 | (i & 0x30) << 12 | (i & 0x0C) << 6 | (i & 0x03)
    }

    @inline(__always)
    private static func unfold(_ v: UInt8) -> UInt8 { v & 1 != 0 ? (v >> 1) ^ 0xFF : v >> 1 }

    private static func decodeJPEG(_ bytes: [UInt8], jpeg: Range<Int>, alpha: Range<Int>?, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(Data(bytes[jpeg]) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let raw = ctx.data
        else { throw Failure.malformed("JPEG did not decode") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgba = [UInt8](UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        var plane = [UInt8](repeating: 255, count: width * height)
        if let alpha, alpha.count >= 8 {
            let packed = Int(bytes.le32(alpha.lowerBound)), size = Int(bytes.le32(alpha.lowerBound + 4))
            let start = alpha.lowerBound + 8
            if start + packed <= bytes.count, size == width * height {
                plane = try Zlib.inflate(bytes[start..<start + packed], size: size)
            }
        }
        for i in 0..<width * height { rgba[i * 4 + 3] = plane[i] }
        return rgba
    }
}

/// LSB-first bit reader with Elias-gamma numbers, as HG-2/HG-3 control streams use.
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    private var bitIndex = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() -> Int {
        guard position < bytes.count else { return 0 }
        let b = Int(bytes[position] >> bitIndex) & 1
        bitIndex += 1
        if bitIndex == 8 { bitIndex = 0; position += 1 }
        return b
    }

    /// n zero bits, a one, then n more bits after an implicit leading one.
    mutating func gamma() throws -> Int {
        var n = 0
        while bit() == 0 {
            n += 1
            guard n < 32, position < bytes.count else { throw HGImage.Failure.malformed("bad run length") }
        }
        var value = 1
        for _ in 0..<n { value = value << 1 | bit() }
        return value
    }
}

extension HGImage.Frame {
    /// The pixels premultiplied by their alpha (for a GPU texture blended "over").
    public func premultipliedRGBA() -> [UInt8] {
        var out = rgba
        out.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: p.count - 3, by: 4) {
                let a = UInt16(p[i + 3])
                if a == 255 { continue }
                p[i] = UInt8((UInt16(p[i]) * a + 127) / 255)
                p[i + 1] = UInt8((UInt16(p[i + 1]) * a + 127) / 255)
                p[i + 2] = UInt8((UInt16(p[i + 2]) * a + 127) / 255)
            }
        }
        return out
    }

    /// The red channel alone (a rule picture's grey levels), one byte a pixel.
    public func redPlane() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        rgba.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<min(o.count, p.count / 4) { o[i] = p[i * 4] }
            }
        }
        return out
    }
}
