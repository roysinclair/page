import Foundation

/// What becomes of one `sessions.update` frame's envelope once the session key has been tried on it.
enum SessionFrameOutcome: Equatable {
    /// The envelope doesn't authenticate under the key (carries its size, for the log).
    case undecryptable(bytes: Int)
    /// Decrypted, but not a kind this phone knows, or malformed.
    case unreadable
    case plaintext(SessionsPlaintext)
}

enum SessionFrame {
    /// Decrypts (AES-GCM, with the HKDF subkey) and decodes one frame. Pure, and deliberately not tied to the main
    /// actor: `SessionStore` runs it on a background thread and only applies the result on the main actor.
    nonisolated static func decode(_ envelope: SessionCrypto.Envelope, root: Data) -> SessionFrameOutcome {
        guard let data = SessionCrypto.open(envelope, root: root, direction: .macToPhone, aad: SessionFrameType.update) else {
            return .undecryptable(bytes: envelope.sealed.count)
        }
        guard let plaintext = SessionsPlaintext.decode(data) else { return .unreadable }
        return .plaintext(plaintext)
    }
}

/// Runs `work` on each input off the main actor, one at a time and in the order the inputs were submitted, and
/// hands each result to `deliver` on the main actor in that same order. A frame that arrives while the one before
/// it is still being decrypted waits its turn, so the store sees the frames exactly as the relay sent them.
@MainActor
final class OrderedOffMainPipeline<Input: Sendable, Output: Sendable> {
    private let continuation: AsyncStream<Input>.Continuation

    init(work: @escaping @Sendable (Input) -> Output, deliver: @escaping @MainActor (Output) -> Void) {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        self.continuation = continuation
        Task { @MainActor in
            for await input in stream {
                let output = await Task.detached(priority: .userInitiated) { work(input) }.value
                deliver(output)
            }
        }
    }

    func submit(_ input: Input) { continuation.yield(input) }

    deinit { continuation.finish() }
}
