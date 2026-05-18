@preconcurrency import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let cfg: Config
    private let state: State
    private var stream: SCStream?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "foldcast.capture")
    private var lastEmit = Date.distantPast

    /// Called when the system tears the stream down (e.g. the user clicks
    /// "Stop Sharing" in the macOS Screen-Recording menu). Used to auto-resume
    /// — an extended display is useless if it freezes.
    var onStop: (@Sendable () -> Void)?
    private var stopping = false   // suppress onStop during our own restarts

    init(cfg: Config, state: State) {
        self.cfg = cfg
        self.state = state
    }

    func stop() async {
        stopping = true
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        stopping = false
    }

    /// Capture the virtual display at its exact pixel resolution so the phone
    /// gets a 1:1, letterbox-free image.
    func start(pixelWidth: Int, pixelHeight: Int) async throws {
        await stop()
        // The virtual display can take a moment to register with WindowServer.
        var target: SCDisplay?
        for attempt in 0..<60 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            if let d = content.displays.first(where: { $0.displayID == state.displayID }) {
                target = d
                break
            }
            if attempt == 0 {
                FileHandle.standardError.write(
                    Data("[foldcast] waiting for virtual display to register…\n".utf8))
            }
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        guard let display = target else {
            throw NSError(domain: "foldcast", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "virtual display \(state.displayID) not visible to ScreenCaptureKit"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let conf = SCStreamConfiguration()
        conf.width = pixelWidth
        conf.height = pixelHeight
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, cfg.fps)))
        conf.queueDepth = 6
        conf.showsCursor = true
        conf.colorSpaceName = CGColorSpace.sRGB

        let s = SCStream(filter: filter, configuration: conf, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        self.stream = s
        let msg = "[foldcast] capturing display \(state.displayID) "
            + "(\(conf.width)x\(conf.height) @\(cfg.fps)fps)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = sampleBuffer.imageBuffer else { return }

        // Drop frames whose contentRect status is not "complete" (skip dirty/idle).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        var image = CIImage(cvPixelBuffer: pb)
        image = oriented(image, rotation: state.rotation, mirror: state.mirror)

        guard let jpeg = ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        cfg.jpegQuality]) else { return }

        state.publish(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            Data("[foldcast] stream stopped: \(error.localizedDescription)\n".utf8))
        self.stream = nil
        if !stopping { onStop?() }   // not our own teardown → auto-resume
    }

    /// Apply clockwise rotation + optional horizontal mirror so the phone
    /// shows the desktop the right way up regardless of how it's propped.
    private func oriented(_ img: CIImage, rotation: Int, mirror: Bool) -> CIImage {
        let o: CGImagePropertyOrientation
        switch (rotation, mirror) {
        case (90, false):  o = .right
        case (180, false): o = .down
        case (270, false): o = .left
        case (0, true):    o = .upMirrored
        case (90, true):   o = .rightMirrored
        case (180, true):  o = .downMirrored
        case (270, true):  o = .leftMirrored
        case (0, false):   o = .up
        default:           o = .up
        }
        let out = img.oriented(o)
        // Re-base extent to the origin so the JPEG has no offset.
        return out.transformed(by: CGAffineTransform(
            translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }
}
