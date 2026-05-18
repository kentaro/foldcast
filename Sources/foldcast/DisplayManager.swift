import Foundation
import CVirtualDisplay

/// Owns the virtual display + capture and resizes the display on demand so it
/// always matches the phone's viewport exactly — no black bars in any
/// orientation, on any client (USB or Wi-Fi). Plain class (no top-level
/// await) so the capture Task + dispatchMain() keep working.
final class DisplayManager: @unchecked Sendable {
    private let cfg: Config
    private let state: State
    private let capture: Capture
    private var vd: FCVirtualDisplay?
    private var curW: Int
    private var curH: Int

    private let lock = NSLock()
    private var fitting = false
    private var pending: (Int, Int)?

    init(cfg: Config, state: State, capture: Capture) {
        self.cfg = cfg
        self.state = state
        self.capture = capture
        self.curW = cfg.width
        self.curH = cfg.height
    }

    private func clamp(_ v: Int) -> Int {
        let x = min(max(v, 640), 3840)
        return x - (x % 2)
    }

    /// Create the initial virtual display (synchronous, called once).
    func bootstrap() -> Bool {
        guard let d = FCVirtualDisplay(width: UInt(curW), height: UInt(curH),
                                       hiDPI: cfg.hiDPI, name: cfg.displayName) else {
            return false
        }
        vd = d
        state.displayID = d.displayID
        return true
    }

    func startCapture() async throws {
        try await capture.start(pixelWidth: curW, pixelHeight: curH)
    }

    /// Resize the virtual display to match the phone viewport. Recreates the
    /// CGVirtualDisplay (its ID changes; input mapping reads it live).
    /// Overlapping requests are coalesced — the last reported size wins.
    func fit(width: Int, height: Int) async {
        let w = clamp(width), h = clamp(height)
        lock.lock()
        if fitting { pending = (w, h); lock.unlock(); return }
        if abs(w - curW) <= 8 && abs(h - curH) <= 8 { lock.unlock(); return }
        fitting = true
        lock.unlock()

        await applyFit(w, h)

        while true {
            lock.lock()
            if let (pw, ph) = pending,
               !(abs(pw - curW) <= 8 && abs(ph - curH) <= 8) {
                pending = nil
                lock.unlock()
                await applyFit(clamp(pw), clamp(ph))
            } else {
                pending = nil
                fitting = false
                lock.unlock()
                break
            }
        }
    }

    private func applyFit(_ w: Int, _ h: Int) async {
        FileHandle.standardError.write(Data(
            "[foldcast] resizing display \(curW)x\(curH) → \(w)x\(h)\n".utf8))

        await capture.stop()
        vd?.invalidate()
        vd = nil
        // Brief pause so WindowServer deregisters the old display first.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let target = FCVirtualDisplay(width: UInt(w), height: UInt(h),
                                      hiDPI: cfg.hiDPI, name: cfg.displayName)
        if let d = target {
            vd = d
            curW = w; curH = h
            state.displayID = d.displayID
        } else if let back = FCVirtualDisplay(width: UInt(curW), height: UInt(curH),
                                              hiDPI: cfg.hiDPI, name: cfg.displayName) {
            FileHandle.standardError.write(Data(
                "[foldcast] resize failed; kept previous size\n".utf8))
            vd = back
            state.displayID = back.displayID
        }
        for _ in 0..<8 {
            do { try await startCapture(); break }
            catch { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
    }
}
