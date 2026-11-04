import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import WebSocketKit
@testable import PageCore

/// The relay's WebSocket on Linux: swift-nio and WebSocketKit.
///
/// corelibs Foundation's URLSessionWebSocketTask is built on libcurl's
/// WebSocket support, and Ubuntu 24.04's libcurl (8.5) is built without it:
/// every task fails with "WebSockets not supported by libcurl". So the socket
/// is NIO's, behind RelayClient's `RelayTransport`; the one plain HTTPS POST
/// (retiring a token) still goes through URLSession, which curl does fine.
///
/// HTTPS_PROXY / HTTP_PROXY (and NO_PROXY) are honoured with an HTTP CONNECT
/// tunnel, as URLSession would on macOS. TLS uses the system's trust store.
final class NIORelayTransport: RelayTransport {
    private let queue: DispatchQueue
    private let group: EventLoopGroup
    private let environment: [String: String]
    private let lock = NSLock()
    private var sockets: [NIORelayWebSocket] = []

    init(queue: DispatchQueue, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.queue = queue
        self.group = group
        self.environment = environment
    }

    func makeWebSocket(request: URLRequest, events: RelayWebSocketEvents) -> RelayWebSocket {
        let s = NIORelayWebSocket(request: request, queue: queue, group: group, events: events,
                                  proxy: request.url.flatMap { Self.proxy(for: $0, environment: environment) })
        lock.lock(); sockets.removeAll { $0.finished }; sockets.append(s); lock.unlock()
        return s
    }

