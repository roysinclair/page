import XCTest
@testable import PageCore

/// Voice input on the Mac (Designs/voice-input.md, "Mac"): the words in the Steer box (`DictationDraft`),
/// the guard against typing under the dictation, the engine choice, the locale match, the clock, the level,
/// the copy, the keys and the shortcuts sheet. Pure: no microphone, no speech engine.
final class DictationTests: XCTestCase {

    // MARK: - DictationDraft: joining

    func testEmptyBaseTakesTheWordsWithNoSpace() {
        var d = DictationDraft(base: "")
        XCTAssertEqual(d.text, "", "nothing said, nothing shown")
        d.commit("hello")
        XCTAssertEqual(d.text, "hello")
    }

    func testBaseWithoutTrailingSpaceGetsOneSpace() {
        var d = DictationDraft(base: "Fix the test")
        d.commit("now")
        XCTAssertEqual(d.text, "Fix the test now")
    }

    func testBaseEndingInSpaceGetsNoSecondSpace() {
        var d = DictationDraft(base: "Fix the test ")
        d.commit("now")
        XCTAssertEqual(d.text, "Fix the test now")
    }

    func testBaseEndingInNewlineOrTabGetsNoJoiner() {
        var newline = DictationDraft(base: "line one\n")
        newline.setVolatile("two")
        XCTAssertEqual(newline.text, "line one\ntwo", "the person's own newline is kept, and no space is added after it")

        var tab = DictationDraft(base: "a\t")
        tab.commit("b")
        XCTAssertEqual(tab.text, "a\tb")
    }

    func testBaseAloneIsShownUntilSomethingIsSaid() {
        let d = DictationDraft(base: "Keep this")
        XCTAssertEqual(d.text, "Keep this")
        XCTAssertFalse(d.hasWords)
        XCTAssertEqual(d.spoken, "")
    }

    func testOnlyTheFirstWordsGetTheJoiner() {
        var d = DictationDraft(base: "Hi")
        d.setVolatile("there")
        XCTAssertEqual(d.text, "Hi there")
        d.commit("there")
        d.setVolatile("friend")
        XCTAssertEqual(d.text, "Hi there friend", "one space between the spoken pieces, none doubled")
    }

    func testBaseOfOnlySpacesGetsNoJoinerBecauseItEndsInWhitespace() {
        var d = DictationDraft(base: "   ")
        d.commit("x")
        XCTAssertEqual(d.text, "   x")
    }

    // MARK: - DictationDraft: volatile and committed words

    func testVolatileUpdatesReplaceEachOther() {
        var d = DictationDraft(base: "")
        d.setVolatile("hel")
        XCTAssertEqual(d.text, "hel")
        d.setVolatile("hello")
        XCTAssertEqual(d.text, "hello")
        d.setVolatile("hi")
        XCTAssertEqual(d.text, "hi", "the volatile words are replaced, not appended")
        XCTAssertEqual(d.volatile, "hi")
        XCTAssertEqual(d.committed, "")
    }

    func testCommitsAccumulateAndDropTheVolatileWords() {
        var d = DictationDraft(base: "")
        d.commit("one")
        d.commit("two")
        d.setVolatile("thr")
        XCTAssertEqual(d.text, "one two thr")
        XCTAssertEqual(d.committed, "one two")
        d.commit("three")
        XCTAssertEqual(d.text, "one two three")
        XCTAssertEqual(d.volatile, "", "a commit clears the volatile words")
    }

    func testFinalResultReplacesItsVolatileWords() {
        var d = DictationDraft(base: "")
        d.setVolatile("abc")
        d.commit("abcdef")
        XCTAssertEqual(d.text, "abcdef", "the volatile 'abc' is not kept beside the final 'abcdef'")
    }

    func testEmptyCommitAddsNoSpace() {
        var d = DictationDraft(base: "")
        d.commit("a")
        d.commit("   ")
        XCTAssertEqual(d.committed, "a")
        XCTAssertEqual(d.text, "a")
        XCTAssertTrue(d.hasWords)
    }

    func testEmptyVolatileIsNotWords() {
        var d = DictationDraft(base: "Base")
        d.setVolatile("")
        XCTAssertFalse(d.hasWords)
        XCTAssertEqual(d.text, "Base")
    }

    func testRealFinalsWithALeadingSpaceJoinCleanly() {
        // SpeechTranscriber's finals start with a space.
        var d = DictationDraft(base: "Say")
        d.commit(" hello")
        d.commit(" world")
        XCTAssertEqual(d.text, "Say hello world")
    }

    // MARK: - DictationDraft: one line

    func testNewlinesBecomeSpaces() {
        var d = DictationDraft(base: "")
        d.setVolatile("one\ntwo")
        XCTAssertEqual(d.text, "one two")
        var e = DictationDraft(base: "")
        e.commit("a\r\nb")
        XCTAssertEqual(e.text, "a b", "\\r\\n is one character, and it becomes one space")
        e.setVolatile("c\nd")
        XCTAssertEqual(e.text, "a b c d")
    }

