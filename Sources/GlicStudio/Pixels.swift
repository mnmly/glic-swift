import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// Image <-> packed-ARGB buffer plumbing, and the GPU (Core Image) effects layer.
// The codec's `Color` is a uint32 ARGB (0xAARRGGBB). On little-endian arm64 that
// is byte order BGRA in memory, i.e. premultipliedFirst + byteOrder32Little.
// We use the SAME format both directions, so any orientation/format detail
// cancels out on the round-trip.
enum Pixels {
    private static let bitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func toBuffer(_ cg: CGImage) -> (px: [UInt32], w: Int, h: Int) {
        let w = cg.width, h = cg.height
        var px = [UInt32](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        px.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs, bitmapInfo: bitmapInfo
            ) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return (px, w, h)
    }

    static func toCGImage(_ px: [UInt32], _ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0, px.count == w * h else { return nil }
        var data = px
        let cs = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs, bitmapInfo: bitmapInfo
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    static func load(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    // GPU effects: applied to the already-decoded image; never re-runs the codec.
    static func applyEffects(_ cg: CGImage, _ e: EffectSettings, ctx: CIContext) -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        var img = CIImage(cgImage: cg)

        if e.pixelate {
            let f = CIFilter.pixellate()
            f.inputImage = img
            f.scale = Float(max(1, e.pixelScale))
            f.center = CGPoint(x: cg.width / 2, y: cg.height / 2)
            if let o = f.outputImage { img = o.cropped(to: extent) }
        }
        if e.posterize {
            let f = CIFilter.colorPosterize()
            f.inputImage = img
            f.levels = Float(max(2, e.levels))
            if let o = f.outputImage { img = o }
        }
        if e.colorAdjust {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(e.saturation)
            f.contrast = Float(e.contrast)
            f.brightness = Float(e.brightness)
            if let o = f.outputImage { img = o }
        }
        return ctx.createCGImage(img, from: extent) ?? cg
    }
}

struct EffectSettings: Sendable {
    var pixelate = false
    var pixelScale = 8.0
    var posterize = false
    var levels = 6.0
    var colorAdjust = false
    var saturation = 1.0
    var contrast = 1.0
    var brightness = 0.0
}
