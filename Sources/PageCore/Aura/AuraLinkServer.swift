import Foundation

/// What `AuraBackend` needs from the socket, so tests can stand in a fake.
/// The callbacks run on the transport's own queue; set them before `start()`.
protocol AuraLinkTransport: AnyObject {
    var onConnect: (() -> Void)? { get set }
    /// One complete line, without its newline.
    var onLine: ((Data) -> Void)? { get set }
    /// The current client went away (it closed, misbehaved, or was replaced
    /// by a newer one). Not called for a `stop()`.
    var onDisconnect: (() -> Void)? { get set }
    /// Opens the listener. True when it is listening.
    @discardableResult func start() -> Bool
    /// Closes the listener and the client and removes the socket file.
    func stop()
    /// Queues one line for the client. False when nobody is connected.
    func send(_ line: Data) -> Bool
}

/// The Unix-socket server of the Page Aura link (docs/AURA-LINK.md §1).
///
/// `~/Library/Application Support/ClaudePowerMode/aura.sock` on macOS,
/// `$XDG_DATA_HOME/page/aura.sock` on Linux (`PlatformPaths.support`), mode
/// 0600, one client at a time (a new connection replaces the old one), and
/// only the same user: the peer's uid (`getpeereid`, `SO_PEERCRED` on Linux)
/// must be our own. All socket work happens on
/// one private serial queue; sockets are non-blocking.
final class AuraLinkServer: AuraLinkTransport, @unchecked Sendable {
    static var defaultPath: String { path(socketName: "aura.sock") }

    /// `<support>/<name>`: `aura.sock` for Page Aura, `orbit.sock` for Page Orbit.
    /// `PlatformPaths.support` is ~/Library/Application Support/ClaudePowerMode
    /// on macOS and $XDG_DATA_HOME/page (~/.local/share/page) on Linux.
    static func path(socketName: String) -> String {
        Platform.current.paths.support.appendingPathComponent(socketName).path
    }

    /// `sun_path` is 104 bytes on macOS (108 on Linux), with the terminating NUL.
    static let maxPathBytes = LocalSocket.maxPathBytes
    /// A client that stops reading is dropped rather than buffered forever.
    static let maxOutputBytes = 1 << 20

    var onConnect: (() -> Void)?
    var onLine: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    let path: String
    private let queue = DispatchQueue(label: "ClaudePowerMode.aura.link", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    // Queue-confined.
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var client: Client?

    private final class Client {
        let fd: Int32
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var lines = AuraLineBuffer()
        var output = Data()
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    init(path: String = AuraLinkServer.defaultPath) {
        self.path = path
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    // MARK: lifecycle

    @discardableResult
    func start() -> Bool { onQueue { startLocked() } }

    func stop() { onQueue { stopLocked() } }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    private func startLocked() -> Bool {
        if listenFD >= 0 { return true }
        guard path.utf8.count <= Self.maxPathBytes else {
            Logger.shared.log("AuraLink: socket path too long (\(path.utf8.count) bytes) — not listening")
            return false
        }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            #if os(macOS)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            #else
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            #endif
        } catch {
            Logger.shared.log("AuraLink: can't create \(dir): \(error.localizedDescription)")
            return false
        }
        unlink(path) // a stale socket from a crashed run
        let fd = LocalSocket.makeStream()
        guard fd >= 0 else {
            Logger.shared.log("AuraLink: socket() failed (errno \(errno))")
            return false
        }
        Self.configure(fd)
        let bound = LocalSocket.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else {
            Logger.shared.log("AuraLink: bind failed (errno \(errno))")
            LocalSocket.close(fd)
            return false
        }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else {
            Logger.shared.log("AuraLink: listen failed (errno \(errno))")
            LocalSocket.close(fd)
            unlink(path)
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReady() }
        source.setCancelHandler { LocalSocket.close(fd) }
        listenFD = fd
        listenSource = source
        source.resume()
        Logger.shared.log("AuraLink: listening on \(path)")
        return true
    }

    private func stopLocked() {
        if let c = client {
            client = nil
            closeClient(c)
        }
        if let source = listenSource {
            listenSource = nil
            listenFD = -1
            source.cancel()
            unlink(path)
            Logger.shared.log("AuraLink: stopped")
        }
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        LocalSocket.disableSigPipe(fd)
    }

    // MARK: accepting

    private func acceptReady() {
        while listenFD >= 0 {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: nothing more to accept
            }
            guard let uid = LocalSocket.peerUID(cfd), uid == getuid() else {
                Logger.shared.log("AuraLink: refused a connection from another user")
                LocalSocket.close(cfd)
                continue
            }
            Self.configure(cfd)
            if let old = client {
                client = nil
                closeClient(old)
                onDisconnect?()
            }
            let c = Client(fd: cfd)
            let source = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            source.setEventHandler { [weak self, weak c] in
                guard let self, let c else { return }
                self.readReady(c)
            }
            source.setCancelHandler { LocalSocket.close(cfd) }
            c.readSource = source
            client = c
            source.resume()
            Logger.shared.log("AuraLink: client connected on \((path as NSString).lastPathComponent)")
            onConnect?()
        }
    }

    // MARK: reading

    private func readReady(_ c: Client) {
        guard client === c, !c.closed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            drop(c, why: "read error \(errno)")
            return
        }
        if n == 0 {
            drop(c, why: "closed by Page Aura")
            return
        }
        guard let lines = c.lines.append(Data(chunk[0..<n])) else {
            drop(c, why: "a line longer than \(AuraLink.maxLineBytes) bytes")
            return
        }
        for line in lines {
            guard client === c, !c.closed else { return }
            onLine?(line)
        }
    }

    /// The client is gone (or must go): close it and tell the backend.
    private func drop(_ c: Client, why: String) {
        guard client === c else { return }
        client = nil
        closeClient(c)
        Logger.shared.log("AuraLink: Page Aura disconnected (\(why))")
        onDisconnect?()
    }

    private func closeClient(_ c: Client) {
        guard !c.closed else { return }
        c.closed = true
        c.writeSource?.cancel()
        c.writeSource = nil
        // The read source's cancel handler closes the descriptor.
        c.readSource?.cancel()
        c.readSource = nil
    }

    // MARK: writing

    func send(_ line: Data) -> Bool {
        onQueue {
            guard let c = client, !c.closed else { return false }
            c.output.append(line)
            flush(c)
            return client === c && !c.closed
        }
    }

    private func flush(_ c: Client) {
        while !c.output.isEmpty {
            let n = c.output.withUnsafeBytes { LocalSocket.write(c.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                c.output.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                break
            } else {
                drop(c, why: "write error \(errno)")
                return
            }
        }
        if c.output.count > Self.maxOutputBytes {
            drop(c, why: "not reading")
            return
        }
        if c.output.isEmpty {
            c.writeSource?.cancel()
            c.writeSource = nil
        } else if c.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: queue)
            source.setEventHandler { [weak self, weak c] in
                guard let self, let c, self.client === c, !c.closed else { return }
                self.flush(c)
            }
            c.writeSource = source
            source.resume()
        }
    }
}
