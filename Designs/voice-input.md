# Speak instead of type: voice input in the phone apps

Branch `voice-input` (stacked on `budget-caps`). iPhone, Android, and Page Studio on the Mac (decision D2).

## What the user asked (2026-11-13)

> "I need to be able to transcribe in my app so that instead of writing text, I should be able to allow my microphone audio to transcribe from speech to text. This is required for both iOS and Android. On iOS and macOS it's Apple's Speech framework. There's the older SFSpeechRecognizer and the newer SpeechAnalyzer with SpeechTranscriber, which came in with iOS 26. On Android it's SpeechRecognizer in android.speech, and for offline use you'd call createOnDeviceSpeechRecognizer."

## Rules that do not bend

1. **Speaking only fills the box.** Nothing is ever sent by voice. The words land in the draft, the person reads them, and Send is the same Send as before. Saying "send" is just a word.
2. **On the device first; never through Page.** Recognition runs on the device when the device can do it. Otherwise it uses the phone's own speech service (Apple's, or the Android phone's default recognizer, usually Google's), and the line says so the whole time it listens (decision D1). Page never records, keeps or relays audio. Only the text the person sends goes over the relay, as it does today.
3. **Dictated text is one line.** Newlines in a result become spaces, so a dictated update can never look like the Return key (`DraftSubmit.isReturnKey(old:new:)` is `new == old + "\n"`) and send by accident.
4. **One input at a time.** Tapping the mic drops the keyboard. Touching the field, typing, sending, leaving the screen, locking the phone, the app going to the background, or the box locking (`sending`, `locked`, the composer mode turning `.locked`/`.blocked`) stops listening. The words so far are kept.
5. **Nothing the person typed is overwritten.** Spoken words are added after the existing draft. If the draft changes under the dictation (the person edited it), listening stops and the late results are dropped.

## Where the mic goes

Four boxes get a mic. The search and pairing fields do not.

| Box | iOS | Android |
|---|---|---|
| Session room composer | `NWRoomComposer.field` (NWRoom.swift) | `Field` (NWSessionRoom.kt) |
| Reply / deny / answer sheet | `NWDecisionComposer` (NWDecisionSheet.swift) | `Composer` (NWDecisionSheet.kt) |
| "Type your answer" on a question card | `NWAnswerCard` (NWAnswerCard.swift) | `NWAnswerCard.kt` |
| "What should Claude do?" on New task | `NWDispatchScreen` (NWDispatch.swift) | `NWDispatch.kt` |

