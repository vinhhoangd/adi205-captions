import Foundation
import Network

/// Serves the caption page and pushes caption events to every viewer.
///
/// Server-sent events rather than WebSocket: captions only ever travel one way,
/// and SSE needs no handshake, no frame masking and no client library — a plain
/// `<script>` on the other laptops is enough. On a LAN this costs about 10 ms,
/// which is not worth optimising against a budget measured in seconds.
public final class CaptionServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "captions.server")
    private var viewers: [NWConnection] = []
    private let lock = NSLock()
    public let port: UInt16
    private let page: String
    /// Called with "start" or "pause" when a viewer presses the button.
    /// Plain GET so the page needs no CORS preflight and no request body.
    public var onControl: ((String) -> Void)?
    /// Reports which language a viewer has selected, so only that one is
    /// translated. "all" means every configured language.
    public var onViewing: ((String) -> Void)?

    /// When set, every request must carry `?k=<token>`. Unset is fine on a
    /// trusted LAN; it is NOT fine behind a public tunnel, where an open
    /// /control/start would let any stranger switch on the microphone.
    private let accessToken: String?

    public init(port: UInt16 = 8420, page: String, accessToken: String? = nil) throws {
        self.port = port
        self.page = page
        self.accessToken = accessToken
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw CaptionError.setup("bad port \(port)")
        }
        listener = try NWListener(using: params, on: p)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receiveRequest(on: conn)
        }
        listener.start(queue: queue)
    }

    private func receiveRequest(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self else { return }
            guard let data, let head = String(data: data, encoding: .utf8), !head.isEmpty else {
                if done { conn.cancel() }
                return
            }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            if let want = self.accessToken, Self.query(path, "k") != want {
                let body = Data("forbidden".utf8)
                let headers = """
                HTTP/1.1 403 Forbidden\r
                Content-Type: text/plain\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r

                """
                var out = Data(headers.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            if path.hasPrefix("/viewing/") {
                let code = String(path.dropFirst("/viewing/".count)).prefix(while: { $0 != "?" })
                self.onViewing?(String(code))
                let body = Data("{\"ok\":true}".utf8)
                var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            if path.hasPrefix("/control/") {
                let action = String(path.dropFirst("/control/".count))
                    .prefix(while: { $0 != "?" })
                self.onControl?(String(action))
                let body = Data("{\"ok\":true}".utf8)
                let headers = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r

                """
                var out = Data(headers.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            if path.hasPrefix("/events") {
                let headers = """
                HTTP/1.1 200 OK\r
                Content-Type: text/event-stream\r
                Cache-Control: no-cache\r
                Connection: keep-alive\r
                Access-Control-Allow-Origin: *\r
                \r

                """
                conn.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })
                self.lock.lock(); self.viewers.append(conn); self.lock.unlock()
                // Drop the viewer as soon as the connection dies. Waiting for a
                // send to fail leaves closed tabs on the list, which inflates the
                // reported viewer count and wastes a write per caption.
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed:
                        guard let self else { return }
                        self.lock.lock()
                        self.viewers.removeAll { $0 === conn }
                        self.lock.unlock()
                    default: break
                    }
                }
            } else {
                let body = Data(self.page.utf8)
                let headers = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r

                """
                var out = Data(headers.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    /// Pushes a health snapshot to every viewer. Without this the page cannot
    /// distinguish "nobody is speaking" from "the microphone is dead", which is
    /// exactly the confusion a silent Bluetooth headset caused.
    public func broadcastStatus(level: Double, device: String, language: String,
                                listening: Bool, warning: String?,
                                devices: [[String: Any]] = []) {
        var obj: [String: Any] = [
            "kind": "status", "level": level, "device": device,
            "language": language, "capturing": listening,
            "viewers": viewerCount, "devices": devices,
        ]
        if let warning { obj["warning"] = warning }
        send(obj)
    }

    public func broadcast(_ event: CaptionEvent) {
        let obj: [String: Any] = [
            "kind": event.kind.rawValue,
            "id": event.id,
            "en": event.english,
            "tr": event.translations,   // keyed by language code
            "latencyMS": Int(event.latency.isFinite ? event.latency * 1000 : 0),
            "corrected": event.corrected,
            "confidence": event.confidence,
        ]
        send(obj)
    }

    private func send(_ obj: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: json, encoding: .utf8) else { return }
        let frame = Data("data: \(s)\n\n".utf8)

        lock.lock(); let targets = viewers; lock.unlock()
        for c in targets {
            c.send(content: frame, completion: .contentProcessed { [weak self] err in
                guard err != nil, let self else { return }
                self.lock.lock()
                self.viewers.removeAll { $0 === c }
                self.lock.unlock()
                c.cancel()
            })
        }
    }

    /// Reads one query parameter out of a request path.
    static func query(_ path: String, _ name: String) -> String? {
        guard let q = path.firstIndex(of: "?") else { return nil }
        for pair in path[path.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    public var viewerCount: Int {
        lock.lock(); defer { lock.unlock() }; return viewers.count
    }

    /// Every non-loopback IPv4 address, so the console can print a URL the other
    /// laptops in the room can actually reach.
    public static func lanAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                               as: UTF8.self)
                if !s.isEmpty, s != "127.0.0.1" { out.append(s) }
            }
        }
        return out
    }
}
