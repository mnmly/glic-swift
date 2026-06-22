import CGlic
import CoreGraphics
import CoreImage
import CxxStdlib
import Foundation
import Observation

// Picker option tables (name, raw value matching config.hpp enums).
enum Options {
    static let colorSpaces: [(String, Int)] = [
        ("HWB", 9), ("RGB", 1), ("YUV", 15), ("HSB", 3), ("LAB", 8),
        ("OHTA", 0), ("YCbCr", 12), ("XYZ", 4), ("CMY", 2),
    ]
    static let predictions: [(String, Int)] = [
        ("PAETH", 9), ("NONE", 0), ("MEDIAN", 6), ("AVG", 7), ("TRUEMOTION", 8),
        ("JPEGLS", 12), ("SPIRAL", 16), ("WAVE", 20), ("GRADIENT", 18),
        ("RADIAL", 22), ("CHECKERBOARD", 21), ("RANDOM", -3),
    ]
    static let tiles: [(String, Int)] = [
        ("128", 128), ("256", 256), ("512", 512), ("Whole image", 0),
    ]
}

enum Source: String, CaseIterable, Sendable { case image = "Image", camera = "Camera" }

@MainActor
@Observable
final class GlicModel {
    // Source / mode
    var source: Source = .image
    var cameraWidth: Int = 320
    var detectMode: DetectMode = .mask   // glitch whole frame / person box / person mask
    var glitchBackground = false         // invert: glitch background instead of person
    var cameraError: String?

    // Displayed images
    var sourceImage: CGImage?
    var displayImage: CGImage?
    var status: String = "Loading…"

    // Codec parameters (drive a debounced round-trip)
    var colorSpace: Int = 9
    var prediction: Int = 9
    var quantization: Double = 25  // HWB washes out toward flat color above ~30
    var threshold: Double = 15
    var tile: Int = 256
    var threads: Int = 6

    // Effect parameters (drive an instant GPU re-render)
    var effects = EffectSettings()

    // Internal state
    private var sourcePx: [UInt32] = []
    private var sourceW = 0
    private var sourceH = 0
    private var decodedCG: CGImage?
    private var codecTask: Task<Void, Never>?
    private var camera: CameraController?
    private var cameraTask: Task<Void, Never>?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() {
        glic.setQuietLogging(true)
        loadSynthetic()
    }

    // MARK: - Source

    func loadSynthetic() {
        let w = 768, h = 512
        var px = [UInt32](repeating: 0, count: w * h)
        var s: UInt32 = 1234
        func cl(_ v: Int) -> UInt32 { UInt32(min(255, max(0, v))) }
        for y in 0..<h {
            for x in 0..<w {
                s = s &* 1_664_525 &+ 1_013_904_223
                let n = Int(s & 0x1F) - 16
                let r = (x * 255) / w, g = (y * 255) / h, b = (x ^ y) & 0xFF
                px[y * w + x] = (0xFF << 24) | (cl(r + n) << 16) | (cl(g + n) << 8) | cl(b + n)
            }
        }
        setSourceBuffer(px, w, h)
    }

    func open(url: URL) {
        guard let cg = Pixels.load(url: url) else {
            status = "Failed to load \(url.lastPathComponent)"
            return
        }
        let (px, w, h) = Pixels.toBuffer(cg)
        setSourceBuffer(px, w, h)
    }

    private func setSourceBuffer(_ px: [UInt32], _ w: Int, _ h: Int) {
        if source == .camera { source = .image; stopCamera() }
        sourcePx = px
        sourceW = w
        sourceH = h
        sourceImage = Pixels.toCGImage(px, w, h)
        scheduleCodec()
    }

    // MARK: - Codec loop (debounced, off-main, tiled)

