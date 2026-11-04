import Foundation

/// The wire format of the Page Aura link (docs/AURA-LINK.md, `aura-link-v1`):
/// newline-delimited JSON over a local Unix socket. Everything here is pure
/// so the parsing, encoding and reply rules are testable without a socket.
///
/// Page Aura is the client and Page the server. Readers ignore unknown `t`
/// values and unknown fields; ids are validated and strings clamped, because
/// whatever arrives here ends up on the phone.
enum AuraLink {
    /// A longer line closes the connection (both sides).
    static let maxLineBytes = 256 * 1024
    static let maxIdLength = 64
    /// Page Aura drops a `send` longer than this.
    static let maxSendTextLength = 8000
    /// How long Page waits for the `ack` of a command.
    static let ackTimeout: TimeInterval = 20

    // Clamps for strings that reach the phone.
    static let maxTitleLength = 200
    static let maxModelLength = 100
    static let maxNameLength = 120
    static let maxArgsLength = 1500
    static let maxSnippetLength = 1000
    static let maxDetailLength = 200
    static let maxChats = 200

    // Page Aura chats in the phone's Sessions tab (proto 2, docs/AURA-LINK.md §5).
    /// The first `hello.proto` that sends `chats` / `transcript` and takes `watch`.
    static let sessionsProto = 2
    static let maxRemoteChats = 100
    static let maxPreviewLength = 160
    static let maxTranscriptEntries = 40
    /// Entries read from a `transcript` frame before the last `maxTranscriptEntries` are kept.
    static let maxTranscriptScan = 200
    static let maxEntryTextLength = 4000
    static let maxEntryIdLength = 64
    static let maxToolNameLength = 60
    /// At most this many chats are named in one `watch` (sessions-v1 allows 32 viewers).
    static let maxWatchedChats = 32
    /// The phone's session id for a chat.
    static let sessionPrefix = "aura-"
    /// What a row's `host` says on the phone.
    static let hostName = "Page Aura"

    static let stillReplyingDetail = "Page Aura is still replying"
    static let chatGoneDetail = "That chat no longer exists"
    static let toolRequestWaitingDetail = "A tool request is waiting — answer it first"
    static let photosBlocker = "Page Studio can't send photos to Page Aura yet"
    static let unsupportedDetail = "Page Aura chats don't support that from the phone"
    static let holdDetail = "Page Studio can't hold messages for Page Aura chats — send it when the reply is done"

    static func sessionId(chatId: String) -> String { sessionPrefix + chatId }

    /// The chat id behind a phone session id, or nil when it isn't one.
    static func chatId(sessionId: String) -> String? {
        guard sessionId.hasPrefix(sessionPrefix) else { return nil }
        let id = String(sessionId.dropFirst(sessionPrefix.count))
        return isValidId(id) ? id : nil
    }

    /// What the phone is told for each refusal Page makes itself.
    static let notConnectedDetail = "Page Aura isn't open on your computer"
    static let permissionRepliesDetail = "Page Aura tool requests take Allow or Deny"
    static let chatRepliesDetail = "Page Aura chats take a message, not Allow or Deny"
    static let emptyReplyDetail = "There's nothing to send"
    static let tooLongDetail = "That message is too long for Page Aura"
    static let pageGoneDetail = "That page is no longer open"
    static let requestGoneDetail = "That request was already answered"

    // MARK: Incoming

    struct Hello: Equatable {
        let proto: Int
        let app: String
        let version: String
    }

    struct Approval: Equatable {
        let id: String
        let server: String
        let tool: String
        let args: String
    }

    struct Chat: Equatable {
        let id: String
        let title: String
        let model: String
        let busy: Bool
        /// Epoch ms the current turn started.
        let since: Int64?
        let approval: Approval?
    }

    struct Finished: Equatable {
        let chatId: String
        let title: String
        let ok: Bool
        let stopped: Bool
        let snippet: String
        /// Epoch ms.
        let at: Int64
    }

    struct Ack: Equatable {
        let ref: String
        let ok: Bool
        let detail: String
    }

    /// One row of a `chats` frame (proto 2): the chats the phone may list.
    struct RemoteChat: Equatable {
        let id: String
        let title: String
        let model: String
        /// Epoch ms.
        let updatedAt: Int64?
        let busy: Bool
        let approval: Approval?
        /// The last assistant line, at most 160 characters.
        let preview: String
    }

    struct TranscriptEntry: Equatable {
        enum Role: String { case user, assistant, tool }
        let id: String
        let role: Role
        let text: String
        let tool: String?
        /// Epoch ms.
        let at: Int64?
    }

