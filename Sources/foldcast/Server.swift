import Foundation
import Network

final class Server: @unchecked Sendable {
    private let cfg: Config
    private let state: State
    private let input: Input
    private let manager: DisplayManager
    private let listener: NWListener
    private let q = DispatchQueue(label: "foldcast.server", attributes: .concurrent)

    init(cfg: Config, state: State, input: Input, manager: DisplayManager) throws {
        self.cfg = cfg
        self.state = state
        self.input = input
        self.manager = manager
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params,
                                       on: NWEndpoint.Port(rawValue: cfg.port)!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: q)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: q)
        receive(conn, buffer: Data())
    }

    // Minimal keep-alive HTTP/1.1 request reader.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error { _ = error; conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }

            while let headerEnd = self.range(of: "\r\n\r\n", in: buf) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard let reqLine = lines.first?.split(separator: " "),
                      reqLine.count >= 2 else { conn.cancel(); return }
                let method = String(reqLine[0])
                let rawPath = String(reqLine[1])

                var contentLength = 0
                for l in lines.dropFirst() {
                    let lower = l.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(l.split(separator: ":")[1]
                            .trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }

                let bodyStart = headerEnd.upperBound
                let available = buf.distance(from: bodyStart, to: buf.endIndex)
                if available < contentLength {
                    // Need more bytes for the body; keep reading.
                    self.receive(conn, buffer: buf)
                    return
                }
                let body = Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: contentLength)])
                buf.removeSubrange(buf.startIndex...buf.index(bodyStart,
                                    offsetBy: contentLength).advanced(by: -1))

                if self.route(conn, method: method, rawPath: rawPath, body: body) {
                    return  // streaming route took over the connection
                }
            }
            if isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    /// Returns true if the route hijacked the connection (MJPEG stream).
    private func route(_ conn: NWConnection, method: String,
                       rawPath: String, body: Data) -> Bool {
        let (path, query) = splitQuery(rawPath)
        switch path {
        case "/":
            send(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(viewerHTML.utf8))
        case "/stream":
            startMJPEG(conn)
            return true
        case "/input":
            handleInput(query: query, body: body)
            send(conn, status: "204 No Content", contentType: "text/plain",
                 body: Data())
        case "/ctl":
            applyControl(query: query)
            send(conn, status: "200 OK", contentType: "text/plain",
                 body: Data("rotation=\(state.rotation) mirror=\(state.mirror)".utf8))
        case "/health":
            send(conn, status: "200 OK", contentType: "text/plain",
                 body: Data("ok".utf8))
        default:
            send(conn, status: "404 Not Found", contentType: "text/plain",
                 body: Data("not found".utf8))
        }
        return false
    }

    // MARK: input / control

    private func handleInput(query: [String: String], body: Data) {
        // Accept params from query or urlencoded body.
        var p = query
        if !body.isEmpty,
           let s = String(data: body, encoding: .utf8) {
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    p[String(kv[0])] = String(kv[1])
                        .removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        let kind = p["k"] ?? "move"
        let nx = Double(p["x"] ?? "") ?? 0
        let ny = Double(p["y"] ?? "") ?? 0
        let dy = Double(p["dy"] ?? "") ?? 0
        input.handle(kind: kind, nx: nx, ny: ny, dy: dy)
    }

    private func applyControl(query: [String: String]) {
        if let r = query["rotate"], let v = Int(r) {
            if query["rel"] == "1" { state.rotateBy(v) } else { state.rotation = v }
        }
        if let m = query["mirror"] { state.mirror = (m == "1" || m == "true") }
        // Resize the virtual display to match the phone viewport (no black
        // bars in any orientation). Sent by the viewer on load + rotation.
        if let wS = query["fitw"], let hS = query["fith"],
           let w = Int(wS), let h = Int(hS) {
            let m = manager
            Task.detached { await m.fit(width: w, height: h) }
        }
    }

    // MARK: MJPEG push

    private func startMJPEG(_ conn: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: multipart/x-mixed-replace; boundary=fcframe\r
        Cache-Control: no-cache, no-store\r
        Pragma: no-cache\r
        Connection: close\r
        \r\n
        """
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] e in
            guard let self, e == nil else { conn.cancel(); return }
            self.pushLoop(conn, lastSeq: 0)
        })
    }

    private func pushLoop(_ conn: NWConnection, lastSeq: UInt64) {
        let (jpeg, seq) = state.latest()
        let interval = 1.0 / Double(max(1, cfg.fps))
        if jpeg.isEmpty || seq == lastSeq {
            q.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.pushLoop(conn, lastSeq: lastSeq)
            }
            return
        }
        var part = Data()
        part.append(Data("--fcframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8))
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        conn.send(content: part, completion: .contentProcessed { [weak self] e in
            guard let self else { return }
            if e != nil { conn.cancel(); return }
            self.q.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.pushLoop(conn, lastSeq: seq)
            }
        })
    }

    // MARK: helpers

    private func send(_ conn: NWConnection, status: String,
                      contentType: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in })
    }

    private func range(of needle: String, in data: Data) -> Range<Data.Index>? {
        data.range(of: Data(needle.utf8))
    }

    private func splitQuery(_ raw: String) -> (String, [String: String]) {
        guard let qi = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[..<qi])
        var dict: [String: String] = [:]
        for pair in raw[raw.index(after: qi)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                dict[String(kv[0])] = String(kv[1]).removingPercentEncoding
                    ?? String(kv[1])
            } else if kv.count == 1 {
                dict[String(kv[0])] = ""
            }
        }
        return (path, dict)
    }
}
