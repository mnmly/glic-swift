// Swift-side interop benchmark: drives the C++ GLIC codec across the C++ interop
// boundary and times it, to compare against the raw-C++ baseline (bench/bench_cpp).
//
// Measures, per resolution:
//   enc        - encodeToBuffer() called from Swift (byte buffer stays in C++)
//   dec        - decodeFromBuffer() called from Swift
//   rt         - enc + dec (compare directly to the raw C++ round-trip)
//   materialize- cost of pulling decoded pixels into a Swift [UInt32]
//                (this is where the std::vector deep-copy at the boundary lands)

import CGlic
import CxxStdlib
import Dispatch
import Foundation

func makeImage(_ w: Int, _ h: Int) -> [UInt32] {
    var px = [UInt32](repeating: 0, count: w * h)
    var seed: UInt32 = 1234
    func rnd() -> UInt32 { seed = seed &* 1664525 &+ 1013904223; return seed }
    for y in 0..<h {
        for x in 0..<w {
            var r = (x * 255) / w
            var g = (y * 255) / h
            var b = (x ^ y) & 0xFF
            let n = Int(rnd() & 0x1F) - 16
            r = min(255, max(0, r + n))
            g = min(255, max(0, g + n))
            b = min(255, max(0, b + n))
            px[y * w + x] = (0xFF << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        }
    }
    return px
}

func f1(_ x: Double) -> String { String(format: "%.1f", x) }

let sizes: [(Int, Int, Int)] = [(256, 256, 7), (512, 512, 7), (1024, 1024, 5), (2048, 2048, 3)]

print("resolution    enc_ms   dec_ms    rt_ms   matz_ms   rt_MP/s")
print("------------------------------------------------------------")

for (w, h, iters) in sizes {
    let img = makeImage(w, h)
    let mp = Double(w * h) / 1e6
    var codec = glic.GlicCodec()

    img.withUnsafeBufferPointer { bp in
        // warm-up (not timed)
        let wbuf = codec.encodeToBuffer(bp.baseAddress, Int32(w), Int32(h))
        let wres = codec.decodeFromBuffer(wbuf)
        precondition(wres.success, "decode failed")

        var encMs = [Double](), decMs = [Double](), matMs = [Double]()
        for _ in 0..<iters {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let buf = codec.encodeToBuffer(bp.baseAddress, Int32(w), Int32(h))
            let t1 = DispatchTime.now().uptimeNanoseconds
            let res = codec.decodeFromBuffer(buf)
            let t2 = DispatchTime.now().uptimeNanoseconds
            let arr = Array(res.pixels)   // boundary deep-copy into Swift Array
            let t3 = DispatchTime.now().uptimeNanoseconds
            precondition(arr.count == w * h, "size mismatch")
            encMs.append(Double(t1 - t0) / 1e6)
            decMs.append(Double(t2 - t1) / 1e6)
            matMs.append(Double(t3 - t2) / 1e6)
        }
        encMs.sort(); decMs.sort(); matMs.sort()
        let e = encMs[encMs.count / 2]
        let d = decMs[decMs.count / 2]
        let m = matMs[matMs.count / 2]
        let rt = e + d
        let line = "\(w)x\(h)".padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(line) \(f1(e))    \(f1(d))    \(f1(rt))    \(f1(m))    \(f1(mp / (rt / 1000.0)))")
    }
}