    func send(_ request: URLRequest, completion: @escaping (Int, Error?) -> Void) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            completion((response as? HTTPURLResponse)?.statusCode ?? 0, error)
        }.resume()
    }

    func invalidate() {
        lock.lock(); let all = sockets; sockets = []; lock.unlock()
        all.forEach { $0.cancel() }
    }

    struct Proxy: Equatable {
        let host: String
        let port: Int
        /// "Basic …" when the proxy URL carries credentials.
        let authorization: String?
    }

    /// Pure. The proxy for `url` from the usual variables, unless NO_PROXY
    /// covers its host. wss uses HTTPS_PROXY, ws HTTP_PROXY.
    static func proxy(for url: URL, environment env: [String: String]) -> Proxy? {
        guard let host = url.host?.lowercased() else { return nil }
        let secure = url.scheme?.lowercased() == "wss" || url.scheme?.lowercased() == "https"
        let raw = secure ? (env["HTTPS_PROXY"] ?? env["https_proxy"]) : (env["HTTP_PROXY"] ?? env["http_proxy"])
        guard let raw, !raw.isEmpty else { return nil }
        let noProxy = (env["NO_PROXY"] ?? env["no_proxy"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        for entry in noProxy {
            if entry == "*" { return nil }
            let bare = entry.hasPrefix("*.") ? String(entry.dropFirst(1)) : entry
            if host == bare.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || (bare.hasPrefix(".") && host.hasSuffix(bare))
                || (!bare.hasPrefix(".") && host.hasSuffix("." + bare)) {
                return nil
            }
        }
        guard let p = URL(string: raw.contains("://") ? raw : "http://" + raw), let ph = p.host else { return nil }
        var auth: String?
        if let user = p.user {
            let cred = "\(user.removingPercentEncoding ?? user):\((p.password ?? "").removingPercentEncoding ?? "")"
            auth = "Basic " + Data(cred.utf8).base64EncodedString()
        }
        return Proxy(host: ph, port: p.port ?? 80, authorization: auth)
    }
}

/// One connection attempt. All state is confined to `queue` (RelayClient's).
final class NIORelayWebSocket: RelayWebSocket, @unchecked Sendable {
    private let request: URLRequest
    private let queue: DispatchQueue
    private let group: EventLoopGroup
    private weak var events: RelayWebSocketEvents?
    private let proxy: NIORelayTransport.Proxy?

    private var ws: WebSocket?
    private var inbox: [RelayWebSocketMessage] = []
    private var receivers: [(Result<RelayWebSocketMessage, Error>) -> Void] = []
    private var pongWaiters: [(Error?) -> Void] = []
    private var ended = false
    private var cancelled = false

    /// Readable from any thread (the transport prunes finished sockets).
    private let doneLock = NSLock()
    private var done = false
    var finished: Bool { doneLock.lock(); defer { doneLock.unlock() }; return done }
    private func markDone() { doneLock.lock(); done = true; doneLock.unlock() }

    struct Closed: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    init(request: URLRequest, queue: DispatchQueue, group: EventLoopGroup, events: RelayWebSocketEvents,
         proxy: NIORelayTransport.Proxy?) {
        self.request = request
        self.queue = queue
        self.group = group
        self.events = events
        self.proxy = proxy
    }

    func resume() {
        guard let url = request.url, let host = url.host else {
            queue.async { self.fail(Closed(detail: "bad relay URL"), status: nil) }
            return
        }
        let scheme = url.scheme?.lowercased() == "wss" ? "wss" : "ws"
        var headers = HTTPHeaders()
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers.add(name: k, value: v) }
        var proxyHeaders = HTTPHeaders()
        if let auth = proxy?.authorization { proxyHeaders.add(name: "Proxy-Authorization", value: auth) }
        var config = WebSocketClient.Configuration()
        config.maxFrameSize = 1 << 24
        let future = WebSocket.connect(
            scheme: scheme, host: host, port: url.port ?? (scheme == "wss" ? 443 : 80),
            path: url.path.isEmpty ? "/" : url.path, query: url.query, headers: headers,
            proxy: proxy?.host, proxyPort: proxy?.port, proxyHeaders: proxyHeaders,
            proxyConnectDeadline: .now() + .seconds(20),
            configuration: config, on: group
        ) { [weak self] ws in
            self?.queue.async { self?.opened(ws) }
        }
        future.whenFailure { [weak self] error in
            var status: Int?
            if case WebSocketClient.Error.invalidResponseStatus(let head) = error { status = Int(head.status.code) }
            self?.queue.async { self?.fail(error, status: status) }
        }
    }

    /// On `queue`.
    private func opened(_ ws: WebSocket) {
        guard !cancelled, !ended else { _ = ws.close(code: .goingAway); return }
        self.ws = ws
        ws.onText { [weak self] _, text in self?.queue.async { self?.deliver(.string(text)) } }
        ws.onBinary { [weak self] _, buffer in
            let data = Data(buffer.readableBytesView)
            self?.queue.async { self?.deliver(.data(data)) }
        }
        ws.onPong { [weak self] _, _ in
            self?.queue.async {
                guard let self, !self.pongWaiters.isEmpty else { return }
                self.pongWaiters.removeFirst()(nil)
            }
        }
        ws.onClose.whenComplete { [weak self] _ in
            let code = ws.closeCode
            self?.queue.async { self?.closed(code) }
        }
        events?.webSocketDidOpen(self)
    }

    private func deliver(_ message: RelayWebSocketMessage) {
        guard !ended, !cancelled else { return }
        if receivers.isEmpty { inbox.append(message) } else { receivers.removeFirst()(.success(message)) }
    }

    private func closed(_ code: WebSocketErrorCode?) {
        guard !ended, !cancelled else { return }
        let numeric: Int
        switch code {
        case .some(.normalClosure): numeric = 1000
        case .some(.goingAway): numeric = 1001
        case .some(.unknown(let c)): numeric = Int(c)
        case .some(let other): numeric = Int(Self.rawCode(other))
        case .none: numeric = 1006
        }
        finish(Closed(detail: "closed (code \(numeric))"))
        events?.webSocketDidClose(self, code: numeric)
    }

    private static func rawCode(_ code: WebSocketErrorCode) -> UInt16 {
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        return buffer.readInteger(as: UInt16.self) ?? 1006
    }

    private func fail(_ error: Error, status: Int?) {
        guard !ended, !cancelled else { return }
        finish(error)
        events?.webSocketDidComplete(self, error: error, httpStatus: status)
    }

    private func finish(_ error: Error) {
        ended = true
        markDone()
        let rs = receivers, ps = pongWaiters
        receivers = []; pongWaiters = []; inbox = []
        rs.forEach { $0(.failure(error)) }
        ps.forEach { $0(error) }
    }

    // MARK: RelayWebSocket

    func send(_ message: RelayWebSocketMessage, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard let ws = self.ws, !self.ended, !self.cancelled else { completion(Closed(detail: "not connected")); return }
            let promise = ws.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { result in
                if case .failure(let e) = result { completion(e) } else { completion(nil) }
            }
            switch message {
            case .data(let d): ws.send(Array(d), promise: promise)
            case .string(let s): ws.send(s, promise: promise)
            }
        }
    }

    func receive(completion: @escaping (Result<RelayWebSocketMessage, Error>) -> Void) {
        queue.async {
            if self.ended || self.cancelled { completion(.failure(Closed(detail: "closed"))); return }
            if !self.inbox.isEmpty { completion(.success(self.inbox.removeFirst())) } else { self.receivers.append(completion) }
        }
    }

    func sendPing(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard let ws = self.ws, !self.ended, !self.cancelled else { completion(Closed(detail: "not connected")); return }
            self.pongWaiters.append(completion)
            let promise = ws.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { [weak self] e in
                self?.queue.async {
                    guard let self, !self.pongWaiters.isEmpty else { return }
                    self.pongWaiters.removeFirst()(e)
                }
            }
            ws.sendPing(promise: promise)
        }
    }

    /// Asynchronous on `queue`; events already queued are ignored by
    /// RelayClient (it compares sockets by identity).
    func cancel() {
        markDone()
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.receivers = []; self.pongWaiters = []; self.inbox = []
            if let ws = self.ws { _ = ws.close(code: .goingAway) }
            self.ws = nil
        }
    }
}
