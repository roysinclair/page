# Performance: heat, lag and 60 Hz scrolling (2026-11-19)

## What the user reported

> "There seems to be quite a bit of lag, and when I'm running it on my phone, I'm feeling quite a bit of heat
> as well, and I'm definitely seeing when I'm scrolling … a 60 hertz refresh rate instead of the 120."

This applies to all the apps: iPhone, Android, Mac and Linux. Power saving was off on the phone. The Android
app hasn't been tried on a real phone.

## What was measured and found

### Mac (measured on the user's Mac)
- **Idle CPU:** Page Studio uses 6–15% of one core while just sitting in the menu bar. Over its whole run,
  about 72% of its CPU time was on the main thread.
- **The menu bar glyph is most of that.** In an 8 s sample, almost all the main-thread work was the
  menu-bar glyph:
  - `GlyphAnimator` runs at 8 fps whenever any agent is working: 24 phase steps over a 3–4 s breath.
  - Every frame sets `statusItem.button.image`.
  - That image is an `NSCustomImageRep`, so AppKit draws the glyph again for the button and for every
    menu-bar replicant (`_updateReplicants`).
- **`ps`:** spawned about 8 times a minute (Claude and Codex scans every 15 s). That's cheap.
- **Linux:** the daemon has no UI and reads `/proc`. Nothing to fix.
- **Mac → phone:** while agents work, the session list goes to the phone up to once a second
  (`SessionsSchedule.listThrottle`), because `lastActivityAt` changes with every transcript write.

### iPhone (from the code; the simulator was measured with `-NWLive`)

Simulator CPU before the change (Debug build, every motion live):

| Screen | CPU |
|---|---|
| now-still | 6.1% |
| now-working | 14.3% |
| now-inflight-long | 15.3% |
| lanes | 12.5% |
| room-story | 13.3% |

- **No 120 Hz key.** `CADisableMinimumFrameDurationOnPhone` is missing from Info.plist.
- **The Horizon sky never stops.** It runs as a Metal aurora at 30 fps whenever Now is up, and
  doesn't pause when it is scrolled off-screen. `NWNightScene` (the still mountains) is drawn again inside
  the same clock.
- **Too many clocks.** While agents work, Now has 6–9 unsynchronised `TimelineView(.animation)` clocks:
  the orb, the capsule, the Runway, the In flight strip and each card.
- **Every update rebuilds Now.** Every list frame republishes `SessionStore`:
  - `sessions` and `lastListAt = Date()` are assigned every time, and transcript and screen frames
    publish too.
  - `NowContainer` and `LanesContainer` observe the whole store, so all of Now is rebuilt each time,
    even under a room sheet.
  - Decryption and JSON decoding run on the main actor.
- **Every scroll starts and ends with a rebuild.** `DragGesture(minimumDistance: 0)` on the Now
  ScrollView rebuilds the container both times.
- **The room aurora is expensive.** `NWAuroraCanvas` is drawn on the CPU with blurs at 30 fps the
  whole time a room is open.
- **Smaller costs:**
  - `NWNowScreen.stream` works out order, sections and arrivals once per row, which grows with
    the square of the row count.
  - `NWPhotos` decodes thumbnails inside `body`.
  - `DiffView` rebuilds every 1 s, and the room container every 2 s, with the whole screen inside each
    `TimelineView(.periodic)`.

### Android (from the code)
- **Stacked glows.** `drawSoftGlow` draws 8–28 translucent rounded rects per glow. Cards (often two
  glows each), the desk behind the list and the chrome all use it, so the GPU fills each area dozens of
  times on every frame.
- **The Horizon AGSL aurora** runs at 30 fps.
- **`NWAnimated` recomposes instead of redrawing.** It reads the clock in composition, so every tick
  recomposes the whole Horizon.
- **The Lanes aurora (15 fps) and the Room aurora (30 fps, CPU path with blurs)** have no
  `active` gate.
- **`NowScreen.kt:459`** reads `firstVisibleItemIndex` in composition, so the whole screen recomposes
  while you scroll.
- **`RelayClient`** parses and decrypts on `Dispatchers.Main.immediate`. The HKDF subkey isn't cached.
- **NowScreen collects all of `SessionStore.state`,** including screens and transcripts.

## Phase 1: fixes that don't change the look (approved 2026-11-19)

The rule: a screenshot of any screen at any moment must look the same as before. Nothing animates
differently while it's on screen. Work that nobody can see is skipped or moved off the main thread.

**Mac**
1. Render the glyph once per frame into a bitmap image, at 1× and 2×, instead of a drawing handler.
   The status item and its replicants then blit pixels instead of redrawing vectors.
2. Stop the glyph's timer while the displays are asleep or the session is locked. Restart it on wake
   or unlock.

**iPhone**
1. Add `CADisableMinimumFrameDurationOnPhone = true`.
2. Pause the Horizon's clocks (sky and orb) while the Horizon is scrolled off-screen, the way In flight
   already pauses. If `NWNightScene` doesn't depend on time, draw it outside the clock.
3. Decrypt and decode relay frames off the main actor, and publish only real changes:
   - Don't reassign `sessions` when they are equal.
   - Stop `lastListAt` from republishing the whole store.
   - Keep transcript and screen frames from rebuilding Now and Lanes.
4. Don't rebuild Now when a scroll starts or ends, unless data arrived during the touch.
5. Work out the per-row values in `NWNowScreen.stream` once per body. Cache decoded photo thumbnails.
6. Narrow the `TimelineView(.periodic)` wrappers in DiffView and the session room to the views that
   show time.
7. The room aurora: allowed only if a screenshot comparison shows no difference (for example,
   `.drawingGroup()`). Otherwise leave it for Phase 2.

**Android**
1. Render each soft glow once into a cached bitmap (keyed by size, colour, blur and corner) and draw
   the bitmap. Do the same for the desk.
2. Read animation clocks in draw lambdas, not composition: the Horizon sky and the Lanes and Room
   auroras. Put each shader or canvas in its own `graphicsLayer`.
3. Pause the Lanes and Room auroras while covered (`LocalAnimationsPaused`), like the other clocks.
4. Wrap `firstVisibleItemIndex > 0` in `derivedStateOf`.
5. Parse and decrypt relay frames on `Dispatchers.Default`, and cache the HKDF subkey.
6. NowScreen collects only what it shows, so screen and transcript frames don't recompose Now.

## Phase 2: changes that alter the look (for the user to decide later)
- Mac glyph: animate only for "needs you", or a slower breath.
- Phone skies: lower frame rate or resolution, or stay still while things are quiet.
- One shared clock per screen.
- A cheaper room aurora.

## Checks
- **Mac:** CPU before and after on the same busy state, and a glyph bitmap pixel-compared with the old
  drawing.
- **iPhone:** the simulator CPU table above after the change, and screenshots of every harness screen
  compared pixel for pixel. On the device: Instruments Animation Hitches and Time Profiler, with the
  phone connected.
- **Android:** unit tests, a screenshot comparison, and `dumpsys gfxinfo` on an emulator. A real phone
  when the user has one connected.
