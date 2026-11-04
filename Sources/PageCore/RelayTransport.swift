import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The relay's WebSocket and its one plain HTTPS request, behind a protocol.
///
/// macOS: URLSession (`URLSessionRelayTransport`, the code RelayClient always
/// used). Linux: corelibs Foundation's URLSessionWebSocketTask needs a libcurl
/// built with WebSocket support, which Ubuntu 24.04's curl 8.5 is not ("WebSockets
/// not supported by libcurl"), so `paged` uses swift-nio's WebSocketKit
/// (Sources/PageLinux/NIORelayTransport.swift).
///
/// Threading: a transport is made for one RelayClient with the client's
/// serial queue (`Platform.makeRelayTransport(queue)`), and every socket
/// callback and event is delivered on that queue.
protocol RelayTransport: AnyObject {
    /// A WebSocket for `request` (URL plus Authorization and User-Agent
    /// headers). Nothing happens until `resume()`.
    func makeWebSocket(request: URLRequest, events: RelayWebSocketEvents) -> RelayWebSocket
    /// One HTTP request (the `relay.retire` POST). `status` is 0 without a response.
    func send(_ request: URLRequest, completion: @escaping (_ status: Int, _ error: Error?) -> Void)
    /// Ends every socket and request; the transport is finished.
    func invalidate()
}

enum RelayWebSocketMessage: Equatable {
    case data(Data)
    case string(String)
}

/// One connection attempt. RelayClient compares sockets by identity.
protocol RelayWebSocket: AnyObject {
    func resume()
    func send(_ message: RelayWebSocketMessage, completion: @escaping (Error?) -> Void)
    /// The next message. Call again after each one.
    func receive(completion: @escaping (Result<RelayWebSocketMessage, Error>) -> Void)
    /// `completion` runs when the pong arrives (nil) or the ping failed.
    func sendPing(completion: @escaping (Error?) -> Void)
    /// Closes with "going away". No events follow.
    func cancel()
}

/// What a socket reports, on the client's queue.
protocol RelayWebSocketEvents: AnyObject {
    func webSocketDidOpen(_ socket: RelayWebSocket)
    func webSocketDidClose(_ socket: RelayWebSocket, code: Int)
    /// The socket failed or ended. `httpStatus` is the upgrade response's
    /// status when the server refused it (410: the token was retired).
    func webSocketDidComplete(_ socket: RelayWebSocket, error: Error?, httpStatus: Int?)
}

struct RelayTransportUnavailable: LocalizedError {
    var errorDescription: String? { "No WebSocket transport on this system" }
}

/// Fails every connection; the default off macOS until a platform installs one.
final class UnavailableRelayTransport: RelayTransport {
    private final class Socket: RelayWebSocket {
        weak var events: RelayWebSocketEvents?
        let queue: DispatchQueue
        init(queue: DispatchQueue, events: RelayWebSocketEvents) { self.queue = queue; self.events = events }
        func resume() {
            queue.async { [self] in events?.webSocketDidComplete(self, error: RelayTransportUnavailable(), httpStatus: nil) }
        }
        func send(_ message: RelayWebSocketMessage, completion: @escaping (Error?) -> Void) { completion(RelayTransportUnavailable()) }
        func receive(completion: @escaping (Result<RelayWebSocketMessage, Error>) -> Void) {}
        func sendPing(completion: @escaping (Error?) -> Void) { completion(RelayTransportUnavailable()) }
        func cancel() {}
    }
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }
    func makeWebSocket(request: URLRequest, events: RelayWebSocketEvents) -> RelayWebSocket {
        Socket(queue: queue, events: events)
    }
    func send(_ request: URLRequest, completion: @escaping (Int, Error?) -> Void) { completion(0, RelayTransportUnavailable()) }
    func invalidate() {}
}

#if canImport(Darwin)
/// URLSession and URLSessionWebSocketTask: the macOS transport, moved out of
/// RelayClient unchanged (same configuration, same delegate callbacks).
final class URLSessionRelayTransport: NSObject, RelayTransport, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private let lock = NSLock()
    /// Live sockets by task, so delegate callbacks find theirs.
    private var sockets: [ObjectIdentifier: Socket] = [:]

    final class Socket: RelayWebSocket {
        let task: URLSessionWebSocketTask
        weak var events: RelayWebSocketEvents?
        init(task: URLSessionWebSocketTask, events: RelayWebSocketEvents) { self.task = task; self.events = events }
        func resume() { task.resume() }
        func send(_ message: RelayWebSocketMessage, completion: @escaping (Error?) -> Void) {
            switch message {
            case .data(let d): task.send(.data(d)) { completion($0) }
            case .string(let s): task.send(.string(s)) { completion($0) }
            }
        }
        func receive(completion: @escaping (Result<RelayWebSocketMessage, Error>) -> Void) {
            task.receive { result in
                switch result {
                case .failure(let e): completion(.failure(e))
                case .success(.data(let d)): completion(.success(.data(d)))
                case .success(.string(let s)): completion(.success(.string(s)))
                case .success: completion(.success(.data(Data())))
                }
            }
        }
        func sendPing(completion: @escaping (Error?) -> Void) { task.sendPing { completion($0) } }
        func cancel() { task.cancel(with: .goingAway, reason: nil) }
    }

    /// `configuration` is for tests (a stub URLProtocol); production uses the
    /// default. Delegate callbacks run on `queue` (RelayClient's).
    init(configuration: URLSessionConfiguration = .default, queue: DispatchQueue) {
        super.init()
        let config = configuration
        // Generous: the 25 s ping keeps traffic flowing well inside it.
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "ClaudePowerMode.relay.delegate"
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func makeWebSocket(request: URLRequest, events: RelayWebSocketEvents) -> RelayWebSocket {
        let task = session.webSocketTask(with: request)
        let socket = Socket(task: task, events: events)
        lock.lock(); sockets[ObjectIdentifier(task)] = socket; lock.unlock()
        return socket
    }

    func send(_ request: URLRequest, completion: @escaping (Int, Error?) -> Void) {
        session.dataTask(with: request) { _, response, error in
            completion((response as? HTTPURLResponse)?.statusCode ?? 0, error)
        }.resume()
    }

    func invalidate() {
        lock.lock()
        sockets.removeAll()
        lock.unlock()
        // Releases the session's strong reference to its delegate (us).
        session.invalidateAndCancel()
    }

    private func socket(for task: URLSessionTask) -> Socket? {
        lock.lock(); defer { lock.unlock() }
        return sockets[ObjectIdentifier(task)]
    }

    private func forget(_ task: URLSessionTask) {
        lock.lock(); sockets[ObjectIdentifier(task)] = nil; lock.unlock()
    }

    // MARK: URLSessionWebSocketDelegate (delivered on the client's queue)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard let s = socket(for: webSocketTask) else { return }
        s.events?.webSocketDidOpen(s)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let s = socket(for: webSocketTask) else { return }
        s.events?.webSocketDidClose(s, code: closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionWebSocketTask, let s = socket(for: task) else { return }
        forget(task)
        s.events?.webSocketDidComplete(s, error: error, httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
    }
}
#endif
