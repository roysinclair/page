import XCTest
@testable import PageCore

/// The name a Claude session goes by (Designs/session-copies.md §C): the rule (`SessionNaming`), the pure parsers
/// of cmux and tmux output, the transcript's `/rename` reader (temp files only), and `SessionNameProvider` with its
/// seams injected. No cmux, tmux or `ps` is run: the provider's process table is the inert one for the test.
final class SessionNamesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)
    private let sid = "5e55a0f1-7c2b-4d3e-8a9f-0b1c2d3e4f50"
    private var savedProcesses: ProcessInspector!
    private var files: [URL] = []

    override func setUp() {
        super.setUp()
        // `SessionNameProvider.fetch` reads the process table directly: give it the inert one, never `ps`.
        savedProcesses = Platform.current.processes
        Platform.current.processes = InertProcesses()
    }

    override func tearDown() {
        Platform.current.processes = savedProcesses
        for f in files { try? FileManager.default.removeItem(at: f) }
        files = []
        super.tearDown()
    }

    // MARK: - the rule

    func testWithNothingGivenThereIsNoName() {
        XCTAssertNil(SessionNaming.resolve(SessionNaming.Sources()))
    }

    func testTheCmuxTabBeatsEverything() {
        let s = SessionNaming.Sources(cmuxTab: "Tab", rename: "R", cmuxWorkspace: "W", cmuxWindow: "Win", tmuxWindow: "T")
        XCTAssertEqual(SessionNaming.resolve(s), "Tab")
    }

    func testTheRenameBeatsTheCmuxWorkspace() {
        XCTAssertEqual(SessionNaming.resolve(.init(rename: "R", cmuxWorkspace: "W", cmuxWindow: "Win", tmuxWindow: "T")), "R")
    }

    func testTheCmuxWorkspaceBeatsTheWindowAndTheWindowBeatsTmux() {
        XCTAssertEqual(SessionNaming.resolve(.init(cmuxWorkspace: "W", cmuxWindow: "Win", tmuxWindow: "T")), "W")
        XCTAssertEqual(SessionNaming.resolve(.init(cmuxWindow: "Win", tmuxWindow: "T")), "Win")
        XCTAssertEqual(SessionNaming.resolve(.init(tmuxWindow: "T")), "T")
    }

    func testABlankSourceIsSkippedForTheNextOne() {
        XCTAssertEqual(SessionNaming.resolve(.init(cmuxTab: "   ", rename: "", cmuxWorkspace: "W")), "W")
        XCTAssertNil(SessionNaming.resolve(.init(cmuxTab: " \n ", rename: nil)))
    }

    // MARK: - clean

    func testCleanTrimsAndKeepsOneLine() {
        XCTAssertNil(SessionNaming.clean(nil))
        XCTAssertNil(SessionNaming.clean("   "))
        XCTAssertEqual(SessionNaming.clean("  Workspace-App \n"), "Workspace-App")
        XCTAssertEqual(SessionNaming.clean("first\nsecond"), "first second", "a newline becomes a space")
        XCTAssertEqual(SessionNaming.clean("first\u{2028}second"), "first second", "a line separator is a newline too")
    }

    func testCleanTreatsACarriageReturnLineEndingAsOneNewline() {
        // A CRLF is one line break: it becomes one space, not two.
        XCTAssertEqual(SessionNaming.clean("first\r\nsecond"), "first second")
    }

    func testCleanClipsToTheWireTitleLength() {
        let long = String(repeating: "x", count: SessionRemote.maxTitle + 50)
        XCTAssertEqual(SessionNaming.clean(long)?.count, SessionRemote.maxTitle)
        XCTAssertEqual(SessionNaming.clean(String(repeating: "y", count: SessionRemote.maxTitle)),
                       String(repeating: "y", count: SessionRemote.maxTitle))
    }

    // MARK: - /rename and the sessions file

    func testTheTranscriptRenameWinsOverTheSessionsFileName() {
        XCTAssertEqual(SessionNaming.renameName(customTitle: "Renamed", sessionFileName: "page", sessionFileNameSource: "user"),
                       "Renamed")
    }

    func testTheSessionsFileNameCountsOnlyWhenThePersonGaveIt() {
        XCTAssertEqual(SessionNaming.renameName(customTitle: nil, sessionFileName: "work", sessionFileNameSource: "user"), "work")
        XCTAssertNil(SessionNaming.renameName(customTitle: nil, sessionFileName: "page", sessionFileNameSource: "derived"))
        XCTAssertNil(SessionNaming.renameName(customTitle: nil, sessionFileName: "page", sessionFileNameSource: "Derived"),
                     "the word is compared without case")
        XCTAssertNil(SessionNaming.renameName(customTitle: nil, sessionFileName: "page", sessionFileNameSource: nil),
                     "a file that doesn't say counts as derived")
        XCTAssertNil(SessionNaming.renameName(customTitle: nil, sessionFileName: "page", sessionFileNameSource: "  "))
    }

    func testAClearedRenameFallsBackToThePersonsSessionsFileName() {
        XCTAssertEqual(SessionNaming.renameName(customTitle: "", sessionFileName: "work", sessionFileNameSource: "user"), "work")
        XCTAssertNil(SessionNaming.renameName(customTitle: "", sessionFileName: "page", sessionFileNameSource: "derived"))
    }

    // MARK: - tmux and cmux parsers

    func testATmuxWindowTheUserRenamedIsItsName() {
        XCTAssertEqual(SessionNaming.tmuxWindowName(fromDisplay: "0\tmywin\n"), "mywin")
        XCTAssertEqual(SessionNaming.tmuxWindowName(fromDisplay: "0\tname\n1\tother"), "name", "the first line only")
    }

    func testATmuxWindowWithAutomaticRenameOnIsNotAName() {
        XCTAssertNil(SessionNaming.tmuxWindowName(fromDisplay: "1\tbash\n"), "automatic-rename on: tmux made the title")
        XCTAssertNil(SessionNaming.tmuxWindowName(fromDisplay: "0\t\n"))
        XCTAssertNil(SessionNaming.tmuxWindowName(fromDisplay: "0 mywin"), "no tab between the columns")
        XCTAssertNil(SessionNaming.tmuxWindowName(fromDisplay: ""))
    }

    func testOnlyCustomCmuxWorkspaceTitlesCount() throws {
        let list: [String: Any] = ["workspaces": [
            ["id": "ws-a", "has_custom_title": true, "custom_title": "Workspace-App", "title": "page"],
            ["id": "ws-b", "has_custom_title": false, "title": "Automatic title"],
            ["id": "ws-c", "custom_title": "No flag", "title": "x"],
            ["id": "ws-d", "has_custom_title": true, "custom_title": "   ", "title": "blank"],
        ]]
        XCTAssertEqual(SessionNaming.cmuxCustomWorkspaceNames(fromWorkspaceList: list), ["WS-A": "Workspace-App"],
                       "ids are upper-cased; a title without the flag, or a blank one, isn't a name")
    }

    func testTheCmuxWindowIdsAreListed() {
        XCTAssertEqual(SessionNaming.cmuxWindowIds(fromWindowList: ["windows": [["id": "W1"], ["id": "W2"], ["x": 1]]]),
                       ["W1", "W2"])
        XCTAssertEqual(SessionNaming.cmuxWindowIds(fromWindowList: [:]), [])
    }

    // MARK: - the transcript's /rename (temp files)

    private func renameLine(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sid)"}"#
    }

    private let userLine = #"{"type":"user","timestamp":"2026-10-24T10:00:00.000Z","message":{"role":"user","content":"hello"}}"#

    /// Writes the file with exactly these bytes and a modification time (so a rewrite is seen as a change).
    @discardableResult
    private func tempFile(_ data: Data, mtimeOffset: TimeInterval = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(mtimeOffset)], ofItemAtPath: url.path)
        files.append(url)
        return url
    }

    private func tempFile(lines: [String], mtimeOffset: TimeInterval = 0) throws -> URL {
        try tempFile(Data((lines.joined(separator: "\n") + "\n").utf8), mtimeOffset: mtimeOffset)
    }

    private func rewrite(_ url: URL, lines: [String], mtimeOffset: TimeInterval) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(mtimeOffset)], ofItemAtPath: url.path)
    }

    func testARenameNearTheStartIsFound() throws {
        let url = try tempFile(lines: [renameLine("Early")] + Array(repeating: userLine, count: 200))
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "Early")
    }

    func testTheLatestRenameWins() throws {
        let url = try tempFile(lines: [renameLine("A"), userLine, renameLine("B"), userLine])
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "B")
    }

    func testAnAppendedRenameIsSeenOnTheNextRead() throws {
        let reader = TranscriptRenameReader()
        let url = try tempFile(lines: [renameLine("A"), userLine])
        XCTAssertEqual(reader.customTitle(at: url), "A")
        try rewrite(url, lines: [renameLine("A"), userLine, userLine, renameLine("B")], mtimeOffset: 10)
        XCTAssertEqual(reader.customTitle(at: url), "B")
    }

    func testAClearedTitleIsNoNameNotTheOldOne() throws {
        let reader = TranscriptRenameReader()
        let url = try tempFile(lines: [renameLine("A"), userLine])
        XCTAssertEqual(reader.customTitle(at: url), "A")
        try rewrite(url, lines: [renameLine("A"), userLine, renameLine("")], mtimeOffset: 10)
        XCTAssertNil(reader.customTitle(at: url), "the person cleared the name: the folder shows, not \"A\"")
    }

    func testAUserMessageThatHasTheMarkerAsItsOwnValueDoesNotCount() throws {
        // An unescaped "custom-title" string in a line that isn't a custom-title entry: the byte search finds it,
        // and the entry's type rejects it. The rename before it still counts.
        let decoy = #"{"type":"user","tag":"custom-title","message":{"role":"user","content":"rename it"}}"#
        let url = try tempFile(lines: [renameLine("Real"), userLine, decoy])
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "Real")
    }

    func testAUserTypingTheWordDoesNotCount() throws {
        // The person types the marker as text: it is JSON-escaped in the file, so it isn't the entry either.
        let typed = #"{"type":"user","message":{"role":"user","content":"run /rename \"custom-title\" please"}}"#
        let url = try tempFile(lines: [renameLine("Real"), typed])
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "Real")
        let onlyTyped = try tempFile(lines: [typed])
        XCTAssertNil(TranscriptRenameReader().customTitle(at: onlyTyped))
    }

    func testAFileWithNoRenameHasNoName() throws {
        let url = try tempFile(lines: [userLine, userLine])
        XCTAssertNil(TranscriptRenameReader().customTitle(at: url))
        XCTAssertNil(TranscriptRenameReader().customTitle(at: FileManager.default.temporaryDirectory
                                                              .appendingPathComponent("missing-\(UUID().uuidString).jsonl")))
    }

    func testARenameInAFileOfSeveralMegabytesIsFoundAtEachEnd() throws {
        let filler = String(repeating: userLine + "\n", count: 3000)           // about 0.5 MB of user turns
        let near = [renameLine("Early")] + [filler, filler, filler, filler, filler, filler, filler]
        let url = try tempFile(Data(near.joined(separator: "\n").utf8))
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "Early", "a 3 MB file, the rename at byte 0")

        let late = [filler, filler, filler, filler, filler, filler, filler, renameLine("Late")]
        let url2 = try tempFile(Data((late.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url2), "Late", "the rename at the end")
    }

    func testARenameLineCutAcrossTheOneMegabyteChunkBoundaryIsFound() throws {
        // A 3 MB file. The first 1 MB chunk read (from the end) starts at 2 MB; this rename's first bytes are just
        // before that, so the chunk sees only the line's tail and must not take it, and the next chunk (which reaches
        // back over the overlap) must find it whole.
        let size = 3 * 1024 * 1024
        let boundary = 2 * 1024 * 1024
        let line = Array((renameLine("Straddle") + "\n").utf8)
        let start = boundary - 8                                       // `{"type":` is 8 bytes: the marker starts at the boundary
        var bytes = Array(repeating: UInt8(ascii: "a"), count: start - 1) + [0x0A]
        bytes += line
        bytes += Array(repeating: UInt8(ascii: "b"), count: size - bytes.count - 1) + [0x0A]
        XCTAssertEqual(bytes.count, size)
        let url = try tempFile(Data(bytes))
        XCTAssertEqual(TranscriptRenameReader().customTitle(at: url), "Straddle")
    }

    func testLastTitleIsPureAboutTheEndOfTheData() {
        let line = Data(renameLine("X").utf8)
        // Whole line, the data ends it: found.
        XCTAssertEqual(TranscriptRenameReader.lastTitle(in: Data(("\n" + renameLine("X")).utf8), atFileStart: false, complete: true),
                       .init(title: "X"))
        // The same line cut at the end of the data, not the end of the file: left for the next read.
        XCTAssertNil(TranscriptRenameReader.lastTitle(in: Data(("\n" + renameLine("X")).utf8), atFileStart: false, complete: false))
        // A line cut at the start of the data (not the file's start) is skipped.
        XCTAssertNil(TranscriptRenameReader.lastTitle(in: line, atFileStart: false, complete: true))
        // A cleared title is found, and empty.
        XCTAssertEqual(TranscriptRenameReader.lastTitle(in: Data((renameLine("") + "\n").utf8), atFileStart: true, complete: true),
                       .init(title: nil))
    }

    func testABigTranscriptIsReadInTheBackgroundAndTheAnswerArrivesLater() throws {
        // Sparse: the rename is at the start, the rest of the 9 MB file is zeros (over the 8 MB inline limit).
        let url = try tempFile(Data((renameLine("Big") + "\n").utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 9 * 1024 * 1024)
        try handle.close()

        let reader = TranscriptRenameReader()
        let ready = expectation(description: "the background read finished with a new answer")
        XCTAssertNil(reader.customTitle(at: url, whenReady: { ready.fulfill() }), "the first look doesn't hold the caller")
        wait(for: [ready], timeout: 20)
        XCTAssertEqual(reader.customTitle(at: url), "Big")
    }

    // MARK: - SessionNameProvider (seams injected)

    private final class Box {
        private let lock = NSLock()
        private var _now: Date
        private var _places: [Int32: SessionNameProvider.Place] = [:]
        var cmux: [String: String]? = [:]           // nil: cmux can't be read this time
        var tmux: [String: String] = [:]
        private(set) var locates = 0
        private(set) var cmuxFetches = 0
        private(set) var tmuxFetches = 0
        var sleepNextCmux: TimeInterval = 0
        /// Called after each cmux read (on the provider's queue).
        var onCmuxRead: (() -> Void)?

        init(_ now: Date) { _now = now }

        var now: Date { get { lock.lock(); defer { lock.unlock() }; return _now } set { lock.lock(); _now = newValue; lock.unlock() } }
        func setPlace(_ pid: Int32, _ p: SessionNameProvider.Place) { lock.lock(); _places[pid] = p; lock.unlock() }
        func locate(_ pid: Int32) -> SessionNameProvider.Place {
            lock.lock(); defer { lock.unlock() }
            locates += 1
            return _places[pid] ?? .none
        }
        func cmuxRead() -> [String: String]? {
            lock.lock()
            cmuxFetches += 1
            let sleep = sleepNextCmux
            sleepNextCmux = 0
            let names = cmux
            let hook = onCmuxRead
            lock.unlock()
            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
            hook?()
            return names
        }
        func tmuxRead(_ pane: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            tmuxFetches += 1
            return tmux[pane]
        }
    }

    private func session(name: String? = nil, source: String? = nil) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/Users/me/projects/page", status: .idle,
                          statusUpdatedAt: t0, tty: "ttys042", hasSessionFile: true, name: name, nameSource: source)
    }

    private func provider(_ box: Box) -> SessionNameProvider {
        SessionNameProvider(locate: { s, _ in box.locate(s.pid) },
                            fetchCmux: { _ in box.cmuxRead() },
                            fetchTmux: { _, pane in box.tmuxRead(pane) },
                            now: { box.now })
    }

    private let cmuxPlace = SessionNameProvider.Place.cmux(cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux",
                                                           workspaceId: "ws-a")

    func testTheFolderShowsWhenNothingIsNamed() {
        let box = Box(t0)
        XCTAssertNil(provider(box).nameForNewPage(session(), transcript: nil))
    }

    func testTheCmuxWorkspacesCustomNameIsFoundForANewPage() {
        // The workspace id is lower-case in the place (as the locate read it); the names are keyed in upper case.
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Workspace-App"]
        XCTAssertEqual(provider(box).nameForNewPage(session(), transcript: nil), "Workspace-App")
    }

    func testATmuxWindowTheUserRenamedIsFound() {
        let box = Box(t0)
        box.setPlace(42, .tmux(path: "/opt/tmux", pane: "%3"))
        box.tmux = ["%3": "Build"]
        XCTAssertEqual(provider(box).nameForNewPage(session(), transcript: nil), "Build")
    }

    func testARenameBeatsTheCmuxWorkspace() throws {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Workspace-App"]
        let url = try tempFile(lines: [#"{"type":"custom-title","customTitle":"Renamed"}"#])
        XCTAssertEqual(provider(box).nameForNewPage(session(), transcript: url), "Renamed")
    }

    func testTheSessionsFileNameCountsOnlyWhenNotDerived() {
        let box = Box(t0)
        XCTAssertEqual(provider(box).name(for: session(name: "work", source: "user"), transcript: nil), "work")
        XCTAssertNil(provider(box).name(for: session(name: "page", source: "derived"), transcript: nil))
    }

    func testTheLookupNeverFetchesOrWaits() {
        // `name(for:)` answers from what has been read: no cmux or tmux call, even when a place is known.
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Workspace-App"]
        XCTAssertNil(provider(box).name(for: session(), transcript: nil), "nothing read yet: the folder shows")
        XCTAssertEqual(box.cmuxFetches, 0)
        XCTAssertEqual(box.locates, 0)
    }

    func testTheFiveSecondCacheAndTheSixtySecondPlaceLookup() {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "One"]
        let p = provider(box)
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "One")
        XCTAssertEqual(box.cmuxFetches, 1)
        XCTAssertEqual(box.locates, 1)

        box.now = t0.addingTimeInterval(4)
        box.cmux = ["WS-A": "Two"]
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "One", "4 s: the cached read is used")
        XCTAssertEqual(box.cmuxFetches, 1)

        box.now = t0.addingTimeInterval(5)
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Two", "5 s: read again")
        XCTAssertEqual(box.cmuxFetches, 2)
        XCTAssertEqual(box.locates, 1, "the place is kept for a minute")

        box.now = t0.addingTimeInterval(65)
        _ = p.nameForNewPage(session(), transcript: nil)
        XCTAssertEqual(box.locates, 2, "a minute on, the process's place is found again")
    }

    func testAFailedCmuxReadKeepsTheName() {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Workspace-App"]
        let p = provider(box)
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Workspace-App")

        box.now = t0.addingTimeInterval(6)
        box.cmux = nil                                  // cmux is busy this time
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Workspace-App", "the cached name stays")
        XCTAssertEqual(box.cmuxFetches, 2, "it was tried")
    }

    func testARenamedWorkspaceShowsOnTheNextRead() {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Old"]
        let p = provider(box)
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Old")
        box.now = t0.addingTimeInterval(5)
        box.cmux = ["WS-A": "Workspace-App"]
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Workspace-App")
    }

    func testAPageWaitsAtMostAboutOneAndAHalfSecondsForASlowCmux() {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Old"]
        let p = provider(box)
        XCTAssertEqual(p.nameForNewPage(session(), transcript: nil), "Old")

        box.now = t0.addingTimeInterval(6)              // the cache is stale now: the next page reads again
        box.cmux = ["WS-A": "New"]
        box.sleepNextCmux = 2.5                         // cmux takes too long
        let started = Date()
        let name = p.nameForNewPage(session(), transcript: nil)
        let waited = Date().timeIntervalSince(started)
        XCTAssertEqual(name, "Old", "the page goes with what it had")
        XCTAssertLessThan(waited, 2.2, "waited about the page wait (1.5 s), not the whole read")
    }

    func testTheFiveSecondTimerReadsOnlyWhileAPhoneOrThePanelIsLooking() {
        let box = Box(t0)
        box.setPlace(42, cmuxPlace)
        box.cmux = ["WS-A": "Workspace-App"]
        let p = provider(box)
        p.watch([session()])
        p.start()
        defer { p.stop() }

        // Nobody is looking: the timer fires twice and reads nothing.
        let quiet = expectation(description: "two timer ticks with no demand")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 6)
        XCTAssertEqual(box.cmuxFetches, 0, "no phone, no panel: no cmux read")

        // A phone looks: the next tick reads.
        let read = expectation(description: "a cmux read once touched")
        box.onCmuxRead = { read.fulfill() }
        p.touch()
        wait(for: [read], timeout: 8)
    }
}
