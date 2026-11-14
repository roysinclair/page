import Foundation

// The name a Claude session goes by (Designs/session-copies.md §C): what the person called it, never a title a
// program made up. The rule is pure; the readers below it (the transcript's `/rename`, cmux, tmux) only find
// the candidates. Nothing here ever writes to a terminal, a cmux workspace or a Claude session.

enum SessionNaming {
    /// The names a session might have, one per source. nil: that source has none (or cannot say).
    struct Sources: Equatable {
        /// The cmux tab's own name. Used only if cmux marks it as the person's: cmux 0.65.2 doesn't (`list-panels`,
        /// `tree` and `mobile.workspace.list` give a tab's title with no custom flag, and a tab's automatic
        /// titles look the same), so nothing fills this today.
        var cmuxTab: String?
        /// Claude Code's `/rename`: the transcript's latest `custom-title`, else a sessions-file name the
        /// person gave it.
        var rename: String?
        /// The cmux workspace's own name, when cmux says the person set it (`has_custom_title`).
        var cmuxWorkspace: String?
        /// The cmux window's own name. cmux 0.65.2's `window.list` exposes none.
        var cmuxWindow: String?
        /// A tmux window the person renamed (`automatic-rename` off).
        var tmuxWindow: String?
    }

    /// Pure. The first source that has a name, in the spec's order; nil means "show the folder name".
    static func resolve(_ s: Sources) -> String? {
        for candidate in [s.cmuxTab, s.rename, s.cmuxWorkspace, s.cmuxWindow, s.tmuxWindow] {
            if let name = clean(candidate) { return name }
        }
        return nil
    }

