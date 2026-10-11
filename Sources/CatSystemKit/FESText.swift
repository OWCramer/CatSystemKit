import CoreGraphics
import CoreText
import Foundation

/// How a FES text object (`STRING8`) sets its text, from its `layout` commands: the size
/// (`layout size 18 22 25 28 32` lists one per font-size setting; the middle one is used),
/// the face (`layout fontind 1 GenJyuuGothicX-Bold.ttf`), the letter and edge colours
/// (`layout color 67 33 0 255 255 255 …`: the letters, then their outline) and the reveal
/// speed (`layout frame N`, in the half frames a letter takes, as `startup.xml`'s
/// `strframe_frame` 5 says; 0 shows the text at once).
struct FESTextStyle: Hashable {
    var size = 20
    var font = "GenJyuuGothicX-Bold.ttf"
    var color: [Int] = [255, 255, 255]
    var edge: [Int]? = [0, 33, 67]
    var revealFrame = 0
    var lineSpacing = 6
}

/// Sets FES text with Core Text into a picture the screen blends like any other.
enum FESText {
    /// `fonts`: the game's font files (lower-cased, without extension) to the names they
    /// registered under.
    /// `singleLine`: a one-line box (a save's comment) cuts the text short with an ellipsis
    /// instead of wrapping it.
    static func render(_ text: String, style: FESTextStyle, maxWidth: Int, singleLine: Bool = false, fonts: [String: String]) -> HGImage.Frame? {
        guard !text.isEmpty else { return nil }
        var text = text
        let size = CGFloat(style.size)
        let key = (style.font as NSString).deletingPathExtension.lowercased()
        let name = fonts[key] ?? fonts.first(where: { $0.key.hasSuffix("bold") })?.value ?? "HiraginoSans-W6"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        func color(_ c: [Int]) -> CGColor {
            CGColor(srgbRed: CGFloat(c.count > 0 ? c[0] : 255) / 255, green: CGFloat(c.count > 1 ? c[1] : 255) / 255,
                    blue: CGFloat(c.count > 2 ? c[2] : 255) / 255, alpha: 1)
        }
        if singleLine, maxWidth > 0 {
            text = text.replacingOccurrences(of: "\n", with: " ")
            func width(_ t: String) -> Double {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                return CTLineGetTypographicBounds(line, nil, nil, nil)
            }
            if width(text) > Double(maxWidth) {
                var cut = text
                while !cut.isEmpty, width(cut + "…") > Double(maxWidth) { cut.removeLast() }
                text = cut.trimmingCharacters(in: .whitespaces) + "…"
            }
        }
        let edgeWidth = style.edge == nil ? 0 : max(1.5, size / 10)
        let pad = Int(edgeWidth.rounded(.up)) + 1
        let width = singleLine ? 4000 : max(1, maxWidth > 0 ? maxWidth : 1280)
        func attributed(fill: Bool) -> NSAttributedString {
            var spacing = CGFloat(style.lineSpacing)
            let settings = withUnsafePointer(to: &spacing) { pointer -> CTParagraphStyle in
                var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): settings,
            ]
            if fill {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color(style.color)
            } else {
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(style.edge ?? style.color)
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = edgeWidth * 2 / size * 100
            }
            return NSAttributedString(string: text, attributes: attributes)
        }
        let setter = CTFramesetterCreateWithAttributedString(attributed(fill: true))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                  CGSize(width: CGFloat(width), height: 4000), nil)
        let w = min(width, Int(fitted.width.rounded(.up))) + pad * 2
        let h = Int(fitted.height.rounded(.up)) + pad * 2
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let path = CGPath(rect: CGRect(x: CGFloat(pad), y: CGFloat(pad), width: CGFloat(w - pad * 2) + 1, height: CGFloat(h - pad * 2) + 1), transform: nil)
        if style.edge != nil {
            context.setLineJoin(.round)
            let stroke = CTFramesetterCreateWithAttributedString(attributed(fill: false))
            CTFrameDraw(CTFramesetterCreateFrame(stroke, CFRange(), path, nil), context)
        }
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        guard let data = context.data else { return nil }
        let premultiplied = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)
        // Straight alpha, as HG-3 frames are.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = Int(premultiplied[i + 3])
            guard a > 0 else { continue }
            for c in 0..<3 { rgba[i + c] = UInt8(min(255, Int(premultiplied[i + c]) * 255 / a)) }
            rgba[i + 3] = UInt8(a)
        }
        return HGImage.Frame(id: 0, width: w, height: h, bitsPerPixel: 32, offsetX: -pad, offsetY: -pad,
                             canvasWidth: w, canvasHeight: h, baseX: 0, baseY: 0, sections: [], rgba: rgba)
    }
}
