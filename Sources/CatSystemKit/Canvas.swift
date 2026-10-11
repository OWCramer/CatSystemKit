import Foundation

/// A straight-RGBA screen that starts black, for headless drawing (FES screens, scenes).
struct Canvas {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    /// Black, or clear (`transparent`: then the pixels end up premultiplied, as every blend
    /// below is "over" in premultiplied terms and keeps alpha up to date).
    init(width: Int, height: Int, transparent: Bool = false) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        if !transparent { for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 } }
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A rectangle of `color` (`0xAARRGGBB`), its alpha scaled by `alpha` (0–255).
    mutating func fill(x: Int, y: Int, w: Int, h: Int, color: UInt32, alpha: Int) {
        let a = Int(color >> 24) * alpha / 255
        guard a > 0 else { return }
        let r = Int(color >> 16 & 0xFF), g = Int(color >> 8 & 0xFF), b = Int(color & 0xFF)
        for yy in max(0, y)..<max(max(0, y), min(height, y + h)) {
            for xx in max(0, x)..<max(max(0, x), min(width, x + w)) {
                let o = (yy * width + xx) * 4
                pixels[o] = UInt8((r * a + Int(pixels[o]) * (255 - a)) / 255)
                pixels[o + 1] = UInt8((g * a + Int(pixels[o + 1]) * (255 - a)) / 255)
                pixels[o + 2] = UInt8((b * a + Int(pixels[o + 2]) * (255 - a)) / 255)
                pixels[o + 3] = UInt8(a + Int(pixels[o + 3]) * (255 - a) / 255)
            }
        }
    }

    /// Premultiplied RGBA (an E-mote drawing) with its top-left corner at (x, y), faded by `alpha`.
    mutating func blitPremultiplied(_ rgba: [UInt8], width w: Int, height h: Int, x: Int, y: Int, alpha: Int) {
        let x0 = max(0, x), x1 = min(width, x + w)
        let y0 = max(0, y), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1, alpha > 0 else { return }
        let stride = width
        rgba.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let s = ((yy - y) * w + (xx - x)) * 4
                        let a = Int(src[s + 3]) * alpha / 255
                        guard a > 0 else { continue }
                        let d = (yy * stride + xx) * 4
                        for c in 0..<3 {
                            let value = Int(src[s + c]) * alpha / 255 + Int(dst[d + c]) * (255 - a) / 255
                            dst[d + c] = UInt8(min(255, value))
                        }
                        dst[d + 3] = UInt8(min(255, a + Int(dst[d + 3]) * (255 - a) / 255))
                    }
                }
            }
        }
    }

    /// An HG-3 frame with its top-left corner at (x, y), blended by its alpha times `alpha`.
    mutating func blit(_ frame: HGImage.Frame, x: Int, y: Int, alpha: Int) {
        let x0 = max(0, x), x1 = min(width, x + frame.width)
        let y0 = max(0, y), y1 = min(height, y + frame.height)
        guard x0 < x1, y0 < y1 else { return }
        let w = width
        frame.rgba.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let s = ((yy - y) * frame.width + (xx - x)) * 4
                        let a = Int(src[s + 3]) * alpha / 255
                        guard a > 0 else { continue }
                        let d = (yy * w + xx) * 4
                        for c in 0..<3 { dst[d + c] = UInt8((Int(src[s + c]) * a + Int(dst[d + c]) * (255 - a)) / 255) }
                        dst[d + 3] = UInt8(a + Int(dst[d + 3]) * (255 - a) / 255)
                    }
                }
            }
        }
    }

    /// An HG-3 frame scaled by (`sx`, `sy`) with its top-left corner at (x, y), sampled
    /// nearest (headless pictures of zoomed scenes).
    mutating func blit(_ frame: HGImage.Frame, x: Double, y: Double, scaleX sx: Double, scaleY sy: Double, alpha: Int) {
        guard sx > 0, sy > 0 else { return }
        if abs(sx - 1) < 0.0001, abs(sy - 1) < 0.0001 {
            blit(frame, x: Int(x.rounded()), y: Int(y.rounded()), alpha: alpha)
            return
        }
        let x0 = max(0, Int(x.rounded(.down))), x1 = min(width, Int((x + Double(frame.width) * sx).rounded(.up)))
        let y0 = max(0, Int(y.rounded(.down))), y1 = min(height, Int((y + Double(frame.height) * sy).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return }
        let w = width
        frame.rgba.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for yy in y0..<y1 {
                    let fy = Int((Double(yy) + 0.5 - y) / sy)
                    guard fy >= 0, fy < frame.height else { continue }
                    for xx in x0..<x1 {
                        let fx = Int((Double(xx) + 0.5 - x) / sx)
                        guard fx >= 0, fx < frame.width else { continue }
                        let s = (fy * frame.width + fx) * 4
                        let a = Int(src[s + 3]) * alpha / 255
                        guard a > 0 else { continue }
                        let d = (yy * w + xx) * 4
                        for c in 0..<3 { dst[d + c] = UInt8((Int(src[s + c]) * a + Int(dst[d + c]) * (255 - a)) / 255) }
                        dst[d + 3] = UInt8(a + Int(dst[d + 3]) * (255 - a) / 255)
                    }
                }
            }
        }
    }
}