    func scheduleCodec() {
        codecTask?.cancel()
        guard sourceW > 0 else { return }
        status = "Glitching…"

        // Capture only Sendable primitives; build the C++ params inside the task.
        let px = sourcePx, w = sourceW, h = sourceH
        let cs = Int32(colorSpace), pr = Int32(prediction)
        let q = Int32(quantization), th = Float(threshold)
        let tl = Int32(tile), thr = Int32(threads)

        codecTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120)) // debounce slider spam
            if Task.isCancelled { return }

            let t0 = DispatchTime.now().uptimeNanoseconds
            let decoded: [UInt32] = await Task.detached(priority: .userInitiated) {
                var p = glic.StudioParams()
                p.colorSpace = cs
                p.prediction = pr
                p.quantization = q
                p.threshold = th
                p.tile = tl
                p.threads = thr
                return px.withUnsafeBufferPointer { bp in
                    Array(glic.roundTripTiled(bp.baseAddress, Int32(w), Int32(h), p))
                }
            }.value
            let t1 = DispatchTime.now().uptimeNanoseconds
            if Task.isCancelled { return }

            // Already back on the MainActor here (the enclosing Task inherits it).
            self?.finishCodec(decoded, w: w, h: h, ms: Double(t1 - t0) / 1e6)
        }
    }

    private func finishCodec(_ decoded: [UInt32], w: Int, h: Int, ms: Double) {
        decodedCG = Pixels.toCGImage(decoded, w, h)
        applyEffects()
        status = String(format: "%.0f ms · %.1f fps · %@ tiles · %d thr",
                        ms, 1000 / max(ms, 0.01),
                        tile == 0 ? "whole" : "\(tile)px", threads)
    }

    // MARK: - Effects loop (instant, GPU, no codec re-run)

    func applyEffects() {
        guard let base = decodedCG else { return }
        displayImage = Pixels.applyEffects(base, effects, ctx: ciContext)
    }

    // MARK: - Camera mode (live glitch)

    func setSource(_ s: Source) {
        guard s != source else { return }
        source = s
        if s == .camera {
            startCamera()
        } else {
            stopCamera()
            scheduleCodec() // re-render the still image
        }
    }

    func updateCameraSettings() {
        camera?.targetWidth = cameraWidth
        camera?.detectMode = detectMode
    }

    private func startCamera() {
        cameraTask?.cancel()
        cameraError = nil
        status = "Requesting camera…"
        cameraTask = Task { [weak self] in
            guard let self else { return }
            guard await CameraController.authorize() else {
                self.cameraError = "Camera access denied"
                self.status = "Camera access denied"
                self.source = .image
                return
            }
            let cam = CameraController()
            cam.targetWidth = self.cameraWidth
            cam.detectMode = self.detectMode
            self.camera = cam
            do {
                try await cam.start()
            } catch {
                self.cameraError = error.localizedDescription
                self.status = "Camera error: \(error.localizedDescription)"
                self.source = .image
                self.camera = nil
                return
            }
            self.status = "Camera live"
            for await frame in cam.frames {
                if Task.isCancelled { break }
                await self.renderFrame(frame)
            }
        }
    }

    private func stopCamera() {
        cameraTask?.cancel()
        cameraTask = nil
        camera?.stop()
        camera = nil
    }

    // Per-frame glitch: no debounce; the stream's newest-frame-wins buffering
    // means we always process the most recent frame and drop stale ones.
    private func renderFrame(_ f: CameraFrame) async {
        let cs = Int32(colorSpace), pr = Int32(prediction)
        let q = Int32(quantization), th = Float(threshold)
        let tl = Int32(tile), thr = Int32(threads)

        let t0 = DispatchTime.now().uptimeNanoseconds
        let decoded: [UInt32] = await Task.detached(priority: .userInitiated) {
            var p = glic.StudioParams()
            p.colorSpace = cs; p.prediction = pr; p.quantization = q; p.threshold = th
            p.tile = tl; p.threads = thr
            return f.pixels.withUnsafeBufferPointer { bp in
                Array(glic.roundTripTiled(bp.baseAddress, Int32(f.width), Int32(f.height), p))
            }
        }.value
        let t1 = DispatchTime.now().uptimeNanoseconds

        if Task.isCancelled || source != .camera { return }

        // Composite: keep the glitch only inside the detected region (or its
        // inverse), falling back to the original pixels elsewhere.
        var out = decoded
        if let mask = f.mask, mask.count == out.count {
            let inv = glitchBackground
            for i in 0..<out.count where (mask[i] > 127) == inv {
                out[i] = f.pixels[i]
            }
        }
        decodedCG = Pixels.toCGImage(out, f.width, f.height)
        applyEffects()
        let ms = Double(t1 - t0) / 1e6
        status = String(format: "CAM %.0f ms · %.1f fps · %dpx", ms, 1000 / max(ms, 0.01), f.width)
    }
}
