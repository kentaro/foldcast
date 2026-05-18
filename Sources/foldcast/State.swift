import Foundation

/// Shared, thread-safe runtime state. Lets the phone flip orientation live
/// (the whole point of the "upside-down" fix being controllable without a rebuild).
final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var _rotation: Int
    private var _mirror: Bool
    private var _latestJPEG: Data = Data()
    private var _frameSeq: UInt64 = 0

    // CGDirectDisplayID of the *current* virtual display. Changes when the
    // display is resized to match the phone's viewport (zero black bars).
    private var _displayID: UInt32
    var displayID: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return _displayID }
        set { lock.lock(); _displayID = newValue; lock.unlock() }
    }

    init(rotation: Int, mirror: Bool, displayID: UInt32) {
        self._rotation = rotation
        self._mirror = mirror
        self._displayID = displayID
    }

    var rotation: Int {
        get { lock.lock(); defer { lock.unlock() }; return _rotation }
        set { lock.lock(); _rotation = ((newValue % 360) + 360) % 360; lock.unlock() }
    }

    var mirror: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _mirror }
        set { lock.lock(); _mirror = newValue; lock.unlock() }
    }

    func publish(_ jpeg: Data) {
        lock.lock()
        _latestJPEG = jpeg
        _frameSeq &+= 1
        lock.unlock()
    }

    /// Returns the latest frame plus its sequence number (so MJPEG loops can
    /// skip re-sending an unchanged frame).
    func latest() -> (Data, UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (_latestJPEG, _frameSeq)
    }

    func rotateBy(_ deg: Int) {
        lock.lock(); _rotation = ((_rotation + deg) % 360 + 360) % 360; lock.unlock()
    }
}
