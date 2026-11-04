import Foundation

// A reply to a page that the Mac could not type because the session's input box had text in it.
//
// The Mac says so in `reply.injected`'s `reason` (`draft`, or `input_unverified` when it could not see the box),
// which the relay passes on as the reply's `deliveryReason` and in `reply.result`. That frame is not encrypted,
// so it never carries the text: the phone asks for it over the sealed sessions channel (`peekDraft`) and, when the
// Mac reads real text, offers "Clear it and send", the same offer the room makes for a Steer message.
//
// Foundation-only.

/// Reasons a failed reply can carry (`reply.injected` → `reply.result.reason` / the page's `deliveryReason`).
enum ReplyFailureReason {
    static let draft = "draft"
    static let inputUnverified = "input_unverified"
}

enum ReplyRecoveryCopy {
    /// Text is in the box and the phone has not (yet) been told what it is.
    static let unsentText = "There's unsent text in the session's input box on your computer."
    /// The box was emptied meanwhile, so the reply can simply go again.
    static let nowClear = "The input box on your computer is clear now."

    /// The box is clear but the reply could not go (the page changed meanwhile).
    static let couldNotResend = "The input box is clear, but Page Studio couldn't send your message again. Try again from here."

    /// "There's “<draft>” typed in…", cut for display exactly as the room cuts it.
    static func typed(_ draft: String) -> String {
        "There's “\(ClearDraft.shown(draft))” typed in the session's input box on your computer."
    }

    /// What a failed reply says for a `reason` the phone knows; nil means the Mac's own detail stands.
    static func failure(reason: String?) -> String? {
        switch reason {
        case ReplyFailureReason.draft: return unsentText
        case ReplyFailureReason.inputUnverified: return SessionResultCopy.refusal(reason: reason, detail: nil, agent: "")
        default: return nil
        }
    }
}

/// Where "Clear it and send" stands for one failed reply, keyed by its page.
struct ReplyRecovery: Equatable {
    enum Stage: Equatable {
        /// `peekDraft` is out: the unsent-text copy, no button.
        case peeking
        /// Nothing more to offer (the Mac could not read it, didn't answer, or the phone could not ask).
        case unsent
        /// The Mac read this text: "Clear it and send".
        case offer(String)
        /// `clearDraft` is out for this exact text.
        case clearing(String)
        /// The box is empty: "Send again".
        case clear
        /// The reply is going out again.
        case sendingAgain
        /// The clear didn't happen; this is why, in that result's copy.
        case clearFailed(String)
    }

    enum Button: Equatable { case clearAndSend, sendAgain }

    /// When the failure this answers arrived (`APIClient.deliveryTimes`): a newer failure starts over.
    let failedAt: Date
    var stage: Stage
    /// The command whose answer settles the current stage.
    var commandId: String? = nil

    var copy: String {
        switch stage {
        case .peeking, .unsent: return ReplyRecoveryCopy.unsentText
        case .offer(let t), .clearing(let t): return ReplyRecoveryCopy.typed(t)
        case .clear, .sendingAgain: return ReplyRecoveryCopy.nowClear
        case .clearFailed(let why): return why
        }
    }

    var button: Button? {
        switch stage {
        case .offer, .clearing: return .clearAndSend
        case .clear, .sendingAgain: return .sendAgain
        case .peeking, .unsent, .clearFailed: return nil
        }
    }

    /// The button waits while its command is in flight.
    var inFlight: Bool {
        switch stage {
        case .clearing, .sendingAgain: return true
        default: return false
        }
    }

    /// A failure starts a recovery once: `draft` only, only while the phone still holds the reply it would send again,
    /// and not again for a failure it already answered.
    static func shouldStart(reason: String?, failedAt: Date?, hasReply: Bool, existing: ReplyRecovery?) -> Bool {
        guard reason == ReplyFailureReason.draft, hasReply, let failedAt else { return false }
        return existing?.failedAt != failedAt
    }

    /// The Mac's answer to `peekDraft`. Only the text it read, or an empty box, leads anywhere.
    static func afterPeek(_ state: SessionDeliveryState, draft: String?) -> Stage {
        switch state {
        case .typed: return .clear
        case .refused(let reason, _):
            if reason == ReplyFailureReason.draft, let text = ClearDraft.accepted(draft) { return .offer(text) }
            return .unsent
        default: return .unsent
        }
    }

    /// The Mac's answer to `clearDraft`: nil means cleared, so the reply goes again; else why it did not.
    static func afterClear(_ state: SessionDeliveryState) -> Stage? {
        switch state {
        case .typed: return nil
        case .refused(_, let message), .failed(let message): return .clearFailed(message)
        case .noAnswer: return .clearFailed(ClearDraft.notAnswered)
        default: return .clearFailed(SessionResultCopy.failure(reason: nil, detail: nil))
        }
    }
}