    /// A `transcript` frame (proto 2): a full snapshot of the chat's last entries.
    struct Transcript: Equatable {
        let chatId: String
        let truncated: Bool
        let entries: [TranscriptEntry]
    }

    enum Message: Equatable {
        case hello(Hello)
        case state([Chat])
        case finished(Finished)
        case ack(Ack)
        case chats([RemoteChat])
        case transcript(Transcript)
    }

    /// `[A-Za-z0-9_-]`, 1...64 characters.
    static func isValidId(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= maxIdLength else { return false }
        return s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
        }
    }

    /// One line (without its newline) to a message, or nil for anything
    /// malformed, unknown or invalid.
    static func decode(line: Data) -> Message? {
        guard line.count <= maxLineBytes,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        switch t {
        case "hello":
            return .hello(Hello(proto: int(obj["proto"]) ?? 0,
                                app: clamp(obj["app"] as? String, 100),
                                version: clamp(obj["version"] as? String, 50)))
        case "state":
            guard let raw = obj["chats"] as? [Any] else { return nil }
            var chats: [Chat] = []
            var seen = Set<String>()
            for case let c as [String: Any] in raw.prefix(maxChats) {
                guard let id = c["id"] as? String, isValidId(id), seen.insert(id).inserted else { continue }
                chats.append(Chat(id: id,
                                  title: clamp(c["title"] as? String, maxTitleLength),
                                  model: clamp(c["model"] as? String, maxModelLength),
                                  busy: (c["busy"] as? Bool) ?? false,
                                  since: int64(c["since"]),
                                  approval: approval(c["approval"])))
            }
            return .state(chats)
        case "finished":
            guard let chatId = obj["chatId"] as? String, isValidId(chatId), let at = int64(obj["at"]) else { return nil }
            return .finished(Finished(chatId: chatId,
                                      title: clamp(obj["title"] as? String, maxTitleLength),
                                      ok: (obj["ok"] as? Bool) ?? false,
                                      stopped: (obj["stopped"] as? Bool) ?? false,
                                      snippet: clamp(obj["snippet"] as? String, maxSnippetLength),
                                      at: at))
        case "ack":
            guard let ref = obj["ref"] as? String, isValidId(ref) else { return nil }
            return .ack(Ack(ref: ref, ok: (obj["ok"] as? Bool) ?? false, detail: clamp(obj["detail"] as? String, maxDetailLength)))
        case "chats":
            guard let raw = obj["chats"] as? [Any] else { return nil }
            var chats: [RemoteChat] = []
            var seen = Set<String>()
            for case let c as [String: Any] in raw.prefix(maxRemoteChats) {
                guard let id = c["id"] as? String, isValidId(id), seen.insert(id).inserted else { continue }
                chats.append(RemoteChat(id: id,
                                        title: clamp(c["title"] as? String, maxTitleLength),
                                        model: clamp(c["model"] as? String, maxModelLength),
                                        updatedAt: int64(c["updatedAt"]),
                                        busy: (c["busy"] as? Bool) ?? false,
                                        approval: approval(c["approval"]),
                                        preview: clamp(c["preview"] as? String, maxPreviewLength)))
            }
            return .chats(chats)
        case "transcript":
            guard let chatId = obj["chatId"] as? String, isValidId(chatId), let raw = obj["entries"] as? [Any] else { return nil }
            var entries: [TranscriptEntry] = []
            for case let e as [String: Any] in raw.prefix(maxTranscriptScan) {
                guard let id = e["id"] as? String, !id.isEmpty, id.count <= maxEntryIdLength,
                      let role = (e["role"] as? String).flatMap(TranscriptEntry.Role.init(rawValue:)) else { continue }
                let tool = role == .tool ? (e["tool"] as? String).map { clamp($0, maxToolNameLength) }.flatMap { $0.isEmpty ? nil : $0 } : nil
                entries.append(TranscriptEntry(id: id, role: role, text: clamp(e["text"] as? String, maxEntryTextLength),
                                               tool: tool, at: int64(e["at"])))
            }
            let kept = entries.suffix(maxTranscriptEntries)
            return .transcript(Transcript(chatId: chatId,
                                          truncated: ((obj["truncated"] as? Bool) ?? false) || entries.count > kept.count,
                                          entries: Array(kept)))
        default:
            return nil
        }
    }

    private static func approval(_ value: Any?) -> Approval? {
        guard let a = value as? [String: Any], let id = a["id"] as? String, isValidId(id) else { return nil }
        return Approval(id: id,
                        server: clamp(a["server"] as? String, maxNameLength),
                        tool: clamp(a["tool"] as? String, maxNameLength),
                        args: clamp(a["args"] as? String, maxArgsLength))
    }

    private static func clamp(_ s: String?, _ max: Int) -> String {
        guard let s else { return "" }
        return s.count > max ? String(s.prefix(max)) : s
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, !n.isJSONBool { return n.intValue }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, !n.isJSONBool else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d < 1e15 else { return nil }
        return n.int64Value
    }

    // MARK: Outgoing

    /// A command's id: `[A-Za-z0-9_-]`, well under 64 characters.
    static func newCommandId() -> String {
        "pg" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func encodeSend(id: String, chatId: String, text: String) -> Data {
        line(["t": "send", "id": id, "chatId": chatId, "text": text])
    }

    /// `decision` is `once` or `deny`; "always allow" is never sent.
    static func encodeApprove(id: String, chatId: String, approvalId: String, decision: String) -> Data {
        line(["t": "approve", "id": id, "chatId": chatId, "approvalId": approvalId, "decision": decision])
    }

    static func encodeStop(id: String, chatId: String) -> Data {
        line(["t": "stop", "id": id, "chatId": chatId])
    }

    /// `list`: a phone has the Sessions view open; `chatIds`: the chats it is
    /// viewing (sorted, so equal sets encode equally).
    static func encodeWatch(list: Bool, chatIds: [String]) -> Data {
        line(["t": "watch", "list": list, "chatIds": chatIds.sorted()])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Sessions tab mapping (docs/AURA-LINK.md §5 "How Page maps it")

    static func date(ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// The phone-facing list state of a chat.
    static func listState(busy: Bool, approval: Bool) -> AgentSessionState {
        approval ? .waitingOnApproval : (busy ? .active : .idle)
    }

    /// Pure. The row's host: only an idle chat takes a message, only a busy one a Stop.
    static func host(for state: AgentSessionState) -> SessionHostInfo {
        SessionHostInfo(host: hostName, canType: state == .idle, typeBlocker: stillReplyingDetail,
                        canInterrupt: state == .active, provider: .anthropic)
    }

    /// Pure. A `transcript` frame as the phone's snapshot: text redacted and
    /// capped like Claude's rows, times as dates, thinking and tool output
    /// never present (Page Aura does not send them).
    static func snapshot(_ t: Transcript) -> SessionTranscript.Snapshot {
        SessionTranscript.Snapshot(
            entries: t.entries.map { e in
                let role: SessionTranscriptEntry.Role
                switch e.role {
                case .user: role = .user
                case .assistant: role = .assistant
                case .tool: role = .tool
                }
                return SessionTranscriptEntry(id: e.id, role: role, text: SessionTranscript.clean(e.text), at: date(ms: e.at), tool: e.tool)
            },
            truncated: t.truncated)
    }

    /// Pure. The list `preview`: redacted, one clipped line.
    static func previewLine(_ raw: String) -> String? {
        let line = raw.split(separator: "\n", omittingEmptySubsequences: true).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return SessionTranscript.clean(line, max: SessionTranscript.previewChars)
    }

    // MARK: Replies

    /// What a phone reply turns into for one kind of page (docs/AURA-LINK.md §4).
    enum ReplyPlan: Equatable {
        case send(String)
        /// `once` or `deny`.
        case approve(String)
        case failure(String)
    }

    static func plan(kind: InterventionKind, reply: RelayReply) -> ReplyPlan {
        switch kind {
        case .permission, .plan:
            switch reply.action {
            case "approve": return .approve("once")
            case "deny": return .approve("deny")
            default: return .failure(permissionRepliesDetail)
            }
        case .idle:
            switch reply.action {
            case "approve", "deny":
                return .failure(chatRepliesDetail)
            case "carry_on":
                return .send("Carry on.")
            default:
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return .failure(emptyReplyDetail) }
                if text.count > maxSendTextLength { return .failure(tooLongDetail) }
                return .send(text)
            }
        case .question, .rateLimit:
            return .failure("Page Aura can't answer that kind of page")
        }
    }
}

/// Splits a byte stream into newline-terminated lines with a size cap.
struct AuraLineBuffer {
    private var buffer = Data()
    let maxLine: Int

    init(maxLine: Int = AuraLink.maxLineBytes) { self.maxLine = maxLine }

    /// The complete lines in `data` (empty lines skipped), or nil when a line
    /// is longer than `maxLine` — the caller closes the connection.
    mutating func append(_ data: Data) -> [Data]? {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineLength = buffer.distance(from: buffer.startIndex, to: nl)
            if lineLength > maxLine { return nil }
            if lineLength > 0 { lines.append(Data(buffer[buffer.startIndex..<nl])) }
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        if buffer.count > maxLine { return nil }
        return lines
    }
}
