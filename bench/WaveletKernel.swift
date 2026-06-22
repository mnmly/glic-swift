// Swift port of the representative wavelet kernel (mirror of bench/wavelet_kernel.cpp).
// Two implementations:
//   naive  - idiomatic [Double] subscripting (bounds-checked under -O)
//   tuned  - withUnsafeMutableBufferPointer, raw pointer arithmetic
// Compile once with -O and once with -Ounchecked to see the bounds-check tax.
//
// Build: swiftc -O            bench/WaveletKernel.swift -o bench/wk_swift_O
//        swiftc -Ounchecked   bench/WaveletKernel.swift -o bench/wk_swift_Ou

import Foundation

let H: [Double] = [
    0.054415842, -0.312871590, 0.675630736, -0.585354684,
    -0.015829105, 0.284015543, -0.000472485, -0.128747427,
    0.017369301, 0.044088254, -0.013981028, -0.008746094,
    0.004870353, -0.000391740, -0.000675449, 0.000117477,
]
let G: [Double] = (0..<16).map { k in (k & 1 == 1 ? -1.0 : 1.0) * H[15 - k] }

// ---- naive: idiomatic array subscripting ----
func fwt2dNaive(_ a: inout [Double], _ tmp: inout [Double], _ W: Int, _ levels: Int) {
    for lvl in 0..<levels {
        let n = W >> lvl
        let half = n >> 1
        for r in 0..<n { // rows
            let rb = r * W
            for i in 0..<n { tmp[i] = a[rb + i] }
            for i in 0..<half {
                var av = 0.0, dv = 0.0
                let base = 2 * i
                for k in 0..<16 {
                    var idx = base + k; if idx >= n { idx -= n }
                    let v = tmp[idx]
                    av += H[k] * v; dv += G[k] * v
                }
                a[rb + i] = av
                a[rb + half + i] = dv
            }
        }
        for c in 0..<n { // columns
            for i in 0..<n { tmp[i] = a[i * W + c] }
            for i in 0..<half {
                var av = 0.0, dv = 0.0
                let base = 2 * i
                for k in 0..<16 {
                    var idx = base + k; if idx >= n { idx -= n }
                    let v = tmp[idx]
                    av += H[k] * v; dv += G[k] * v
                }
                a[i * W + c] = av
                a[(half + i) * W + c] = dv
            }
        }
    }
}

// ---- tuned: unsafe buffer pointers ----
func fwt2dTuned(_ a: inout [Double], _ tmp: inout [Double], _ W: Int, _ levels: Int) {
    H.withUnsafeBufferPointer { hb in
    G.withUnsafeBufferPointer { gb in
    a.withUnsafeMutableBufferPointer { ab in
    tmp.withUnsafeMutableBufferPointer { tb in
        let h = hb.baseAddress!, g = gb.baseAddress!
        let A = ab.baseAddress!, T = tb.baseAddress!
        for lvl in 0..<levels {
            let n = W >> lvl
            let half = n >> 1
            for r in 0..<n {
                let rb = r * W
                for i in 0..<n { T[i] = A[rb + i] }
                for i in 0..<half {
                    var av = 0.0, dv = 0.0
                    let base = 2 * i
                    for k in 0..<16 {
                        var idx = base + k; if idx >= n { idx -= n }
                        let v = T[idx]
                        av += h[k] * v; dv += g[k] * v
                    }
                    A[rb + i] = av
                    A[rb + half + i] = dv
                }
            }
            for c in 0..<n {
                for i in 0..<n { T[i] = A[i * W + c] }
                for i in 0..<half {
                    var av = 0.0, dv = 0.0
                    let base = 2 * i
                    for k in 0..<16 {
                        var idx = base + k; if idx >= n { idx -= n }
                        let v = T[idx]
                        av += h[k] * v; dv += g[k] * v
                    }
                    A[i * W + c] = av
                    A[(half + i) * W + c] = dv
                }
            }
        }
    }}}}
}

func bench(_ label: String, _ fn: (inout [Double], inout [Double], Int, Int) -> Void) {
    let W = 512, levels = 5, iters = 100
    let count = W * W
    var input = [Double](repeating: 0, count: count)
    for y in 0..<W {
        for x in 0..<W {
            input[y * W + x] = Double((x * 131 + y * 977) % 251) / 251.0
        }
    }
    var work = [Double](repeating: 0, count: count)
    var tmp = [Double](repeating: 0, count: W)

    for i in 0..<count { work[i] = input[i] }
    fn(&work, &tmp, W, levels) // warm-up

    var times = [Double]()
    var checksum = 0.0
    for it in 0..<iters {
        for i in 0..<count { work[i] = input[i] } // untimed refill
        let t0 = DispatchTime.now().uptimeNanoseconds
        fn(&work, &tmp, W, levels)
        let t1 = DispatchTime.now().uptimeNanoseconds
        times.append(Double(t1 - t0) / 1e6)
        if it == iters - 1 { for v in work { checksum += v } }
    }
    times.sort()
    print(String(format: "%@ %7.3f ms/transform   checksum=%.6f",
                 label, times[times.count / 2], checksum))
}

#if OUNCHECKED
let mode = "-Ounchecked"
#else
let mode = "-O        "
#endif
bench("Swift naive (\(mode))", fwt2dNaive)
bench("Swift tuned (\(mode))", fwt2dTuned)
