import CGlic
import CoreGraphics
import CoreImage
import CxxStdlib
import Foundation
import Observation

// Picker option tables (name, raw value matching config.hpp / effects.hpp enums).
enum Options {
    static let colorSpaces: [(String, Int)] = [
        ("HWB", 9), ("RGB", 1), ("OHTA", 0), ("CMY", 2), ("HSB", 3), ("XYZ", 4),
        ("YXY", 5), ("HCL", 6), ("LUV", 7), ("LAB", 8), ("R-GGB-G", 10),
        ("YPbPr", 11), ("YCbCr", 12), ("YDbDr", 13), ("GS", 14), ("YUV", 15),
    ]
    static let predictions: [(String, Int)] = [
        ("PAETH", 9), ("NONE", 0), ("CORNER", 1), ("H", 2), ("V", 3), ("DC", 4),
        ("DCMEDIAN", 5), ("MEDIAN", 6), ("AVG", 7), ("TRUEMOTION", 8), ("LDIAG", 10),
        ("HV", 11), ("JPEGLS", 12), ("DIFF", 13), ("REF", 14), ("ANGLE", 15),
        ("SPIRAL", 16), ("NOISE", 17), ("GRADIENT", 18), ("MIRROR", 19), ("WAVE", 20),
        ("CHECKERBOARD", 21), ("RADIAL", 22), ("EDGE", 23),
        ("SAD", -1), ("BSAD", -2), ("RANDOM", -3),
    ]
    static let wavelets: [(String, Int)] = [
        ("SYMLET8", 28), ("NONE", 0), ("HAAR", 40), ("DB2", 31), ("DB4", 33),
        ("DB6", 35), ("DB8", 37), ("DB10", 39), ("SYM2", 22), ("SYM4", 24),
        ("SYM6", 26), ("SYM10", 30), ("COIF1", 17), ("COIF3", 19), ("COIF5", 21),
        ("BIOR1.1", 2), ("BIOR2.2", 5), ("BIOR4.4", 14),
    ]
    static let transforms: [(String, Int)] = [("FWT", 0), ("WPT", 1)]
    static let encodings: [(String, Int)] = [
        ("PACKED", 1), ("RAW", 0), ("RLE", 2), ("DELTA", 3), ("XOR", 4), ("ZIGZAG", 5),
    ]
    static let tiles: [(String, Int)] = [
        ("128", 128), ("256", 256), ("512", 512), ("Whole image", 0),
    ]
    static let blocks: [(String, Int)] = [("2", 2), ("4", 4), ("8", 8), ("16", 16), ("32", 32)]
    // EffectType (effects.hpp). 0 = none.
    static let cppEffects: [(String, Int)] = [
        ("None", 0), ("Pixelate", 1), ("Scanline", 2), ("Chromatic", 3), ("Dither", 4),
        ("Posterize", 5), ("Glitch shift", 6), ("DCT corrupt", 7), ("Pixel sort", 8),
        ("Prediction leak", 9),
    ]
    static let sortModes: [(String, Int)] = [
        ("Brightness", 0), ("Hue", 1), ("Saturation", 2), ("Red", 3), ("Green", 4), ("Blue", 5),
    ]
}

enum Source: String, CaseIterable, Sendable { case image = "Image", camera = "Camera" }

// A self-contained, Sendable description of one glitch pass (runs off the main actor).
struct GlitchJob: Sendable {
    var colorSpace: Int32 = 9, prediction: Int32 = 9, quantization: Int32 = 25
    var threshold: Float = 15
    var wavelet: Int32 = 28, transform: Int32 = 0, encoding: Int32 = 1
    var transformScale: Int32 = 20
    var clampMod256: Int32 = 0, minBlock: Int32 = 2, maxBlock: Int32 = 256
    var tile: Int32 = 256, threads: Int32 = 6
    var preset: String?
    var presetsDir: String = ""
    // C++ post-effect (effects.hpp); 0 = none
    var effectType: Int32 = 0, effectIntensity: Int32 = 50, effectBlockSize: Int32 = 16
    var effectLevels: Int32 = 4, effectSortMode: Int32 = 0, effectThreshold: Int32 = 50
    var effectSortVertical: Int32 = 0
    var effectLeak: Float = 0.5
    var effectSeed: UInt32 = 12345
}

