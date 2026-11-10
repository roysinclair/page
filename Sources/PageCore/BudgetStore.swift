import Foundation

// The files behind budget caps (Designs/budget-caps.md). Every directory is
// injected, so tests and `--render-ui` never touch the real support folder.

/// Where budgets keep their files.
struct BudgetFiles {
    /// Page's support folder: the ledger, the caps, the state and the gate's folders.
    var support: URL
    /// Where the status line wrapper writes `<session_id>.json`.
    var statusline: URL

    init(support: URL, statusline: URL? = nil) {
        self.support = support
        self.statusline = statusline ?? support.appendingPathComponent("statusline", isDirectory: true)
    }

    /// The live folders: the support folder, and next to `statusline-input.json`.
    static func live() -> BudgetFiles {
        BudgetFiles(support: Platform.current.paths.support,
                    statusline: UsageCapture().supportDirectory.appendingPathComponent("statusline", isDirectory: true))
    }

    var ledgerURL: URL { support.appendingPathComponent("budget-ledger.json") }
    var sessionCapsURL: URL { support.appendingPathComponent("budget-session-caps.json") }
    var stateURL: URL { support.appendingPathComponent("budget-state.json") }
    /// The gate's folders (`hooks/page-budget-gate.sh` reads them).
    var overDirectory: URL { support.appendingPathComponent("budget-over", isDirectory: true) }
    var allowDirectory: URL { support.appendingPathComponent("budget-allow", isDirectory: true) }

    // MARK: atomic files

    /// Atomic, 0600: a temp file in the same folder, then rename. The folder is made 0700 if missing.
    @discardableResult
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) -> Bool {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, url.path) != 0 {
            try? fileManager.removeItem(at: tmp)
            return false
        }
        return true
    }

    static func read(_ url: URL, maxBytes: Int = 1 << 20) -> Data? { BoundedFileRead.read(url.path, maxBytes: maxBytes) }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    func loadLedger() -> BudgetLedger {
        guard let data = Self.read(ledgerURL), let l = try? Self.decoder().decode(BudgetLedger.self, from: data) else { return BudgetLedger() }
        return l
    }

    @discardableResult
    func save(_ ledger: BudgetLedger) -> Bool {
        guard let data = try? Self.encoder().encode(ledger) else { return false }
        return Self.write(data, to: ledgerURL)
    }

    func loadState() -> BudgetEnforcementState {
        guard let data = Self.read(stateURL), let s = try? Self.decoder().decode(BudgetEnforcementState.self, from: data) else {
            return BudgetEnforcementState()
        }
        return s
    }

    @discardableResult
    func save(_ state: BudgetEnforcementState) -> Bool {
        guard let data = try? Self.encoder().encode(state) else { return false }
        return Self.write(data, to: stateURL)
    }

    func loadSessionCaps() -> BudgetSessionCaps {
        guard let data = Self.read(sessionCapsURL) else { return BudgetSessionCaps() }
        return BudgetSessionCaps.parse(data)
    }

    @discardableResult
    func save(_ caps: BudgetSessionCaps) -> Bool { Self.write(caps.data(), to: sessionCapsURL) }

    // MARK: markers

    /// Writes a marker: the `.json` (for people and Page), then the `.gate`
    /// (what the hook reads), each atomically. False when either failed.
    @discardableResult
    func writeMarker(hash: String, json: Data, gate: String) -> Bool {
        Self.write(json, to: overDirectory.appendingPathComponent(hash + ".json"))
            && Self.write(Data(gate.utf8), to: overDirectory.appendingPathComponent(hash + ".gate"))
    }

    /// A marker's `.gate` text as written, or nil.
    func gateText(hash: String) -> String? {
        try? String(contentsOf: overDirectory.appendingPathComponent(hash + ".gate"), encoding: .utf8)
    }

    /// Removes both files together, the gate first (the hook stops matching at once).
    func removeMarker(hash: String) {
        try? FileManager.default.removeItem(at: overDirectory.appendingPathComponent(hash + ".gate"))
        try? FileManager.default.removeItem(at: overDirectory.appendingPathComponent(hash + ".json"))
    }

    /// The hashes with a file in the marker folder (either kind).
    func markerHashes() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: overDirectory.path)) ?? []
        return Set(names.compactMap { n -> String? in
            guard !n.hasPrefix(".") else { return nil }
            if n.hasSuffix(".gate") { return String(n.dropLast(5)) }
            if n.hasSuffix(".json") { return String(n.dropLast(5)) }
            return nil
        })
    }

    func markerExists(hash: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: overDirectory.appendingPathComponent(hash + ".gate").path)
            && fm.fileExists(atPath: overDirectory.appendingPathComponent(hash + ".json").path)
    }

    /// An allow file: the gate lets this session through while it exists.
    @discardableResult
    func writeAllow(sessionId: String, now: Date) -> Bool {
        let name = BudgetProjectKey.sanitizedSessionId(sessionId)
        guard !name.isEmpty else { return false }
        return Self.write(Data("\(Int(now.timeIntervalSince1970))\n".utf8), to: allowDirectory.appendingPathComponent(name))
    }

    func removeAllow(sessionId: String) {
        let name = BudgetProjectKey.sanitizedSessionId(sessionId)
        guard !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: allowDirectory.appendingPathComponent(name))
    }

    func allowNames() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: allowDirectory.path)) ?? []).filter { !$0.hasPrefix(".") })
    }

    /// Removes every marker and allow file (usage capture is off: nothing is enforced).
    func removeAllMarkersAndAllows() {
        for h in markerHashes() { removeMarker(hash: h) }
        for n in allowNames() { try? FileManager.default.removeItem(at: allowDirectory.appendingPathComponent(n)) }
    }
}