The mic is its own button, never the Send button. Send keeps its place and its rules. (Swapping the mic and Send in one slot, as some chat apps do, would put Send under the thumb that just tapped stop. Page types into a real terminal, so it doesn't do that.)

```
Room, idle:
╭──────────────────────────────────────────────────────╮
│ [📷]  Message Claude…                     (🎙)  (↑)  │
│       Your message, then Return · cmux › page · Mac  │
╰──────────────────────────────────────────────────────╯

Room, listening:
  ▍▍▌▍▍ Listening on this iPhone · nothing is sent until you tap Send
╭──────────────────────────────────────────────────────╮
│ [📷]  Run the tests again and then tell me (■)  (↑)  │
│       which ones still fail                          │
│       Your message, then Return · cmux › page · Mac  │
╰──────────────────────────────────────────────────────╯
```

### The mic button (`NWMicButton`)

- **Idle.** A 40 pt circle in the room (44 pt in the sheet, the answer card and New task), white 8 % fill, 1 pt white 10 % border, SF Symbol `mic` (Android: `Icons.Outlined.Mic`) in textSecondary. The hit area is at least 44 pt.
- **Getting ready / downloading.** The same circle with a teal progress ring around it: indeterminate while preparing, the real fraction while a language downloads.
- **Listening.** Teal on dark: a 16 % teal fill, a 1.5 pt teal border and a teal stop square, with a soft teal ring outside that grows with the voice level (scale 1.0–1.22). It never takes Send's bright gradient, because the two sit side by side. With Reduce Motion the ring is still.
- **Can't listen** (denied, unavailable). The idle look with `mic.slash`. A tap shows why, in the note above the box.
- **Accessibility.** The label is "Dictate", or "Stop dictating" while listening. The hint is "Your words go into the message box. Nothing is sent until you tap Send." Starting and stopping are announced.
- **Haptics.** A light tap at start and stop (`NWHaptics`).

### The line above the box

One line, in the composer's own column, above the field, in the style of the room's notes:

| State | Line | Tone |
|---|---|---|
| Listening | `▍▍▌▍▍ Listening on this iPhone · nothing is sent until you tap Send` (the bars follow the voice). The last word is the box's own button: Send, Answer, or Start on New task | teal |
| Getting ready | `Getting ready to listen…` | textSecondary |
| Downloading | `Getting English (UK) speech for this iPhone · 40%` with a thin bar. It is a one-off download that iOS or Android keeps, not Page. Listening starts by itself when it is done | textSecondary |
| Microphone off | `Page can't hear you: microphone access is off for Page.` [Open Settings] | amber |
| Speech recognition off (iOS) | `Speech recognition is off for Page.` [Open Settings] | amber |
| Language not on this phone | `Speech in Afrikaans can't be turned into text on this iPhone.` | textSecondary |
| No on-device speech (D1) | `This phone can't turn speech into text on the phone itself, so Page leaves the mic off.` | textSecondary |
| Interrupted | `Stopped listening: something else took the microphone. Your words are kept.` | textSecondary |

"iPhone" reads "phone" on Android (as the rest of the Android copy does), and "iPad" on an iPad. The line goes away by itself 4 s after a stop or an interruption. The Settings notes stay until the next tap.

While listening with an empty draft, the placeholder reads "Listening…", and the quick replies and Yes/No step aside.

## Behaviour

- **Start.** Tap the mic. The keyboard goes down, the permissions are asked for the first time, and a language model is fetched the first time if needed. Then the button turns to stop and the line says Listening.
- **Words.** Each update replaces only the words still changing. Finished words are kept. All of it shows in the field as plain text, so the counter and Send work as usual.
- **Joining.** The first spoken words join an existing draft with one space, unless the draft is empty or already ends in whitespace. Newlines become spaces, and runs of spaces are collapsed.
- **Stop.** Tap stop or any of the triggers in rule 4. The words still changing are finalised (iOS `finalizeAndFinishThroughEndOfInput()`; Android `stopListening()` and the last `onResults`). The keyboard does not come back by itself.
- **Silence.** Listening stops by itself after 20 s with no new words, and after 10 min in all.
- **Language.** The phone's language (`Locale.current`), mapped to the nearest one the engine supports. If none matches, the line says so.
- **One at a time.** The app has one dictation controller. Starting the mic in another box stops the first one.
- **The character limit.** Spoken words count like typed ones. Over `SessionComposer.maxCharacters` the counter turns amber and Send is off, as now.

## Engines

### iOS: one controller, two engines, chosen at run time (deployment target 17.0)

Pinned from the iOS 27.2 SDK `Speech.swiftinterface` on this Mac.

**iOS 26 and later: `SpeechAnalyzer` + `SpeechTranscriber`**
- `guard SpeechTranscriber.isAvailable`, then `let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)`. With no locale, fall back to `DictationTranscriber` (same calls). With neither, use the SFSpeechRecognizer path.
- `let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])`
- Assets: `switch await AssetInventory.status(forModules: [transcriber])`
  - `.installed`: go.
  - `.supported`, `.downloading`: `if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { observe req.progress.fractionCompleted; try await req.downloadAndInstall() }`.
  - `.unsupported`: fall back.
- `let analyzer = SpeechAnalyzer(modules: [transcriber])`; `let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`; `try await analyzer.prepareToAnalyze(in: format)`.
- Audio: `AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)` and `setActive(true)`. Then an `AVAudioEngine` input tap, with `AVAudioConverter` to `format`, yielding `AnalyzerInput(buffer:)` into an `AsyncStream<AnalyzerInput>`, and `try await analyzer.start(inputSequence: stream)`.
- Results: `for try await r in transcriber.results { let s = String(r.text.characters); r.isFinal ? draft.commit(s) : draft.setVolatile(s) }`.
- Stop: stop the engine and remove the tap, `continuation.finish()`, `try await analyzer.finalizeAndFinishThroughEndOfInput()`, then `setActive(false, options: .notifyOthersOnDeactivation)`.
- iOS 27's `AnalyzerInputConverter` / `CaptureInputSequenceProvider` are not used, so one path covers 26 and 27.

**iOS 17 to 25: `SFSpeechRecognizer`**
- `SFSpeechRecognizer(locale: Locale.current)`; it must be `isAvailable` and `supportsOnDeviceRecognition` (D1).
- `SFSpeechAudioBufferRecognitionRequest`: `shouldReportPartialResults = true`, `requiresOnDeviceRecognition = true`, `addsPunctuation = true`, `taskHint = .dictation`.
- `result.bestTranscription.formattedString` is the whole utterance so far. It is the volatile part until `result.isFinal`, then it is committed.

**Permissions (both paths).** `AVAudioApplication.requestRecordPermission()` and `SFSpeechRecognizer.requestAuthorization`. The SDK does not say whether SpeechAnalyzer needs the second, so both are asked for and both keys go in Info.plist:
- `NSMicrophoneUsageDescription`: "Page Relay uses the microphone only while you dictate a message. What you say is turned into text on this iPhone, or by Apple's speech service when the iPhone can't. It isn't recorded or kept."
- `NSSpeechRecognitionUsageDescription`: "Page Relay turns what you say into text, so you can dictate messages to your sessions. Nothing is sent until you tap Send."

**Interruptions.** `AVAudioSession.interruptionNotification` and route loss stop listening and keep the words, with the Interrupted line.

**Level.** RMS of each tap buffer, mapped to 0…1 and published at about 15 Hz.

### Android: one controller, chosen at run time (minSdk 26, targetSdk 35)

API levels are pinned from `platforms/android-35/data/api-versions.xml`: `createOnDeviceSpeechRecognizer` and `isOnDeviceRecognitionAvailable` 31, `checkRecognitionSupport` and `triggerModelDownload(Intent)` 33, `triggerModelDownload(…, ModelDownloadListener)` 34.

- **API 31+ with `SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)`:** `SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)`.
- **API 33+ first:** `checkRecognitionSupport(intent, mainExecutor, cb)`.
  - The locale is in `installedOnDeviceLanguages`: go.
  - It is in `supportedOnDeviceLanguages` or `pendingOnDeviceLanguages`: on 34+, `triggerModelDownload(intent, mainExecutor, listener)` (progress shows on the line); on 33, `triggerModelDownload(intent)` (the line says "Getting … speech" with no percent, and the person taps again).
  - Neither: unavailable.
- **API 26–30, or no on-device recognizer:** D1 decides. Either unavailable, or `createSpeechRecognizer(ctx)` with `EXTRA_PREFER_OFFLINE`, and then the line says the phone's speech service may use the network.
- **Intent.** `ACTION_RECOGNIZE_SPEECH`, `EXTRA_LANGUAGE_MODEL = LANGUAGE_MODEL_FREE_FORM`, `EXTRA_LANGUAGE = locale.toLanguageTag()`, `EXTRA_PARTIAL_RESULTS = true`, `EXTRA_PREFER_OFFLINE = true`.
- **Results.** `onPartialResults` gives the volatile part (`RESULTS_RECOGNITION[0]`). `onResults` commits it. The recognizer ends at a pause, so the controller starts it again until the person stops, the 20 s of silence has passed, or the 10 min cap is reached.
- **Errors.**
  - `ERROR_NO_MATCH`, `ERROR_SPEECH_TIMEOUT`: restart, and count toward the silence.
  - `ERROR_INSUFFICIENT_PERMISSIONS`: the Microphone off line.
  - `ERROR_LANGUAGE_NOT_SUPPORTED`, `ERROR_LANGUAGE_UNAVAILABLE`: the language line.
  - `ERROR_RECOGNIZER_BUSY`: retry once.
  - `ERROR_CLIENT` after a stop: ignored.
- **Level.** `onRmsChanged(rmsdB)`, mapped from −2…10 dB to 0…1.
- **Threading.** Create, use and `destroy()` the recognizer on the main thread, with `DisposableEffect` on leaving the box.
- **Manifest.** `<uses-permission android:name="android.permission.RECORD_AUDIO" />`, and `<queries><intent><action android:name="android.speech.RecognitionService" /></intent></queries>` (without it `isRecognitionAvailable` is false on API 30+).
- **Runtime permission.** `RequestPermission`. If it is refused for good, the Microphone off line opens `ACTION_APPLICATION_DETAILS_SETTINGS`.

## Pure logic (both platforms, same names, unit-tested)

- **`DictationDraft`**
  - `init(base:)`, `setVolatile(_:)`, `commit(_:)`, `text`, `finish() -> String`.
  - Holds the base draft, the committed words and the volatile words.
  - `text` = base + joiner + committed + volatile.
  - No newline ever. The joiner rules are as above.
- **`DictationGuard.userEdited(current:lastWritten:)`**: the field no longer holds what dictation last wrote, so stop and drop late results.
- **`DictationEngineChoice.pick(…)`**: from the OS version or API level, on-device availability, locale support and the D1 policy, chooses `analyzer`, `transcriberFallback`, `recognizerOnDevice`, `recognizerServer` or `unavailable(reason)`.
- **`DictationPhase`**: `idle`, `preparing`, `downloading(fraction?)`, `listening(level)`, `denied(.microphone | .speech)`, `unavailable(reason)`, `interrupted`.
- **`DictationCopy`**: every line and label above, with the language display name and the device word passed in.
- **`DictationClock`**: the 20 s silence limit (reset by any new words) and the 10 min cap.

## Privacy and security (SECURITY.md)

A new section, "Voice input":
- Audio is turned into text on the phone, by Apple's or Google's on-device recognizer.
- Page never writes audio to disk, never sends it over the relay and never logs transcripts.
- The text goes into the draft and goes nowhere until Send, by the same route and rules as typed text.
- The microphone is open only while the stop button shows.

## Decisions (the user, 2026-11-13)

- **Design: approved** as rendered (the board of seven iPhone screens).
- **D1: on-device first, then the phone's own speech service.** Use on-device recognition whenever the device has it. Otherwise fall back to the platform service, which may send audio to Apple or Google.
  - **Line while listening on a server.** iPhone: "Listening with Apple's speech service · nothing is sent until you tap Send". Android: "Listening with this phone's speech service · nothing is sent until you tap Send". The on-device line stays "Listening on this iPhone · …".
  - **Copy.** `DictationCopy.listening(device:send:onDevice:)`. On a server, `DictationPhase.listening` carries `onDevice: false`.
  - **iOS chain.** `SpeechTranscriber` (iOS 26+, on-device), then `DictationTranscriber` (iOS 26+, on-device), then `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` when `supportsOnDeviceRecognition`, then `SFSpeechRecognizer` on Apple's server (`requiresOnDeviceRecognition = false`). The server path ends each request near 1 minute, so the engine starts a new request at 55 s and carries the committed words over.
  - **Android chain.** `createOnDeviceSpeechRecognizer` (API 31+, with `isOnDeviceRecognitionAvailable`, a supported or installed language, or a download), then `createSpeechRecognizer` when `SpeechRecognizer.isRecognitionAvailable(ctx)`, with `EXTRA_PREFER_OFFLINE = true`. If neither exists: `unavailable(.noRecognizer)`, "This phone has no speech recognizer, so the mic is off."
  - **A language missing on-device** falls back to the server path too, before the language line is ever shown. That line is only for a language that no path supports.
- **D2: the Mac too.** Page Studio's two Steer boxes in the menu-bar panel get the same mic (see "Mac" below).

## Mac (Page Studio)

- **Boxes.** `NWComposer` ("Tell it instead…", NowPopoverView.swift) and `NWFlightComposer` ("Steer Claude…", NowInFlightView.swift). Both write `store.composerText`.
- **The mic.** A 24 pt glyph button inside the field, before the ↵ keycap or Send: `mic` in textTertiary, with the help text "Dictate · nothing is sent until you press Return". While listening it shows the teal stop square on a 16 % teal disc, with the level ring.
- **The line.** It sits above the field, in the panel's style (monoMicro or 11 pt): "Listening on this Mac · nothing is sent until you press Return", with level bars. The problem lines are the phones' lines, with "Mac", and "Open Settings" opens System Settings ▸ Privacy & Security ▸ Microphone or Speech Recognition (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` / `?Privacy_SpeechRecognition`).
- **Keys.**
  - ⌘D (or a click) starts and stops while a Steer box is open. (Not ⌥⌘D: macOS takes that for "Turn Dock hiding on/off" before any app sees it.)
  - Esc stops listening first and closes the box on the second press.
  - Return sends what shows and stops, the same as Send.
  - Typing stops listening.
- **Engines.** macOS 26+: `SpeechAnalyzer` + `SpeechTranscriber` / `DictationTranscriber` (the same calls as iOS; macOS has no `AVAudioSession`, so `AVAudioEngine` is used directly). Earlier: `SFSpeechRecognizer`, on-device when supported, else Apple's server (D1). The package's deployment target is macOS 12, so it is all behind `#available`.
- **Permissions.**
  - `AVCaptureDevice.requestAccess(for: .audio)` and `SFSpeechRecognizer.requestAuthorization`.
  - build.sh writes `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` into Info.plist.
  - Resources/Page.entitlements gains `com.apple.security.device.audio-input`; the app is signed with the hardened runtime, and without that entitlement the microphone is silently denied.
- **Pure logic.** The same `Dictation.swift` types in Sources/PageCore (Foundation only: PageCore also builds for Linux).
- **Renders.** `RenderHarness` screens `popover-voice-listening` and `popover-voice-denied`.

## Build plan

The renders come first, for approval: iOS fixtures `room-voice`, `room-voice-listening`, `room-voice-download`, `room-voice-denied`, `room-voice-off`, `decision-review-voice` and `dispatch-voice`. These views are already in place (Design/NightWatch/NWDictation.swift, Models/Dictation.swift, and the room, reply-sheet and New task boxes). The agents wire them up. Then:
1. **Sonnet: iOS.** The engines, `DictationController`, the wiring into the four boxes, Info.plist, and render fixtures for every state.
2. **Sonnet: Android.** The same, matching the iOS renders. Also the manifest and the demo screens `room-voice-*`.
3. **Haiku: tests.** `DictationDraft` (joining, volatile replace, no newline, the Return-key trap), `DictationGuard`, `DictationEngineChoice` (every OS and policy combination), `DictationCopy` and `DictationClock`, on iOS (`Tests/run-logic-tests.sh`) and Android (JUnit).
4. **Opus: verification.** Builds, renders on both platforms, the test suites, and a simulator run that speaks into the Mac's microphone with `say`. Then the docs: the README, SECURITY.md, the iOS and Android READMEs, the website, the brochure and the images.

A real-device check is still owed: the iPhone needs Xcode signed in, and no Android phone is set up.
