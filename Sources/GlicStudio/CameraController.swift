import AVFoundation
import CoreGraphics
import CoreImage
import Vision

// Where to apply the glitch within the camera frame.
enum DetectMode: String, CaseIterable, Sendable, Hashable {
    case off = "Whole frame"
    case box = "Person box"
    case mask = "Person mask"
}

// One downscaled camera frame as packed ARGB (matches the codec's Color),
// plus an optional person mask (255 = person) aligned pixel-for-pixel with `pixels`.
struct CameraFrame: Sendable {
    let pixels: [UInt32]
    let mask: [UInt8]?
    let width: Int
    let height: Int
}

// Wraps AVCaptureSession + Vision and emits downscaled frames as an AsyncStream.
// `.bufferingNewest(1)` means a slow consumer (the codec) always gets the latest
// frame and stale ones are dropped — natural backpressure for live glitching.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let frames: AsyncStream<CameraFrame>
    private let continuation: AsyncStream<CameraFrame>.Continuation

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.mnmly.glicstudio.camera")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let rgb = CGColorSpaceCreateDeviceRGB()

    // Vision requests (reused across frames; only touched on `queue`).
    private let humanRequest = VNDetectHumanRectanglesRequest()
    private let segRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast // real-time
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    // Codec processing width: smaller = faster + chunkier glitch. Set before start().
    var targetWidth: Int = 320
    // Region detection mode. Updated live from the model.
    var detectMode: DetectMode = .off

    override init() {
        var cont: AsyncStream<CameraFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        super.init()
    }

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure()
                    self.session.startRunning()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
        continuation.finish()
    }

    private func configure() throws {
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw NSError(domain: "GlicCamera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "GlicCamera", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        // Use the highest source resolution the camera supports (so `targetWidth`
        // up to ~1280 isn't upscaled). Falls back gracefully on older cameras.
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high, .vga640x480]
        where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let src = CIImage(cvPixelBuffer: pb)
        let srcExtent = src.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return }

        let w = max(16, targetWidth)
        let scale = CGFloat(w) / srcExtent.width
        let h = max(1, Int((srcExtent.height * scale).rounded()))

        // Frame pixels (codec input).
        let scaledSrc = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var px = [UInt32](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { raw in
            ci.render(scaledSrc, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                      bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .BGRA8, colorSpace: rgb)
        }

        // Person mask (optional). Built in source-CIImage space, then rendered to
        // WxH with the SAME convention as the frame, so it aligns pixel-for-pixel.
        var mask: [UInt8]? = nil
        if detectMode != .off, let maskCI = detect(pb, srcExtent: srcExtent) {
            mask = renderMask(maskCI, toWidth: w, height: h)
        }

        continuation.yield(CameraFrame(pixels: px, mask: mask, width: w, height: h))
    }

    // Returns a mask CIImage (white = person) in source-image coordinate space.
    private func detect(_ pb: CVPixelBuffer, srcExtent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        switch detectMode {
        case .mask:
            guard (try? handler.perform([segRequest])) != nil,
                  let obs = segRequest.results?.first else { return nil }
            return CIImage(cvPixelBuffer: obs.pixelBuffer)
        case .box:
            guard (try? handler.perform([humanRequest])) != nil else { return nil }
            let rects = (humanRequest.results ?? []).map {
                VNImageRectForNormalizedRect($0.boundingBox, Int(srcExtent.width), Int(srcExtent.height))
            }
            if rects.isEmpty { return nil }
            var img = CIImage(color: .black).cropped(to: srcExtent)
            for r in rects {
                img = CIImage(color: .white).cropped(to: r).composited(over: img)
            }
            return img
        case .off:
            return nil
        }
    }

    private func renderMask(_ maskCI: CIImage, toWidth w: Int, height h: Int) -> [UInt8] {
        let ext = maskCI.extent
        guard ext.width > 0, ext.height > 0 else { return [UInt8](repeating: 0, count: w * h) }
        let scaled = maskCI.transformed(
            by: CGAffineTransform(scaleX: CGFloat(w) / ext.width, y: CGFloat(h) / ext.height))
        var m = [UInt8](repeating: 0, count: w * h)
        m.withUnsafeMutableBytes { raw in
            ci.render(scaled, toBitmap: raw.baseAddress!, rowBytes: w,
                      bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .R8, colorSpace: nil)
        }
        return m
    }
}