    /// Pure. A name as it is shown: one line, trimmed, clipped to the wire's `maxTitle`. nil when nothing is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Any run of spaces and line breaks (CRLF included) becomes one space.
        let oneLine = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count <= SessionRemote.maxTitle ? oneLine : String(oneLine.prefix(SessionRemote.maxTitle))
    }

    /// Pure. Claude Code's own rename: the transcript's latest `custom-title` wins; else the sessions file's
    /// `name`, but only when it says the person gave it (`nameSource` other than "derived"; a file that
    /// doesn't say counts as derived, since the name there is "often the folder").
    static func renameName(customTitle: String?, sessionFileName: String?, sessionFileNameSource: String?) -> String? {
        if let t = clean(customTitle) { return t }
        guard let source = sessionFileNameSource?.trimmingCharacters(in: .whitespaces).lowercased(),
              !source.isEmpty, source != "derived" else { return nil }
        return clean(sessionFileName)
    }

    /// Pure. A tmux window's name when the person set it: `automatic-rename` is off. `listing` is
    /// `#{automatic-rename}\t#{window_name}`.
    static func tmuxWindowName(fromDisplay listing: String) -> String? {
        let line = listing.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let cols = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard cols.count == 2, cols[0] == "0" else { return nil }
        return clean(String(cols[1]))
    }

    /// Pure. The workspaces the person named, from one window's `workspace.list`: id (uppercased) → name.
    /// Only `has_custom_title` counts: `title` is cmux's display title, automatic or not.
    static func cmuxCustomWorkspaceNames(fromWorkspaceList obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for w in (obj["workspaces"] as? [[String: Any]]) ?? [] {
            guard w["has_custom_title"] as? Bool == true, let id = w["id"] as? String,
                  let name = clean(w["custom_title"] as? String) else { continue }
            out[id.uppercased()] = name
        }
        return out
    }

    /// Pure. The window ids in `window.list`.
    static func cmuxWindowIds(fromWindowList obj: [String: Any]) -> [String] {
        ((obj["windows"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - /rename in the transcript

/// Claude Code writes `{"type":"custom-title","customTitle":"…","sessionId":"…"}` into the transcript when the
/// person runs `/rename`, and again when it resumes the session, so the latest one is the name. It is near the
/// start of the file as often as the end, so the whole file is searched once (from the end, 1 MB at a time, with
/// a byte search before any JSON is parsed) and after that only what was appended.
final class TranscriptRenameReader {
    private struct Entry { var size: UInt64; var mtime: Date; var title: String? }
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var scanning: Set<String> = []
    private let scanQueue = DispatchQueue(label: "ClaudePowerMode.renameScan", qos: .utility)

    static let marker = Data("\"custom-title\"".utf8)
    static let chunk = 1 << 20
    /// A custom-title line is a few hundred bytes: an overlap this long always holds one whole.
    static let overlap = 4096
    /// A read of more than this many bytes (about a millisecond per megabyte) happens off the caller's thread.
    static let inlineBytes: UInt64 = 8 << 20

    /// The session's latest rename, or nil. Reads the file only when its size or time changed: what was
    /// appended, or all of it. A big read runs in the background (the caller gets what was known, and
    /// `whenReady` runs if the answer turned out different), so a first look at a 250 MB transcript never
    /// holds the tick.
    func customTitle(at url: URL, whenReady: (() -> Void)? = nil) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        lock.lock()
        let known = cache[url.path]
        lock.unlock()
        if let known, known.size == size, known.mtime == mtime { return known.title }
        let appended = known.map { size > $0.size && mtime >= $0.mtime } ?? false
        let from = appended ? (known!.size > UInt64(Self.overlap) ? known!.size - UInt64(Self.overlap) : 0) : 0
        if size - from <= Self.inlineBytes {
            return read(url, size: size, mtime: mtime, from: from, known: appended ? known?.title : nil)
        }
        lock.lock()
        let started = scanning.insert(url.path).inserted
        lock.unlock()
        guard started else { return known?.title }
        let before = known?.title
        scanQueue.async { [self] in
            let title = read(url, size: size, mtime: mtime, from: from, known: appended ? before : nil)
            lock.lock()
            scanning.remove(url.path)
            lock.unlock()
            if title != before { whenReady?() }
        }
        return before
    }

    private func read(_ url: URL, size: UInt64, mtime: Date, from: UInt64, known: String?) -> String? {
        // Appended to: only what is new counts, and with no new entry the old answer stands.
        let title = Self.scan(url, from: from, to: size).map(\.title) ?? known
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[url.path] = Entry(size: size, mtime: mtime, title: title)
        lock.unlock()
        return title
    }

    /// What a `custom-title` entry said: its title, nil when empty (the name was cleared).
    struct Found: Equatable { let title: String? }

    /// The last custom-title entry in bytes [from, to) of the file; nil when there is none.
    static func scan(_ url: URL, from: UInt64, to: UInt64) -> Found? {
        guard to > from, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var end = to
        while true {
            let start = end > from + UInt64(chunk) ? end - UInt64(chunk) : from
            do { try handle.seek(toOffset: start) } catch { return nil }
            guard let data = try? handle.read(upToCount: Int(end - start)) else { return nil }
            if let hit = lastTitle(in: data, atFileStart: start == 0, complete: end == to) { return hit }
            if start == from { return nil }
            // The next chunk reaches back over this one's first bytes: a line cut here is whole there.
            end = start + UInt64(overlap)
        }
    }

    /// Pure. The last whole `custom-title` line in `data`: its title (nil when empty). A line cut off at the
    /// chunk's start is skipped unless the chunk starts the file; one cut at its end only if the data ends
    /// the read (`complete`), since the next read sees it whole.
    static func lastTitle(in data: Data, atFileStart: Bool, complete: Bool) -> Found? {
        var searchEnd = data.endIndex
        while let r = data.range(of: marker, options: .backwards, in: data.startIndex..<searchEnd) {
            searchEnd = r.lowerBound
            let before = data[data.startIndex..<r.lowerBound]
            let lineStart: Data.Index
            if let nl = before.lastIndex(of: 0x0A) { lineStart = nl + 1 } else if atFileStart { lineStart = data.startIndex } else { continue }
            let after = data[r.upperBound..<data.endIndex]
            let lineEnd: Data.Index
            if let nl = after.firstIndex(of: 0x0A) { lineEnd = nl } else if complete { lineEnd = data.endIndex } else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
                  obj["type"] as? String == "custom-title" else { continue }
            return Found(title: SessionNaming.clean(obj["customTitle"] as? String))
        }
        return nil
    }
}

// MARK: - cmux and tmux names

/// Finds the names cmux and tmux hold for the terminals Claude sessions run in. Only reads (`window.list`,
/// `workspace.list`, `tmux display-message`). cmux has no all-windows listing and `has_custom_title` is only in the
/// per-window one, so a fetch is one `window.list` and one `workspace.list` per window (about 0.3 s for nine
/// windows); it runs at most every 5 s, and only while a phone is looking, the Now panel is open, or a page is
/// about to open.
final class SessionNameProvider {
    /// Where a session's terminal lives, for naming only.
    enum Place: Equatable {
        case cmux(cliPath: String, workspaceId: String)
        case tmux(path: String, pane: String)
        case none
    }

    static let fetchInterval: TimeInterval = 5
    /// How long after the last sign of interest the 5 s timer keeps fetching.
    static let demandWindow: TimeInterval = 20
    /// How long a page about to open waits for cmux or tmux to answer before it goes with what it has.
    static let pageWait: TimeInterval = 1.5
    private static let placeTTL: TimeInterval = 60

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ClaudePowerMode.sessionNames", qos: .utility)
    private let renames = TranscriptRenameReader()
    private let locate: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> Place
    private let fetchCmux: (_ cliPath: String) -> [String: String]?
    private let fetchTmux: (_ path: String, _ pane: String) -> String?
    private let now: () -> Date

    // Under `lock`. Names and when each source was last read, by cmux channel and by tmux pane.
    private var places: [Int32: (place: Place, at: Date)] = [:]
    private var cmuxNames: [String: (names: [String: String], at: Date)] = [:]
    private var tmuxNames: [String: (name: String?, at: Date)] = [:]
    private var watching: [ClaudeLiveSession] = []
    private var demandUntil: Date = .distantPast
    private var timer: DispatchSourceTimer?

    /// Called (off the tick queue) when something that may have changed a name was read: the 5 s pass while
    /// names are wanted, or a big transcript's rename finished reading. The listener compares.
    var onChange: (() -> Void)?

    init(locate: @escaping (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> Place = SessionNameProvider.livePlace,
         fetchCmux: @escaping (String) -> [String: String]? = SessionNameProvider.liveCmuxNames,
         fetchTmux: @escaping (String, String) -> String? = SessionNameProvider.liveTmuxName,
         now: @escaping () -> Date = Date.init) {
        self.locate = locate
        self.fetchCmux = fetchCmux
        self.fetchTmux = fetchTmux
        self.now = now
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.fetchInterval, repeating: Self.fetchInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, self.wanted() else { return }
            self.lock.lock()
            let sessions = self.watching
            self.lock.unlock()
            self.fetch(sessions)
            // A rename in a transcript has no timer of its own: the listener looks again, and does nothing
            // when no name changed.
            self.onChange?()
        }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// A phone is looking, or the panel is open: keep the cmux and tmux names fresh for a while.
    func touch() {
        lock.lock()
        demandUntil = now().addingTimeInterval(Self.demandWindow)
        lock.unlock()
    }

    private func wanted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now() < demandUntil
    }

    /// The sessions the names are for (the leads, each tick).
    func watch(_ sessions: [ClaudeLiveSession]) {
        lock.lock()
        watching = sessions
        let live = Set(sessions.map(\.pid))
        places = places.filter { live.contains($0.key) }
        let panes = Set(places.values.compactMap { if case .tmux(_, let p) = $0.place { return p } else { return nil } })
        let clis = Set(places.values.compactMap { if case .cmux(let c, _) = $0.place { return c } else { return nil } })
        tmuxNames = tmuxNames.filter { panes.contains($0.key) }
        cmuxNames = cmuxNames.filter { clis.contains($0.key) }
        lock.unlock()
    }

    // MARK: lookup (never blocks on cmux or tmux)

    /// The name the person gave this session, from what has been read so far; nil to show the folder.
    func name(for s: ClaudeLiveSession, transcript: URL?) -> String? {
        let rename = SessionNaming.renameName(customTitle: transcript.flatMap { renames.customTitle(at: $0, whenReady: { [weak self] in self?.onChange?() }) },
                                              sessionFileName: s.name, sessionFileNameSource: s.nameSource)
        var sources = SessionNaming.Sources(rename: rename)
        lock.lock()
        switch places[s.pid]?.place {
        case .cmux(let cli, let ws)?: sources.cmuxWorkspace = cmuxNames[cli]?.names[ws.uppercased()]
        case .tmux(_, let pane)?: sources.tmuxWindow = tmuxNames[pane]?.name
        case Place.none?, nil: break
        }
        lock.unlock()
        return SessionNaming.resolve(sources)
    }

    /// The same, for a page about to open: reads this session's cmux workspace or tmux window first when what is
    /// held is older than 5 s, waiting at most `pageWait` for it (the page goes with what it has after that).
    func nameForNewPage(_ s: ClaudeLiveSession, transcript: URL?) -> String? {
        touch()
        lock.lock()
        let at = now()
        let stale: Bool
        switch places[s.pid] {
        case nil: stale = true
        case let known?:
            switch known.place {
            case .cmux(let cli, _): stale = cmuxNames[cli].map { at.timeIntervalSince($0.at) >= Self.fetchInterval } ?? true
            case .tmux(_, let pane): stale = tmuxNames[pane].map { at.timeIntervalSince($0.at) >= Self.fetchInterval } ?? true
            case .none: stale = at.timeIntervalSince(known.at) >= Self.placeTTL
            }
        }
        lock.unlock()
        if stale {
            let done = DispatchSemaphore(value: 0)
            queue.async { [self] in
                fetch([s])
                done.signal()
            }
            _ = done.wait(timeout: .now() + Self.pageWait)
        }
        return name(for: s, transcript: transcript)
    }

    // MARK: fetching (queue)

    /// Reads where `sessions` live (once a minute per process) and the names cmux and tmux hold for them, each
    /// source once however many sessions share it.
    private func fetch(_ sessions: [ClaudeLiveSession]) {
        let at = now()
        lock.lock()
        let missing = sessions.filter { s in places[s.pid].map { at.timeIntervalSince($0.at) >= Self.placeTTL } ?? true }
        lock.unlock()
        if !missing.isEmpty {
            let table = ProcessRunner.processTable()
            let found = missing.map { ($0.pid, locate($0, table)) }
            lock.lock()
            for (pid, place) in found { places[pid] = (place, at) }
            lock.unlock()
        }
        lock.lock()
        let placesNow = sessions.compactMap { places[$0.pid]?.place }
        lock.unlock()
        for cli in Set(placesNow.compactMap { if case .cmux(let c, _) = $0 { return c } else { return nil } }) {
            // A failed read keeps what was known: cmux may have been busy.
            guard let names = fetchCmux(cli) else { continue }
            lock.lock(); cmuxNames[cli] = (names, at); lock.unlock()
        }
        for case .tmux(let path, let pane) in placesNow {
            let name = fetchTmux(path, pane)
            lock.lock(); tmuxNames[pane] = (name, at); lock.unlock()
        }
    }

    // MARK: live readers

    /// Where a session's terminal is, without touching it: tmux by tty, else cmux through the process's ancestry,
    /// the same way `InjectionExecutor.resolveHost` finds the pane (and nothing else: a session in any other
    /// terminal has no name to read there).
    static func livePlace(_ s: ClaudeLiveSession, table: [ProcessRunner.ProcessInfoRow]) -> Place {
        guard let tty = s.devTTY else { return .none }
        if let tmux = ProcessRunner.findExecutable("tmux") {
            let r = ProcessRunner.run(tmux, ["list-panes", "-a", "-F", InjectionExecutor.tmuxPaneListFormat], timeout: 3)
            if r.succeeded, let pane = InjectionExecutor.tmuxPane(forTTY: tty, listing: r.stdout) {
                return .tmux(path: tmux, pane: pane.id)
            }
        }
        guard let app = InjectionExecutor.hostAppCommand(forPid: s.pid, processTable: table),
              let bundle = CmuxBridge.bundlePath(fromAppCommand: app),
              case .success(let target) = CmuxBridge.locateSurface(pid: s.pid, sessionId: s.sessionId, agent: .claude, bundlePath: bundle),
              let ws = target.workspaceId else { return .none }
        return .cmux(cliPath: target.cliPath, workspaceId: ws)
    }

    /// Every workspace the person named, across cmux's windows. nil when cmux can't be read.
    static func liveCmuxNames(cliPath: String) -> [String: String]? {
        guard case .success(let client) = CmuxBridge.connect(cliPath: cliPath),
              case .success(let windows) = client.rpc("window.list", [:], fallback: "cmux didn't list its windows") else { return nil }
        var out: [String: String] = [:]
        for id in SessionNaming.cmuxWindowIds(fromWindowList: windows).prefix(40) {
            guard case .success(let list) = client.rpc("workspace.list", ["window_id": id], fallback: "cmux didn't list a window") else { return nil }
            out.merge(SessionNaming.cmuxCustomWorkspaceNames(fromWorkspaceList: list)) { a, _ in a }
        }
        return out
    }

    /// The tmux window's name when the person renamed it.
    static func liveTmuxName(path: String, pane: String) -> String? {
        guard TerminalFocus.isSafePane(pane) else { return nil }
        let r = ProcessRunner.run(path, ["display-message", "-p", "-t", pane, "#{automatic-rename}\t#{window_name}"], timeout: 3)
        return r.succeeded ? SessionNaming.tmuxWindowName(fromDisplay: r.stdout) : nil
    }
}
