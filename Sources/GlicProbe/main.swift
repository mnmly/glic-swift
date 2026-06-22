// Probe: does the Swift -> C++ applyStudioEffect bridge actually mutate the buffer?
import CGlic
import CxxStdlib

func makeImg(_ w: Int, _ h: Int) -> [UInt32] {
    var px = [UInt32](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            px[y * w + x] = (0xFF << 24) | (UInt32((x * 255) / w) << 16)
                | (UInt32((y * 255) / h) << 8) | UInt32((x ^ y) & 0xFF)
        }
    }
    return px
}

let w = 256, h = 256
let img = makeImg(w, h)
print("input distinct colors: \(Set(img).count)")

func tryEffect(_ name: String, _ type: Int32, _ intensity: Int32, _ block: Int32,
               _ sortMode: Int32, _ threshold: Int32, _ vertical: Int32,
               _ leak: Float, _ seed: UInt32) {
    var buf = img
    buf.withUnsafeMutableBufferPointer { mb in
        glic.applyStudioEffect(mb.baseAddress, Int32(w), Int32(h),
                               type, intensity, block, 2, 0, 4,
                               sortMode, threshold, vertical, leak, seed)
    }
    print("\(name): changed=\(buf != img)  distinct=\(Set(buf).count)")
}

tryEffect("PIXELATE",        1, 50, 16, 0, 50, 0, 0.5, 1)
tryEffect("DCT_CORRUPT",     7, 60, 16, 0, 50, 0, 0.5, 999)
tryEffect("PIXEL_SORT",      8, 50, 8, 0, 60, 0, 0.5, 12345)
tryEffect("PREDICTION_LEAK", 9, 50, 16, 0, 50, 0, 0.7, 7)

// Replicate the app's new flow: codec ONCE, then effect on the cached output.
var p = glic.StudioParams(); p.quantization = 25; p.tile = 256; p.threads = 4
let cached = img.withUnsafeBufferPointer { Array(glic.roundTripTiled($0.baseAddress, Int32(w), Int32(h), p)) }
print("\ncached codec output: distinct=\(Set(cached).count)")
var fx = cached
fx.withUnsafeMutableBufferPointer { mb in
    glic.applyStudioEffect(mb.baseAddress, Int32(w), Int32(h), 8, 50, 8, 2, 0, 4, 0, 60, 0, 0.5, 12345)
}
print("cached + PIXEL_SORT: distinct=\(Set(fx).count)  differs from cached: \(fx != cached)")
