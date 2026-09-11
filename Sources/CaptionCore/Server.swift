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

    public init(port: UInt16 = 8420, page: String) throws {
        self.port = port
        self.page = page
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
                                listening: Bool, warning: String?) {
        var obj: [String: Any] = [
            "kind": "status", "level": level, "device": device,
            "language": language, "listening": listening,
            "viewers": viewerCount,
        ]
        if let warning { obj["warning"] = warning }
        send(obj)
    }

    public func broadcast(_ event: CaptionEvent) {
        let obj: [String: Any] = [
            "kind": event.kind.rawValue,
            "en": event.english,
            "tr": event.translation,
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
                let s = String(cString: host)
                if !s.isEmpty, s != "127.0.0.1" { out.append(s) }
            }
        }
        return out
    }
}
