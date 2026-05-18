import Foundation

struct Config {
    var width: Int = 1968          // Galaxy Z Fold 7 inner screen (physical px)
    var height: Int = 2184
    var port: UInt16 = 8787
    var jpegQuality: Double = 0.55
    var fps: Int = 30
    var hiDPI: Bool = false
    var rotation: Int = 0          // 0 / 90 / 180 / 270 (clockwise)
    var mirror: Bool = false
    var displayName: String = "FoldCast"

    static func parse(_ args: [String]) -> Config {
        var c = Config()
        var it = args.makeIterator()
        _ = it.next() // argv[0]
        func nextVal(_ cur: String) -> String? {
            if let eq = cur.firstIndex(of: "=") { return String(cur[cur.index(after: eq)...]) }
            return nil
        }
        var pending: String? = nil
        for raw in args.dropFirst() {
            if let key = pending {
                apply(&c, key, raw); pending = nil; continue
            }
            if raw.hasPrefix("--") {
                let body = String(raw.dropFirst(2))
                if let v = nextVal(body) {
                    apply(&c, String(body.prefix(while: { $0 != "=" })), v)
                } else if body == "mirror" {
                    c.mirror = true
                } else if body == "help" || body == "h" {
                    printUsage(); exit(0)
                } else {
                    pending = body
                }
            }
        }
        return c
    }

    private static func apply(_ c: inout Config, _ key: String, _ v: String) {
        switch key {
        case "width":  c.width = Int(v) ?? c.width
        case "height": c.height = Int(v) ?? c.height
        case "port":   c.port = UInt16(v) ?? c.port
        case "quality": c.jpegQuality = Double(v) ?? c.jpegQuality
        case "fps":    c.fps = Int(v) ?? c.fps
        case "hidpi":  c.hiDPI = (v == "1" || v == "true" || v == "yes")
        case "rotate", "rotation": c.rotation = ((Int(v) ?? 0) % 360 + 360) % 360
        case "mirror": c.mirror = (v == "1" || v == "true" || v == "yes")
        case "name":   c.displayName = v
        default: break
        }
    }

    static func printUsage() {
        print("""
        foldcast — turn a USB/Wi-Fi connected Android device into a Mac extended display.

        Usage: foldcast [options]
          --width N        virtual display width  (default 1968)
          --height N       virtual display height (default 2184)
          --port N         HTTP port              (default 8787)
          --fps N          target frame rate      (default 30)
          --quality 0..1   JPEG quality           (default 0.55)
          --rotate D       0|90|180|270 clockwise (default 0)  [fix upside-down here]
          --mirror         horizontally mirror the image
          --hidpi 1        create a HiDPI/Retina virtual display
          --name S         display name           (default FoldCast)

        Orientation can also be changed live from the phone (on-screen buttons)
        or via:  curl -s localhost:PORT/ctl?rotate=180
        """)
    }
}