// Codec round-trip only (preset or params). Pure, off-main.
func runCodec(_ job: GlitchJob, _ px: [UInt32], _ w: Int, _ h: Int) -> [UInt32] {
    px.withUnsafeBufferPointer { bp -> [UInt32] in
        if let preset = job.preset {
            return Array(glic.roundTripPreset(bp.baseAddress, Int32(w), Int32(h),
                                              std.string(job.presetsDir), std.string(preset),
                                              job.tile, job.threads))
        }
        var p = glic.StudioParams()
        p.colorSpace = job.colorSpace; p.prediction = job.prediction
        p.quantization = job.quantization; p.threshold = job.threshold
        p.wavelet = job.wavelet; p.transform = job.transform; p.encoding = job.encoding
        p.transformScale = job.transformScale
        p.clampMod256 = job.clampMod256; p.minBlock = job.minBlock; p.maxBlock = job.maxBlock
        p.tile = job.tile; p.threads = job.threads
        return Array(glic.roundTripTiled(bp.baseAddress, Int32(w), Int32(h), p))
    }
}

// Apply the selected C++ post-effect (effects.cpp) in place. Pure, off-main.
func applyCppEffect(_ buf: inout [UInt32], _ w: Int, _ h: Int, _ job: GlitchJob) {
    guard job.effectType != 0 else { return }
    buf.withUnsafeMutableBufferPointer { mb in
        glic.applyStudioEffect(mb.baseAddress, Int32(w), Int32(h),
                               job.effectType, job.effectIntensity, job.effectBlockSize,
                               2, 0, job.effectLevels, job.effectSortMode, job.effectThreshold,
                               job.effectSortVertical, job.effectLeak, job.effectSeed)
    }
}

@MainActor
@Observable
final class GlicModel {
    // Source / mode
    var source: Source = .image
    var cameraWidth: Int = 320
    var detectMode: DetectMode = .mask
    var glitchBackground = false
    var cameraError: String?

    // Displayed images
    var sourceImage: CGImage?
    var displayImage: CGImage?
    var status: String = "Loading…"

    // Codec parameters
    var colorSpace: Int = 9
    var prediction: Int = 9
    var quantization: Double = 25
    var threshold: Double = 15
    var wavelet: Int = 28
    var transform: Int = 0
    var transformScale: Double = 20
    var encoding: Int = 1
    var clampMod256 = false
    var minBlock: Int = 2
    var maxBlock: Int = 256
    var tile: Int = 256
    var threads: Int = 6

    // Presets (per-channel configs from Daito's gallery). nil = custom (use params).
    var presetsDir: String = GlicModel.defaultPresetsDir
    var presets: [String] = []
    var selectedPreset: String?

    // C++ post-effect
    var cppEffect: Int = 0
    var cppIntensity: Double = 50
    var cppBlockSize: Int = 16
    var cppLevels: Int = 4
    var cppSortMode: Int = 0
    var cppThreshold: Double = 25   // lower => longer sorted runs => more visible
    var cppSortVertical = false
    var cppLeak: Double = 0.5

    // GPU (Core Image) effects
    var effects = EffectSettings()