    func testCarriageReturnAndOtherLineBreaksBecomeSpaces() {
        XCTAssertEqual(DictationDraft.oneLine("a\rb"), "a b")
        XCTAssertEqual(DictationDraft.oneLine("a\u{2028}b"), "a b", "the Unicode line separator")
        XCTAssertEqual(DictationDraft.oneLine("a\u{0085}b"), "a b", "the next-line character")
    }

    func testWhitespaceRunsCollapseToOneSpace() {
        XCTAssertEqual(DictationDraft.oneLine("a   b\t\tc"), "a b c")
        XCTAssertEqual(DictationDraft.oneLine("a \n \n b"), "a b")
        XCTAssertEqual(DictationDraft.oneLine("a\n\n\nb"), "a b")
    }

    func testResultsAreTrimmed() {
        XCTAssertEqual(DictationDraft.oneLine("  x  "), "x")
        XCTAssertEqual(DictationDraft.oneLine("\n\tx\n"), "x")
        XCTAssertEqual(DictationDraft.oneLine(""), "")
        XCTAssertEqual(DictationDraft.oneLine(" \n "), "")
        XCTAssertEqual(DictationDraft.oneLine("x"), "x")
    }

    func testCommittedTextNeverHoldsANewlineWhenTheBaseHasNone() {
        var d = DictationDraft(base: "")
        d.commit("first\nline")
        d.commit("\r\nsecond\n")
        d.setVolatile("third\r\n")
        XCTAssertFalse(d.text.unicodeScalars.contains("\n"))
        XCTAssertFalse(d.text.unicodeScalars.contains("\r"))
        XCTAssertEqual(d.text, "first line second third")
    }

    /// Many sequences of noisy results, with and without a base. The dictated part never has a line break,
    /// so a dictated update can't equal the old draft plus "\n" (the Return key trap).
    func testManyRandomSequencesNeverPutALineBreakInTheDictatedPart() {
        let pieces = ["a", "b", "word", " ", "  ", "\n", "\r\n", "\r", "\t", "\u{2028}", "\u{0085}", "é", "", " x ", "y\nz", "\n\n"]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for base in ["", "Hi", "Hi ", "Hi\n"] {
            for _ in 0..<60 {
                var d = DictationDraft(base: base)
                for _ in 0..<12 {
                    let piece = pieces[next(pieces.count)]
                    if next(2) == 0 { d.setVolatile(piece) } else { d.commit(piece) }
                    let dictated = String(d.text.dropFirst(base.count))
                    XCTAssertFalse(dictated.unicodeScalars.contains("\n"), "dictated part: \(dictated.debugDescription)")
                    XCTAssertFalse(dictated.unicodeScalars.contains("\r"), "dictated part: \(dictated.debugDescription)")
                    XCTAssertFalse(d.spoken.unicodeScalars.contains("\n"))
                    XCTAssertFalse(d.spoken.hasPrefix(" "), "no leading space in the words")
                    XCTAssertFalse(d.spoken.hasSuffix(" "), "no trailing space in the words")
                    XCTAssertFalse(base.isEmpty && d.text.hasSuffix("\n"), "a dictated update can't end in Return")
                }
            }
        }
    }

    // MARK: - DictationDraft: finish

    func testFinishReturnsTheTextAndChangesNothing() {
        var d = DictationDraft(base: "Keep")
        d.commit("this")
        d.setVolatile("and th")
        let before = d
        XCTAssertEqual(d.finish(), "Keep this and th", "the words still changing stay as they stand")
        XCTAssertEqual(d, before, "finish does not change the draft")
        XCTAssertEqual(d.volatile, "and th")
    }

    // MARK: - DictationGuard

    func testUserEditedWhenTheBoxNoLongerHoldsWhatDictationWrote() {
        XCTAssertFalse(DictationGuard.userEdited(current: "hello", lastWritten: "hello"))
        XCTAssertTrue(DictationGuard.userEdited(current: "hello!", lastWritten: "hello"), "typed after")
        XCTAssertTrue(DictationGuard.userEdited(current: "hell", lastWritten: "hello"), "deleted")
        XCTAssertTrue(DictationGuard.userEdited(current: "hello ", lastWritten: "hello"), "a space is an edit")
        XCTAssertFalse(DictationGuard.userEdited(current: "", lastWritten: ""))
        XCTAssertTrue(DictationGuard.userEdited(current: "x", lastWritten: ""))
    }

    // MARK: - DictationEngineChoice.pick

    private func pick(os: Int = 26, transcriber: Bool = true, transcriberLocale: Bool = true,
                      dictationLocale: Bool = true, sfLocale: Bool = true, sfOnDevice: Bool = true,
                      sfAvailable: Bool = true, language: String = "English (UK)") -> DictationEngineChoice {
        DictationEngineChoice.pick(osMajor: os, transcriberAvailable: transcriber, transcriberSupportsLocale: transcriberLocale,
                                   dictationSupportsLocale: dictationLocale, sfSupportsLocale: sfLocale,
                                   sfOnDevice: sfOnDevice, sfAvailable: sfAvailable, language: language)
    }

    func testTheAnalyzerMajorIsMacOS26() {
        XCTAssertEqual(DictationEngineChoice.analyzerMajor, 26)
    }

