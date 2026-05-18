import Foundation
import CoreGraphics
import CVirtualDisplay

// Lightweight subcommand: a *fresh* process re-evaluates the Screen Recording
// TCC state without ever showing a dialog (CGPreflight never prompts). The
// main process polls this instead of hammering SCStream, which is what made
// the permission dialog reappear over and over.
if CommandLine.arguments.contains("--check-access") {
    print(CGPreflightScreenCaptureAccess() ? "1" : "0")
    exit(0)
}

let cfg = Config.parse(CommandLine.arguments)

let logPath = "/tmp/foldcast.log"
let logFH: FileHandle? = {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    return FileHandle(forWritingAtPath: logPath)
}()
func errln(_ s: String) {
    let d = Data((s + "\n").utf8)
    FileHandle.standardError.write(d)
    logFH?.write(d)
}

errln("[foldcast] creating virtual display \(cfg.width)x\(cfg.height)"
      + (cfg.hiDPI ? " (HiDPI)" : "") + " …")

let state = State(rotation: cfg.rotation, mirror: cfg.mirror, displayID: 0)
let input = Input(state: state, width: cfg.width, height: cfg.height)
let capture = Capture(cfg: cfg, state: state)
let manager = DisplayManager(cfg: cfg, state: state, capture: capture)

let booted = manager.bootstrap()
guard booted else {
    errln("""
    [foldcast] FAILED to create the virtual display.
      • The private CGVirtualDisplay API was unavailable or rejected.
      • This must run as a normal user app (not via ssh/headless).
    """)
    exit(1)
}
errln("[foldcast] virtual display ready — CGDirectDisplayID=\(state.displayID). "
      + "It now appears in System Settings ▸ Displays as a real extended monitor.")

// Spawn a fresh helper process that checks Screen Recording access WITHOUT
// prompting (the running process's own status is cached, so we can't rely on
// it). This is what stops the dialog from reappearing repeatedly.
func screenAccessGranted() -> Bool {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["--check-access"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                   as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s == "1"
}

// Keep the virtual display + server alive no matter what.
Task {
    if !CGPreflightScreenCaptureAccess() {
        errln("[foldcast] requesting Screen Recording permission (ONE prompt)…")
        _ = CGRequestScreenCaptureAccess()
        errln("""
        [foldcast] Approve **FoldCast** in System Settings ▸ Privacy &
        Security ▸ Screen Recording. No need to relaunch and NO repeated
        dialogs — foldcast detects the grant via a fresh helper process and
        starts automatically. The virtual display + server stay up meanwhile.
        """)
    }
    // Poll the non-prompting helper until access is granted.
    while !screenAccessGranted() {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
    // Granted: SCStream now succeeds without any dialog. Retry only transient
    // startup races (virtual display still registering, etc.).
    for _ in 0..<40 {
        do {
            try await manager.startCapture()
            errln("[foldcast] live. The Z Fold 7 now shows this extended display.")
            return
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    errln("[foldcast] capture failed to start after permission was granted.")
}

// Auto-resume if the system tears the capture down — most commonly the user
// hitting "Stop Sharing" in the macOS Screen-Recording menu. Without this the
// phone freezes on the last frame and looks hung. Guarded so we never stack
// restarts or busy-loop.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true; return true
    }
    func end() { lock.lock(); busy = false; lock.unlock() }
}
let resumeGate = ResumeGate()
capture.onStop = {
    guard resumeGate.begin() else { return }
    errln("[foldcast] capture was stopped externally — auto-resuming…")
    Task {
        try? await Task.sleep(nanoseconds: 700_000_000)
        var ok = false
        for _ in 0..<60 {
            if !screenAccessGranted() {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            do { try await manager.startCapture(); ok = true; break }
            catch { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        errln(ok ? "[foldcast] capture resumed."
                 : "[foldcast] auto-resume failed; will retry on next event.")
        resumeGate.end()
    }
}

let server: Server
do {
    server = try Server(cfg: cfg, state: state, input: input, manager: manager)
    server.start()
} catch {
    errln("[foldcast] server failed to bind port \(cfg.port): \(error)")
    exit(1)
}

// Auto-wire USB: if an Android device is attached, forward the port over adb.
func setupADBReverse() {
    let adb = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "adb"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "adb"
    let chk = Process()
    chk.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    chk.arguments = [adb, "get-state"]
    let pipe = Pipe(); chk.standardOutput = pipe; chk.standardError = Pipe()
    try? chk.run(); chk.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                     as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard out == "device" else { return }
    let rev = Process()
    rev.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    rev.arguments = [adb, "reverse", "tcp:\(cfg.port)", "tcp:\(cfg.port)"]
    try? rev.run(); rev.waitUntilExit()
    if rev.terminationStatus == 0 {
        errln("[foldcast] adb reverse set — open this on the Z Fold 7 browser:")
        errln("           ┌────────────────────────────────────┐")
        errln("           │  http://localhost:\(cfg.port)/  (USB)        │")
        errln("           └────────────────────────────────────┘")
    }
}
setupADBReverse()

func lanIP() -> String? {
    var addr: String?
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        let f = cur.pointee
        if f.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: f.ifa_name)
            if name == "en0" || name == "en1" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { addr = ip }
            }
        }
        p = f.ifa_next
    }
    freeifaddrs(ifap)
    return addr
}

if let ip = lanIP() {
    errln("[foldcast] Wi-Fi mode — same network, open on the phone browser:")
    errln("           http://\(ip):\(cfg.port)/")
}

// Advertise over Bonjour so the Fold app auto-discovers us by name — the
// connection survives a DHCP/IP change with zero manual reconfiguration.
final class BonjourDelegate: NSObject, NetServiceDelegate, @unchecked Sendable {
    func netServiceDidPublish(_ s: NetService) {
        errln("[foldcast] Bonjour published: \(s.name)._foldcast._tcp "
              + "(phone finds it automatically even if the IP changes)")
    }
    func netService(_ s: NetService, didNotPublish e: [String: NSNumber]) {
        errln("[foldcast] Bonjour publish failed: \(e) — use the LAN IP manually")
    }
}
let bonjourDelegate = BonjourDelegate()
let serviceName = (Host.current().localizedName ?? "FoldCast")
let bonjour = NetService(domain: "", type: "_foldcast._tcp.",
                         name: serviceName, port: Int32(cfg.port))
bonjour.delegate = bonjourDelegate
bonjour.schedule(in: .main, forMode: .common)
bonjour.publish()

errln("[foldcast] running. Ctrl-C to quit (removes the virtual display).")

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
atexit { /* process exit drops the CGVirtualDisplay automatically */ }

// Run the main CFRunLoop (NOT dispatchMain): the OS responsiveness check is
// serviced (no "Not Responding" in Activity Monitor) and NetService's
// .main run-loop scheduling for Bonjour actually works. Capture/server run
// on their own dispatch queues, so this changes nothing functionally.
RunLoop.main.run()
