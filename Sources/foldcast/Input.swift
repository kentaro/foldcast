import CoreGraphics
import Foundation

/// Injects pointer events into the *real* virtual display so touches on the
/// phone behave like a mouse on that extended desktop — including press-move-
/// release window dragging, right-click and scroll.
final class Input: @unchecked Sendable {
    private let state: State
    private let baseW: Int   // un-rotated virtual display pixel size
    private let baseH: Int
    private let lock = NSLock()
    private var dragging = false
    private var lastPoint = CGPoint.zero

    init(state: State, width: Int, height: Int) {
        self.state = state
        self.baseW = width
        self.baseH = height
    }

    /// Global-coordinate frame of the virtual display (points, top-left origin).
    private var bounds: CGRect { CGDisplayBounds(state.displayID) }

    /// Map a normalized point on the *phone-visible* image (after rotation/
    /// mirror) back to a global coordinate inside the virtual display.
    private func globalPoint(nx: Double, ny: Double) -> CGPoint {
        var x = min(max(nx, 0), 1)
        var y = min(max(ny, 0), 1)

        if state.mirror { x = 1 - x }
        switch state.rotation {       // invert the clockwise display rotation
        case 90:  (x, y) = (y, 1 - x)
        case 180: (x, y) = (1 - x, 1 - y)
        case 270: (x, y) = (1 - y, x)
        default:  break
        }

        let b = bounds
        return CGPoint(x: b.origin.x + x * b.size.width,
                       y: b.origin.y + y * b.size.height)
    }

    private func post(_ type: CGEventType, _ p: CGPoint,
                      button: CGMouseButton = .left, scrollY: Int32 = 0) {
        let ev: CGEvent?
        if type == .scrollWheel {
            ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                         wheelCount: 1, wheel1: scrollY, wheel2: 0, wheel3: 0)
            ev?.location = p
        } else {
            ev = CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: p, mouseButton: button)
        }
        ev?.post(tap: .cghidEventTap)
    }

    /// kind: move | down | up | drag | rightclick | scroll | tap
    func handle(kind: String, nx: Double, ny: Double, dy: Double = 0) {
        let p = globalPoint(nx: nx, ny: ny)
        lock.lock(); defer { lock.unlock() }
        lastPoint = p

        switch kind {
        case "move":
            post(dragging ? .leftMouseDragged : .mouseMoved, p)
        case "down":
            dragging = true
            post(.mouseMoved, p)
            post(.leftMouseDown, p)
        case "drag":
            dragging = true
            post(.leftMouseDragged, p)
        case "up":
            post(.leftMouseUp, p)
            dragging = false
        case "tap":
            post(.mouseMoved, p)
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            dragging = false
        case "rightclick":
            post(.rightMouseDown, p, button: .right)
            post(.rightMouseUp, p, button: .right)
        case "scroll":
            post(.scrollWheel, p, scrollY: Int32(dy))
        default:
            break
        }
    }
}