    func testOrderOnMacOS26PrefersSpeechTranscriberFirst() {
        XCTAssertEqual(pick(), .speechTranscriber, "everything available: SpeechTranscriber")
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: true), .dictationTranscriber,
                       "transcriber not available, dictation supports the locale: DictationTranscriber")
    }

    func testSpeechTranscriberNeedsBothAvailabilityAndLocale() {
        XCTAssertEqual(pick(transcriber: true, transcriberLocale: false), .dictationTranscriber)
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: true), .dictationTranscriber)
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: false), .dictationTranscriber)
        XCTAssertEqual(pick(transcriber: true, transcriberLocale: true, dictationLocale: false), .speechTranscriber)
    }

    func testDictationTranscriberNeedsItsLocale() {
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: false, dictationLocale: false), .recognizerOnDevice,
                       "neither transcriber can, so the on-device recognizer")
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: false, dictationLocale: false, sfOnDevice: false), .recognizerServer)
    }

    func testOnDeviceRecognizerBeforeTheServerRecognizer() {
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: false, dictationLocale: false, sfOnDevice: true), .recognizerOnDevice)
        XCTAssertEqual(pick(transcriber: false, transcriberLocale: false, dictationLocale: false, sfOnDevice: false), .recognizerServer,
                       "decision D1: Apple's speech service only when the Mac can't do it")
    }

    func testBelowMacOS26TheTranscriberFlagsAreIgnored() {
        // Every transcriber input says yes; the older OS still uses the recognizer.
        XCTAssertEqual(pick(os: 25), .recognizerOnDevice)
        XCTAssertEqual(pick(os: 15), .recognizerOnDevice)
        XCTAssertEqual(pick(os: 12, sfOnDevice: false), .recognizerServer)
        XCTAssertEqual(pick(os: 25, transcriber: false, transcriberLocale: false, dictationLocale: false), .recognizerOnDevice)
    }

    func testBelowMacOS26TheTranscriberLocalesDoNotCount() {
        let r = pick(os: 25, sfLocale: false, sfAvailable: false)
        XCTAssertEqual(r, .unavailable(.language("English (UK)")),
                       "the transcribers can't be used below 26, so the language is not supported here")
    }

    func testBoundaryIsExactlyMacOS26() {
        XCTAssertEqual(pick(os: 25), .recognizerOnDevice)
        XCTAssertEqual(pick(os: 26), .speechTranscriber)
        XCTAssertEqual(pick(os: 27), .speechTranscriber)
    }

    func testRecognizerServerWhenTheLanguageIsOnlyOnAppleServer() {
        XCTAssertEqual(pick(os: 15, sfOnDevice: false), .recognizerServer)
        XCTAssertEqual(pick(os: 26, transcriber: false, transcriberLocale: false, dictationLocale: false, sfOnDevice: false), .recognizerServer)
    }

    func testLanguageNoPathKnowsIsTheLanguageLine() {
        XCTAssertEqual(pick(os: 26, transcriber: false, transcriberLocale: false, dictationLocale: false, sfLocale: false, language: "Afrikaans"),
                       .unavailable(.language("Afrikaans")))
        XCTAssertEqual(pick(os: 15, sfLocale: false, language: "Afrikaans"), .unavailable(.language("Afrikaans")))
        XCTAssertEqual(pick(os: 26, transcriberLocale: false, dictationLocale: false, sfLocale: false, sfAvailable: true, language: "Hmong"),
                       .unavailable(.language("Hmong")), "a recognizer that isn't there does not count as knowing the language")
    }

    func testLanguageSomePathKnowsButNothingCanRunIsNoRecognizer() {
        // The Mac has the language, but no recognizer can run it: the "no recognizer" line, not the language line.
        XCTAssertEqual(pick(os: 15, sfAvailable: false, language: "Afrikaans"), .unavailable(.noRecognizer))
        XCTAssertEqual(pick(os: 26, transcriber: false, transcriberLocale: false, dictationLocale: false, sfAvailable: false, language: "Afrikaans"),
                       .unavailable(.noRecognizer))
        XCTAssertEqual(pick(os: 26, transcriber: false, transcriberLocale: true, dictationLocale: false, sfLocale: false,
                            sfAvailable: false, language: "Afrikaans"),
                       .unavailable(.noRecognizer), "SpeechTranscriber knows the language, but is not available")
    }

    func testSfUnavailableStillUsesAnalyzerWhenItCan() {
        XCTAssertEqual(pick(sfAvailable: false), .speechTranscriber)
    }

    func testTheLanguageNameIsCarriedThroughToTheLine() {
        XCTAssertEqual(pick(os: 15, sfLocale: false, language: "Swahili"), .unavailable(.language("Swahili")))
    }

    func testEveryCombinationKeepsTheInvariants() {
        var counts: [String: Int] = [:]
        for os in [12, 15, 25, 26, 27] {
            for bits in 0..<128 {
                let t = bits & 1 != 0, tl = bits & 2 != 0, dl = bits & 4 != 0
                let sl = bits & 8 != 0, son = bits & 16 != 0, sa = bits & 32 != 0
                let r = pick(os: os, transcriber: t, transcriberLocale: tl, dictationLocale: dl, sfLocale: sl,
                             sfOnDevice: son, sfAvailable: sa, language: "L")
                let analyzer = os >= 26
                switch r {
                case .speechTranscriber:
                    XCTAssertTrue(analyzer && t && tl)
                    counts["transcriber", default: 0] += 1
                case .dictationTranscriber:
                    XCTAssertTrue(analyzer && dl)
                    counts["dictation", default: 0] += 1
                case .recognizerOnDevice:
                    XCTAssertTrue(sl && sa && son)
                    counts["onDevice", default: 0] += 1
                case .recognizerServer:
                    XCTAssertTrue(sl && sa && !son)
                    counts["server", default: 0] += 1
                case .unavailable(let why):
                    XCTAssertFalse(analyzer && (t && tl || dl) || sl && sa, "a usable engine was there")
                    if case .language = why { XCTAssertFalse(sl || (analyzer && (tl || dl))) }
                    counts["unavailable", default: 0] += 1
                }
                XCTAssertEqual(r.isOnDevice, r == .speechTranscriber || r == .dictationTranscriber || r == .recognizerOnDevice)
            }
        }
        XCTAssertGreaterThan(counts["transcriber", default: 0], 0)
        XCTAssertGreaterThan(counts["server", default: 0], 0)
        XCTAssertGreaterThan(counts["unavailable", default: 0], 0)
    }

    func testIsOnDeviceOnlyForTheOnDevicePaths() {
        XCTAssertTrue(DictationEngineChoice.speechTranscriber.isOnDevice)
        XCTAssertTrue(DictationEngineChoice.dictationTranscriber.isOnDevice)
        XCTAssertTrue(DictationEngineChoice.recognizerOnDevice.isOnDevice)
        XCTAssertFalse(DictationEngineChoice.recognizerServer.isOnDevice)
        XCTAssertFalse(DictationEngineChoice.unavailable(.noRecognizer).isOnDevice)
        XCTAssertFalse(DictationEngineChoice.unavailable(.language("x")).isOnDevice)
    }

    // MARK: - DictationLocale.nearest

    func testSameIdentifierWithAnyHyphenOrUnderscoreMatches() {
        XCTAssertEqual(DictationLocale.nearest(to: "en_GB", in: ["en_US", "en_GB"]), "en_GB")
        XCTAssertEqual(DictationLocale.nearest(to: "en-GB", in: ["en_GB"]), "en_GB")
        XCTAssertEqual(DictationLocale.nearest(to: "en_gb", in: ["en_GB"]), "en_GB", "case does not matter")
        XCTAssertEqual(DictationLocale.nearest(to: "en_US", in: ["en"]), "en", "a bare language is a language, the same one")
    }

    func testSameLanguageAndRegionWhenTheScriptDiffers() {
        XCTAssertEqual(DictationLocale.nearest(to: "zh-Hans_CN", in: ["zh_TW", "zh_HK", "zh_CN"]), "zh_CN")
        XCTAssertEqual(DictationLocale.nearest(to: "zh_Hant_TW", in: ["zh_Hans_CN", "zh_TW"]), "zh_TW")
    }

    func testSameLanguageOtherRegionThenFirstInSortOrder() {
        XCTAssertEqual(DictationLocale.nearest(to: "en_AU", in: ["en_US", "en_GB"]), "en_GB",
                       "no AU, so the first en by sort order (en_GB before en_US)")
        XCTAssertEqual(DictationLocale.nearest(to: "en_GB", in: ["fr_GB", "en_US"]), "en_US",
                       "same language beats same region in another language")
        XCTAssertEqual(DictationLocale.nearest(to: "en_GB", in: ["en_US", "en"]), "en", "sorted: \"en\" comes first")
    }

    func testNoSupportedLanguageIsNil() {
        XCTAssertNil(DictationLocale.nearest(to: "sw_KE", in: ["en_US", "fr_FR"]))
        XCTAssertNil(DictationLocale.nearest(to: "en_GB", in: []))
    }

    func testTheSettingAfterAtIsNotARegion() {
        XCTAssertEqual(DictationLocale.nearest(to: "en_US@calendar=gregorian", in: ["en_US"]), "en_US")
        XCTAssertEqual(DictationLocale.parts("en_US@calendar=gregorian").region, "US")
        XCTAssertEqual(DictationLocale.parts("en@calendar=gregorian").region, nil)
    }

    func testPartsOfCommonIdentifiers() {
        func parts(_ s: String) -> String { let p = DictationLocale.parts(s); return "\(p.language)|\(p.region ?? "-")" }
        XCTAssertEqual(parts("en_GB"), "en|GB")
        XCTAssertEqual(parts("en-gb"), "en|GB")
        XCTAssertEqual(parts("en"), "en|-")
        XCTAssertEqual(parts("zh-Hans_CN"), "zh|CN", "a four-letter script is not a region")
        XCTAssertEqual(parts("sr-Latn"), "sr|-")
        XCTAssertEqual(parts("es_419"), "es|419", "a three-digit region")
        XCTAssertEqual(parts("de_CH_1996"), "de|CH")
        XCTAssertEqual(parts("ca_ES_VALENCIA"), "ca|ES")
        XCTAssertEqual(parts(""), "|-")
    }

    // MARK: - DictationLevel

    func testLevelMapsDecibelsToZeroToOne() {
        XCTAssertEqual(DictationLevel.level(rms: 0), 0)
        XCTAssertEqual(DictationLevel.level(rms: -0.5), 0, "not a level")
        XCTAssertEqual(DictationLevel.level(rms: .nan), 0)
        XCTAssertEqual(DictationLevel.level(rms: .infinity), 0)
        XCTAssertEqual(DictationLevel.level(rms: 0.001), 0, "-60 dB, below the floor")
        XCTAssertEqual(DictationLevel.level(rms: 0.01), 0.375, accuracy: 1e-9, "-40 dB")
        XCTAssertEqual(DictationLevel.level(rms: 0.1), 0.875, accuracy: 1e-9, "-20 dB")
        XCTAssertEqual(DictationLevel.level(rms: 0.1778279410038923), 1, accuracy: 1e-9, "-15 dB is the top")
        XCTAssertEqual(DictationLevel.level(rms: 1), 1, "0 dB is clamped to 1")
        XCTAssertEqual(DictationLevel.level(rms: 3), 1, "above full scale is clamped")
    }

    func testLevelRisesWithVoice() {
        let steps: [Double] = [0.0005, 0.002, 0.005, 0.02, 0.05, 0.2, 0.5, 1]
        let levels = steps.map(DictationLevel.level(rms:))
        XCTAssertEqual(levels, levels.sorted(), "louder never shows a smaller bar")
    }

    func testSmoothedRisesAtOnceAndFallsALittleAtATime() {
        XCTAssertEqual(DictationLevel.smoothed(previous: 0.5, next: 0.9), 0.9, "rises at once")
        XCTAssertEqual(DictationLevel.smoothed(previous: 1.0, next: 0.85), 0.85, "a small fall is taken as it is")
        XCTAssertEqual(DictationLevel.smoothed(previous: 1.0, next: 0.2), 0.8, accuracy: 1e-9, "falls by at most 20 %")
        XCTAssertEqual(DictationLevel.smoothed(previous: 0.5, next: 0.45), 0.45)
        XCTAssertEqual(DictationLevel.smoothed(previous: 0, next: 0), 0)
        XCTAssertEqual(DictationLevel.smoothed(previous: 0.5, next: 0), 0.4, accuracy: 1e-9)
    }

    func testSmoothedDecaysGeometrically() {
        var v = 1.0
        var trail: [Double] = []
        for _ in 0..<3 { v = DictationLevel.smoothed(previous: v, next: 0); trail.append(v) }
        XCTAssertEqual(trail[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(trail[1], 0.64, accuracy: 1e-9)
        XCTAssertEqual(trail[2], 0.512, accuracy: 1e-9)
    }

    // MARK: - DictationClock

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testSilenceStopsAtTwentySecondsNotBefore() {
        let c = DictationClock(startedAt: t0)
        XCTAssertNil(c.expiry(at: t0.addingTimeInterval(19.9)), "not yet at 19.9 s")
        XCTAssertEqual(c.expiry(at: t0.addingTimeInterval(20)), .silence, "at 20 s")
        XCTAssertEqual(c.expiry(at: t0.addingTimeInterval(120)), .silence)
    }

    func testNewWordsResetTheSilence() {
        var c = DictationClock(startedAt: t0)
        c.heardWords(at: t0.addingTimeInterval(19))
        XCTAssertNil(c.expiry(at: t0.addingTimeInterval(38.9)), "20 s counted from the last words")
        XCTAssertEqual(c.expiry(at: t0.addingTimeInterval(39)), .silence)
        XCTAssertEqual(c.lastWordsAt, t0.addingTimeInterval(19))
    }

    func testAnEarlierTimeDoesNotMoveTheLastWords() {
        var c = DictationClock(startedAt: t0)
        c.heardWords(at: t0.addingTimeInterval(10))
        c.heardWords(at: t0.addingTimeInterval(5))
        XCTAssertEqual(c.lastWordsAt, t0.addingTimeInterval(10))
        XCTAssertEqual(c.silenceDeadline, t0.addingTimeInterval(30))
    }

    func testTheCapStopsAtTenMinutesEvenWhileWordsKeepComing() {
        var c = DictationClock(startedAt: t0)
        XCTAssertEqual(c.capDeadline, t0.addingTimeInterval(600))
        c.heardWords(at: t0.addingTimeInterval(580))
        XCTAssertNil(c.expiry(at: t0.addingTimeInterval(599.9)))
        c.heardWords(at: t0.addingTimeInterval(599))
        XCTAssertNil(c.expiry(at: t0.addingTimeInterval(599.9)), "the silence is reset by the 599 s words")
        XCTAssertEqual(c.expiry(at: t0.addingTimeInterval(600)), .cap, "the cap is reached though words keep arriving")
    }

    func testTheCapWinsWhenBothAreDue() {
        var c = DictationClock(startedAt: t0)
        c.heardWords(at: t0.addingTimeInterval(580))
        XCTAssertEqual(c.silenceDeadline, t0.addingTimeInterval(600))
        XCTAssertEqual(c.expiry(at: t0.addingTimeInterval(600)), .cap, "same instant: cap, not silence")
        let silentFromStart = DictationClock(startedAt: t0)
        XCTAssertEqual(silentFromStart.expiry(at: t0.addingTimeInterval(700)), .cap, "silence was also due long before")
    }

    func testNextDeadlineIsTheSoonerLimit() {
        var c = DictationClock(startedAt: t0)
        XCTAssertEqual(c.nextDeadline, t0.addingTimeInterval(20))
        c.heardWords(at: t0.addingTimeInterval(10))
        XCTAssertEqual(c.nextDeadline, t0.addingTimeInterval(30), "moves later with words")
        c.heardWords(at: t0.addingTimeInterval(595))
        XCTAssertEqual(c.nextDeadline, t0.addingTimeInterval(600), "the cap is sooner now")
    }

    func testNoExpiryBeforeAnyLimit() {
        var c = DictationClock(startedAt: t0)
        for s in stride(from: 0.0, to: 19.5, by: 0.5) {
            XCTAssertNil(c.expiry(at: t0.addingTimeInterval(s)))
        }
        c.heardWords(at: t0.addingTimeInterval(1))
        XCTAssertNil(c.expiry(at: t0.addingTimeInterval(20.5)))
    }

    // MARK: - DictationPhase

    func testPhaseHelpers() {
        XCTAssertFalse(DictationPhase.idle.isActive)
        XCTAssertFalse(DictationPhase.idle.isListening)
        XCTAssertFalse(DictationPhase.idle.isBlocked)
        XCTAssertEqual(DictationPhase.idle.level, 0)

        XCTAssertTrue(DictationPhase.preparing.isActive)
        XCTAssertFalse(DictationPhase.preparing.isListening)
        XCTAssertFalse(DictationPhase.preparing.isBlocked)

        XCTAssertTrue(DictationPhase.downloading(fraction: nil).isActive, "a download is part of starting")
        XCTAssertTrue(DictationPhase.downloading(fraction: 0.5).isActive)
        XCTAssertFalse(DictationPhase.downloading(fraction: 0.5).isBlocked)

        let heard = DictationPhase.listening(level: 0.4, onDevice: true)
        XCTAssertTrue(heard.isListening)
        XCTAssertTrue(heard.isActive)
        XCTAssertFalse(heard.isBlocked)
        XCTAssertEqual(heard.level, 0.4)
        XCTAssertEqual(DictationPhase.listening(level: 0.9, onDevice: false).level, 0.9)

        XCTAssertTrue(DictationPhase.denied(.microphone).isBlocked)
        XCTAssertTrue(DictationPhase.denied(.speech).isBlocked)
        XCTAssertFalse(DictationPhase.denied(.speech).isActive)
        XCTAssertTrue(DictationPhase.unavailable(.noRecognizer).isBlocked)
        XCTAssertFalse(DictationPhase.unavailable(.language("x")).isActive)
        XCTAssertFalse(DictationPhase.interrupted.isActive, "interrupted: the mic is closed, the button is not a stop")
        XCTAssertFalse(DictationPhase.interrupted.isBlocked)
        XCTAssertEqual(DictationPhase.interrupted.level, 0)
    }

    // MARK: - DictationCopy: lines

    private let lang = "English (UK)"

    func testIdleHasNoLine() {
        XCTAssertNil(DictationCopy.line(for: .idle, language: lang))
    }

    func testPreparingLine() {
        let line = DictationCopy.line(for: .preparing, language: lang)
        XCTAssertEqual(line?.text, "Getting ready to listen…")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertEqual(line?.opensSettings, false)
        XCTAssertNil(line?.progress)
    }

    func testDownloadingWithoutAFractionHasNoPercentOrBar() {
        let line = DictationCopy.line(for: .downloading(fraction: nil), language: lang)
        XCTAssertEqual(line?.text, "Getting English (UK) speech for this Mac…")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertNil(line?.progress)
    }

    func testDownloadingWithAFractionShowsPercentAndBar() {
        let line = DictationCopy.line(for: .downloading(fraction: 0.404), language: lang)
        XCTAssertEqual(line?.text, "Getting English (UK) speech for this Mac · 40%")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertEqual(line?.progress ?? -1, 0.404, accuracy: 1e-12)
        XCTAssertEqual(line?.opensSettings, false)
    }

    func testListeningOnDeviceLine() {
        let line = DictationCopy.line(for: .listening(level: 0.5, onDevice: true), language: lang)
        XCTAssertEqual(line?.text, "Listening on this Mac · nothing is sent until you press Return")
        XCTAssertEqual(line?.tone, .listening)
        XCTAssertEqual(line?.opensSettings, false)
        XCTAssertNil(line?.progress)
    }

    func testListeningOnAppleServerLineSaysSo() {
        let line = DictationCopy.line(for: .listening(level: 0, onDevice: false), language: lang)
        XCTAssertEqual(line?.text, "Listening with Apple's speech service · nothing is sent until you press Return")
        XCTAssertEqual(line?.tone, .listening)
    }

    func testListeningLineDoesNotChangeWithTheLevel() {
        XCTAssertEqual(DictationCopy.line(for: .listening(level: 0, onDevice: true), language: lang),
                       DictationCopy.line(for: .listening(level: 1, onDevice: true), language: lang))
    }

    func testMicrophoneOffLine() {
        let line = DictationCopy.line(for: .denied(.microphone), language: lang)
        XCTAssertEqual(line?.text, "Page can't hear you: microphone access is off for Page Studio.")
        XCTAssertEqual(line?.tone, .problem)
        XCTAssertEqual(line?.opensSettings, true)
        XCTAssertNil(line?.progress)
    }

    func testSpeechRecognitionOffLine() {
        let line = DictationCopy.line(for: .denied(.speech), language: lang)
        XCTAssertEqual(line?.text, "Speech recognition is off for Page Studio.")
        XCTAssertEqual(line?.tone, .problem)
        XCTAssertEqual(line?.opensSettings, true)
    }

    func testLanguageLine() {
        let line = DictationCopy.line(for: .unavailable(.language("Afrikaans")), language: lang)
        XCTAssertEqual(line?.text, "Speech in Afrikaans can't be turned into text on this Mac.")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertEqual(line?.opensSettings, false)
    }

    func testNoRecognizerLine() {
        let line = DictationCopy.line(for: .unavailable(.noRecognizer), language: lang)
        XCTAssertEqual(line?.text, "This Mac has no speech recognizer, so the mic is off.")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertEqual(line?.opensSettings, false)
    }

    func testInterruptedLine() {
        let line = DictationCopy.line(for: .interrupted, language: lang)
        XCTAssertEqual(line?.text, "Stopped listening. Your words are kept.")
        XCTAssertEqual(line?.tone, .quiet)
        XCTAssertEqual(line?.opensSettings, false)
    }

    func testOnlyTheProblemLinesOpenSettings() {
        let phases: [DictationPhase] = [.idle, .preparing, .downloading(fraction: 0.2), .listening(level: 0.3, onDevice: true),
                                        .denied(.microphone), .denied(.speech), .unavailable(.noRecognizer),
                                        .unavailable(.language("x")), .interrupted]
        let opening = phases.filter { DictationCopy.line(for: $0, language: lang)?.opensSettings == true }
        XCTAssertEqual(opening, [.denied(.microphone), .denied(.speech)])
    }

    func testListeningToneOnlyForTheListeningLine() {
        XCTAssertEqual(DictationCopy.line(for: .listening(level: 0, onDevice: false), language: lang)?.tone, .listening)
        XCTAssertEqual(DictationCopy.line(for: .preparing, language: lang)?.tone, .quiet)
        XCTAssertEqual(DictationCopy.line(for: .denied(.speech), language: lang)?.tone, .problem)
    }

    // MARK: - DictationCopy: strings and percent

    func testCopyStrings() {
        XCTAssertEqual(DictationCopy.device, "Mac")
        XCTAssertEqual(DictationCopy.micLabel, "Dictate")
        XCTAssertEqual(DictationCopy.stopLabel, "Stop dictating")
        XCTAssertEqual(DictationCopy.listeningPlaceholder, "Listening…")
        XCTAssertEqual(DictationCopy.openSettings, "Open Settings")
        XCTAssertEqual(DictationCopy.listening(onDevice: true), "Listening on this Mac · nothing is sent until you press Return")
        XCTAssertEqual(DictationCopy.listening(onDevice: false), "Listening with Apple's speech service · nothing is sent until you press Return")
        XCTAssertEqual(DictationCopy.language("Swahili"), "Speech in Swahili can't be turned into text on this Mac.")
        XCTAssertEqual(DictationCopy.downloading(language: "Swahili", fraction: nil), "Getting Swahili speech for this Mac…")
    }

    func testHelpStringsNameCommandDNotOptionCommandD() {
        XCTAssertEqual(DictationCopy.micHelp, "Dictate · ⌘D · nothing is sent until you press Return")
        XCTAssertEqual(DictationCopy.stopHelp, "Stop dictating · ⌘D · your words stay in the box")
        for help in [DictationCopy.micHelp, DictationCopy.stopHelp] {
            XCTAssertTrue(help.contains("⌘D"))
            XCTAssertFalse(help.contains("⌥"), "macOS takes ⌥⌘D for Dock hiding")
        }
    }

    func testPercentRoundsDownToAWholeNumber() {
        XCTAssertEqual(DictationCopy.percent(0.404), "40%")
        XCTAssertEqual(DictationCopy.percent(0.5), "50%")
        XCTAssertEqual(DictationCopy.percent(0.999), "99%", "rounds down, so a download never reads 100 % early")
        XCTAssertEqual(DictationCopy.percent(0), "0%")
        XCTAssertEqual(DictationCopy.percent(1), "100%")
    }

    func testPercentClamps() {
        XCTAssertEqual(DictationCopy.percent(-0.2), "0%")
        XCTAssertEqual(DictationCopy.percent(1.7), "100%")
        XCTAssertEqual(DictationCopy.percent(-1e9), "0%")
        XCTAssertEqual(DictationCopy.percent(1e9), "100%")
    }

    // MARK: - DictationKeys

    private func press(_ key: NowKeyPress.Key, command: Bool = false, option: Bool = false, control: Bool = false,
                       repeating: Bool = false, up: Bool = false) -> NowKeyPress {
        NowKeyPress(key: key, phase: up ? .up : .down, command: command, option: option, control: control, isRepeat: repeating)
    }

    func testCommandDTogglesOnlyWithTheComposerOpen() {
        let cmdD = press(.char("d"), command: true)
        XCTAssertEqual(DictationKeys.action(for: cmdD, composerOpen: true, dictating: false), .toggle, "start")
        XCTAssertEqual(DictationKeys.action(for: cmdD, composerOpen: true, dictating: true), .toggle, "stop")
        XCTAssertNil(DictationKeys.action(for: cmdD, composerOpen: false, dictating: false))
        XCTAssertNil(DictationKeys.action(for: cmdD, composerOpen: false, dictating: true))
    }

    func testCommandDRepeatAndKeyUpGiveNothing() {
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, repeating: true), composerOpen: true, dictating: false),
                     "holding ⌘D does not start and stop")
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, up: true), composerOpen: true, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, up: true), composerOpen: true, dictating: false))
    }

    func testOptionAndControlCommandDAreNotOurs() {
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, option: true), composerOpen: true, dictating: false),
                     "⌥⌘D is Dock hiding")
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, control: true), composerOpen: true, dictating: false))
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), command: true, option: true, control: true), composerOpen: true, dictating: true))
    }

    func testPlainDIsTypingNotDictation() {
        XCTAssertNil(DictationKeys.action(for: press(.char("d")), composerOpen: true, dictating: false))
        XCTAssertNil(DictationKeys.action(for: press(.char("d"), option: true), composerOpen: true, dictating: false))
        XCTAssertNil(DictationKeys.action(for: press(.char("n"), command: true), composerOpen: true, dictating: false))
    }

    func testEscStopsOnlyWhileDictating() {
        XCTAssertEqual(DictationKeys.action(for: press(.esc), composerOpen: true, dictating: true), .stopListening)
        XCTAssertNil(DictationKeys.action(for: press(.esc), composerOpen: true, dictating: false),
                     "not listening: the existing Esc closes the box")
    }

    func testEscWithModifiersIsNotOurs() {
        XCTAssertNil(DictationKeys.action(for: press(.esc, command: true), composerOpen: true, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.esc, option: true), composerOpen: true, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.esc, control: true), composerOpen: true, dictating: true))
    }

    func testEscKeyUpIsNotOurs() {
        XCTAssertNil(DictationKeys.action(for: press(.esc, up: true), composerOpen: true, dictating: true))
    }

    func testEscWithTheComposerClosedIsNotOurs() {
        XCTAssertNil(DictationKeys.action(for: press(.esc), composerOpen: false, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.esc), composerOpen: false, dictating: false))
    }

    func testReturnSendsWithTheComposerOpen() {
        XCTAssertEqual(DictationKeys.action(for: press(.ret), composerOpen: true, dictating: true), .stopForSend)
        XCTAssertEqual(DictationKeys.action(for: press(.ret), composerOpen: true, dictating: false), .stopForSend)
    }

    func testReturnWithTheComposerClosedOrWithModifiersIsNotOurs() {
        XCTAssertNil(DictationKeys.action(for: press(.ret), composerOpen: false, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.ret), composerOpen: false, dictating: false))
        XCTAssertNil(DictationKeys.action(for: press(.ret, command: true), composerOpen: true, dictating: true))
        XCTAssertNil(DictationKeys.action(for: press(.ret, option: true), composerOpen: true, dictating: false))
        XCTAssertNil(DictationKeys.action(for: press(.ret, up: true), composerOpen: true, dictating: true))
    }

    func testClosedComposerGivesNothingForAnyKey() {
        let keys: [NowKeyPress] = [press(.char("d"), command: true), press(.esc), press(.ret), press(.up), press(.down),
                                   press(.char("x")), press(.delete), press(.char("."), command: true)]
        for k in keys {
            XCTAssertNil(DictationKeys.action(for: k, composerOpen: false, dictating: true), "\(k)")
            XCTAssertNil(DictationKeys.action(for: k, composerOpen: false, dictating: false), "\(k)")
        }
    }

    func testOtherKeysAreNotDictationKeysWithTheComposerOpen() {
        for k in [press(.up), press(.down), press(.delete), press(.char("x")), press(.char("1")), press(.char("t"))] {
            XCTAssertNil(DictationKeys.action(for: k, composerOpen: true, dictating: true), "\(k)")
        }
    }

    // MARK: - The shortcuts sheet

    func testShortcutsSheetListsDictationOnCommandD() {
        let items = ShortcutCatalog.groups.flatMap(\.items)
        let dictation = items.first { $0.title == "Dictate into the Steer box" }
        XCTAssertNotNil(dictation)
        XCTAssertEqual(dictation?.keys, ["⌘", "D"])
        XCTAssertEqual(ShortcutCatalog.groups.first { $0.items.contains { $0.title == "Dictate into the Steer box" } }?.title,
                       "IN THE NOW PANEL")
    }

    func testShortcutsSheetNeverListsOptionCommandD() {
        let all = ShortcutCatalog.groups.flatMap(\.items)
        XCTAssertFalse(all.contains { $0.keys == ["⌥", "⌘", "D"] })
        XCTAssertFalse(all.contains { $0.keys.contains("⌥") && $0.keys.contains("D") })
    }
}