// MARK: - Session caps

/// `budget-session-caps.json` (0600): a cap per session, dropped 8 days after
/// the session was last seen. `{"<session id>": {"pct": 10, "seenAt": <unix seconds>}}`.
struct BudgetSessionCaps: Equatable {
    struct Entry: Equatable {
        var pct: Int
        var seenAt: Date
    }

    var entries: [String: Entry] = [:]

    static let dropAfter: TimeInterval = 8 * 24 * 3600
    /// `seenAt` is only rewritten when it is this stale (the file is not saved every tick).
    static let touchEvery: TimeInterval = 3600

    var caps: [String: Int] { entries.mapValues(\.pct) }

    /// Lenient: an entry that isn't `{pct, seenAt}`, or is out of range, is skipped.
    static func parse(_ data: Data) -> BudgetSessionCaps {
        var out = BudgetSessionCaps()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return out }
        for (id, raw) in obj {
            guard BudgetProjectKey.isSaneSessionId(id), let e = raw as? [String: Any],
                  let n = e["pct"] as? NSNumber, !n.isJSONBool, BudgetPercent.isValid(n.intValue),
                  n.doubleValue == Double(n.intValue) else { continue }
            let seen = (e["seenAt"] as? NSNumber)?.doubleValue ?? 0
            out.entries[id] = Entry(pct: n.intValue, seenAt: Date(timeIntervalSince1970: seen))
        }
        return out
    }

    func data() -> Data {
        var o: [String: Any] = [:]
        for (id, e) in entries { o[id] = ["pct": e.pct, "seenAt": Int(e.seenAt.timeIntervalSince1970)] }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
    }

    mutating func set(_ id: String, pct: Int?, now: Date) {
        if let pct, BudgetPercent.isValid(pct), BudgetProjectKey.isSaneSessionId(id) {
            entries[id] = Entry(pct: pct, seenAt: now)
        } else {
            entries[id] = nil
        }
    }

    /// Marks the sessions seen now still alive (rarely), and drops what has been gone 8 days.
    /// True when anything changed (the file is to be saved).
    mutating func refresh(live: Set<String>, now: Date) -> Bool {
        var changed = false
        for (id, e) in entries {
            if live.contains(id) {
                if now.timeIntervalSince(e.seenAt) >= Self.touchEvery { entries[id]?.seenAt = now; changed = true }
            } else if now.timeIntervalSince(e.seenAt) > Self.dropAfter {
                entries[id] = nil
                changed = true
            }
        }
        return changed
    }
}

// MARK: - Status line files

/// Reads `statusline/<session_id>.json`, only the files that changed since the
/// last scan (by mtime), bounded, and removes the ones nobody has touched for 8 days.
struct BudgetStatusScanner {
    private var seen: [String: Date] = [:]
    private var lastPruneAt: Date = .distantPast

    static let maxBytes = 256 * 1024
    static let pruneEvery: TimeInterval = 3600

    /// New samples, oldest file first, so a later write wins.
    mutating func scan(directory: URL, now: Date, resolve: (String) -> String = BudgetProjectKey.resolveSymlinks) -> [BudgetSample] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let prune = now.timeIntervalSince(lastPruneAt) >= Self.pruneEvery
        if prune { lastPruneAt = now }
        var changed: [(name: String, at: Date)] = []
        var present = Set<String>()
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) > BudgetLedger.closeAfter {
                if prune { try? fm.removeItem(atPath: path) }
                continue
            }
            present.insert(name)
            if seen[name] != mtime { changed.append((name, mtime)) }
        }
        seen = seen.filter { present.contains($0.key) }
        var out: [BudgetSample] = []
        for (name, at) in changed.sorted(by: { $0.at < $1.at }) {
            seen[name] = at
            guard let data = BoundedFileRead.read(directory.appendingPathComponent(name).path, maxBytes: Self.maxBytes),
                  let sample = BudgetSample.parse(data, at: at, resolve: resolve) else { continue }
            out.append(sample)
        }
        return out
    }
}