    // Internal state
    private var sourcePx: [UInt32] = []
    private var sourceW = 0
    private var sourceH = 0
    private var decodedCG: CGImage?
    private var decodedRaw: [UInt32] = []   // cached codec output, before the C++ effect
    private var decodedW = 0
    private var decodedH = 0
    private var codecTask: Task<Void, Never>?
    private var presentTask: Task<Void, Never>?
    private var camera: CameraController?
    private var cameraTask: Task<Void, Never>?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    static let defaultPresetsDir: String = {
        URL(fileURLWithPath: #filePath)        // .../Sources/GlicStudio/Model.swift
            .deletingLastPathComponent()       // GlicStudio
            .deletingLastPathComponent()       // Sources
            .deletingLastPathComponent()       // repo root
            .appendingPathComponent("presets")
            .path
    }()

    init() {
        glic.setQuietLogging(true)
        loadPresets()
        loadSynthetic()
    }

    // MARK: - Presets

    func loadPresets() {
        var names: [String] = []
        let cxx = glic.listPresets(std.string(presetsDir))
        for s in cxx { names.append(String(s)) }
        presets = names.sorted()
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

    // MARK: - Job

    private func currentJob() -> GlitchJob {
        var j = GlitchJob()
        j.colorSpace = Int32(colorSpace); j.prediction = Int32(prediction)
        j.quantization = Int32(quantization); j.threshold = Float(threshold)
        j.wavelet = Int32(wavelet); j.transform = Int32(transform); j.encoding = Int32(encoding)
        j.transformScale = Int32(transformScale)
        j.clampMod256 = clampMod256 ? 1 : 0
        j.minBlock = Int32(minBlock); j.maxBlock = Int32(maxBlock)
        j.tile = Int32(tile); j.threads = Int32(threads)
        j.preset = selectedPreset
        j.presetsDir = presetsDir
        j.effectType = Int32(cppEffect); j.effectIntensity = Int32(cppIntensity)
        j.effectBlockSize = Int32(cppBlockSize); j.effectLevels = Int32(cppLevels)
        j.effectSortMode = Int32(cppSortMode); j.effectThreshold = Int32(cppThreshold)
        j.effectSortVertical = cppSortVertical ? 1 : 0; j.effectLeak = Float(cppLeak)
        return j
    }

    // MARK: - Codec loop (debounced, off-main)

    func scheduleCodec() {
        codecTask?.cancel()
        guard sourceW > 0, source == .image else { return }
        status = "Glitching…"
        let job = currentJob()
        let px = sourcePx, w = sourceW, h = sourceH

        codecTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let decoded = await Task.detached(priority: .userInitiated) { runCodec(job, px, w, h) }.value
            let t1 = DispatchTime.now().uptimeNanoseconds
            if Task.isCancelled { return }
            self?.finishCodec(decoded, w: w, h: h, ms: Double(t1 - t0) / 1e6)
        }
    }

    private func finishCodec(_ decoded: [UInt32], w: Int, h: Int, ms: Double) {
        decodedRaw = decoded; decodedW = w; decodedH = h
        presentDecoded()
        let label = selectedPreset.map { "preset \($0)" } ?? (tile == 0 ? "whole" : "\(tile)px tiles")
        let fx = cppEffect == 0 ? "" : " · +\(Options.cppEffects.first { $0.1 == cppEffect }?.0 ?? "fx")"
        status = String(format: "%.0f ms · %.1f fps · %@%@", ms, 1000 / max(ms, 0.01), label, fx)
    }

    // Apply the C++ effect to the cached codec output (no codec re-run) and show it.
    // This is what makes toggling a C++ effect instant + clearly visible.
    func presentDecoded() {
        presentTask?.cancel()
        guard !decodedRaw.isEmpty else { return }
        let raw = decodedRaw, w = decodedW, h = decodedH
        let job = currentJob()
        presentTask = Task { [weak self] in
            let out: [UInt32] = await Task.detached(priority: .userInitiated) {
                var buf = raw
                applyCppEffect(&buf, w, h, job)
                return buf
            }.value
            if Task.isCancelled { return }
            self?.decodedCG = Pixels.toCGImage(out, w, h)
            self?.applyEffects()
        }
    }

    // MARK: - GPU (Core Image) effects loop

    func applyEffects() {
        guard let base = decodedCG else { return }
        displayImage = Pixels.applyEffects(base, effects, ctx: ciContext)
    }

    // MARK: - Camera mode

    func setSource(_ s: Source) {
        guard s != source else { return }
        source = s
        if s == .camera { startCamera() } else { stopCamera(); scheduleCodec() }
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

    private func renderFrame(_ f: CameraFrame) async {
        let job = currentJob()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let decoded = await Task.detached(priority: .userInitiated) { () -> [UInt32] in
            var buf = runCodec(job, f.pixels, f.width, f.height)
            applyCppEffect(&buf, f.width, f.height, job)
            return buf
        }.value
        let t1 = DispatchTime.now().uptimeNanoseconds
        if Task.isCancelled || source != .camera { return }

        var out = decoded
        if let mask = f.mask, mask.count == out.count {
            let inv = glitchBackground
            for i in 0..<out.count where (mask[i] > 127) == inv { out[i] = f.pixels[i] }
        }
        decodedCG = Pixels.toCGImage(out, f.width, f.height)
        applyEffects()
        let ms = Double(t1 - t0) / 1e6
        status = String(format: "CAM %.0f ms · %.1f fps · %dpx", ms, 1000 / max(ms, 0.01), f.width)
    }
}
