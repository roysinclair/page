# Marketing images

Sources for the images in `docs/images/` (README, GitHub) and `website/public/img/showcase/` (website).
Each image is an HTML composition shot by headless Chromium. Nothing opens a window.

| File | Output |
|---|---|
| `hero.html` | `hero.png` 2400×1200 (README), `hero.webp` 2880×1440 (website) |
| `og.html` | `og.png` / `og.webp` 1200×630 (social card, GitHub social preview) |
| `og-studio.html` | `website/public/img/og/studio.webp` 1200×630 (the website home page's social card) |
| `feature-*.html` | 1600×1000 each: budgets, budget-stop, panel, panel-close, voice, voice-mac, battery, lock-screen, sessions, terminals, android, widgets, relay, aura |
| `family.html` | `family.png` / `family.webp` 2400×1500 (brochure cover, website overview) |
| `screen-lock.html` | `out/screen-lock.png` 782×1690, the lock-screen board with the Page Relay name, for `website/scripts/product-shots.py` (`power/lock`) |

`base.css` holds the Night Watch tokens, the drawn device frames (generic, with no vendor marks) and the lock-screen
overlay. `sky.js` draws the seeded star field and aurora. The fonts are Inter and JetBrains Mono (OFL, in `fonts/`).

## Regenerate

```sh
cd docs/images/src
npm install                                   # playwright (uses its own headless Chromium)
python3 -m venv .venv && .venv/bin/pip install pillow imagequant
node shoot.mjs                                # or: node shoot.mjs feature-relay hero
.venv/bin/python compress.py                  # writes ../*.png and website/public/img/showcase/*.webp
```

The PNGs must stay under 1.5 MB each (12 MB in total). `compress.py` palette-quantises one only if it goes over.

## Refresh the app renders (`assets/`)

`assets/*.webp` are crops of real renders with fixture (demo) data. To refresh them, render all three apps
headlessly, then crop:

```sh
swift build && .build/debug/ClaudePowerMode --render-ui /tmp/r/mac --card-glow full   # offscreen; never use --live-check
iOS/Tools/render-screens.sh /tmp/r/ios full        # simctl only, so Simulator.app stays closed. Re-run any blank screen.
android/tools/screens.sh /tmp/r/android --glow full # boots the PageParity AVD with -no-window
.venv/bin/python assets.py --mac /tmp/r/mac --ios /tmp/r/ios --android /tmp/r/android
```

`xcrun simctl shutdown "Page Render"` afterwards.

Only the budget images (`feature-budgets`, `feature-budget-stop`) need just these renders, and `--only budget`
writes just their crops:

```sh
.build/debug/ClaudePowerMode --render-ui /tmp/r/mac --card-glow full
iOS/Tools/render-screens.sh /tmp/r/ios full -- decision-budget now-budget
android/tools/screens.sh /tmp/r/android --glow full -- decision-budget now-budget
.venv/bin/python assets.py --mac /tmp/r/mac --ios /tmp/r/ios --android /tmp/r/android --only budget
node shoot.mjs feature-budget && .venv/bin/python compress.py
(cd ../../../website && npm run crops -- budget)    # the website's -visual crops
```

The Mac's budget fixtures live in `Sources/ClaudePowerMode/UI/RenderBudget.swift` (popover) and
`TowerFixtures.budgetBoard()` (Tower ▸ Budget), with demo names only.

The menu-bar panel images (`feature-panel`, `feature-panel-close`) need only the Mac renders:

```sh
.build/debug/ClaudePowerMode --render-ui /tmp/r/mac --card-glow full    # from the repo root
.venv/bin/python assets.py --mac /tmp/r/mac --only panel
node shoot.mjs feature-panel && .venv/bin/python compress.py
(cd ../../../website && npm run crops -- panel)     # the website's -visual crops
```

Their fixtures live in `Sources/ClaudePowerMode/UI/RenderSessions.swift`, with demo names only.

The voice-input images (`feature-voice`, `feature-voice-mac`) need one screen from each app:

```sh
.build/debug/ClaudePowerMode --render-ui /tmp/r/mac --card-glow full --only popover-voice
iOS/Tools/render-screens.sh /tmp/r/ios full -- now now-quiet lanes room-voice-listening   # the first captures warm up
android/tools/screens.sh /tmp/r/android --glow full -- room-voice-listening
.venv/bin/python assets.py --mac /tmp/r/mac --ios /tmp/r/ios --android /tmp/r/android --only voice
node shoot.mjs feature-voice && .venv/bin/python compress.py
(cd ../../../website && npm run crops -- voice)     # the website's -visual crops
```

Their fixtures are the `room-voice-*` screens (iOS `Services/RenderHarness.swift`, Android `demo/DemoRooms.kt`) and
`popover-voice-*` (`Sources/ClaudePowerMode/UI/RenderInFlight.swift`).

## Rules for what goes in

- **Real UI only.** Real renders come from the Mac, iOS and Android render harnesses, and Page Aura's own docs.
  Two v4 design boards are used where no render exists: the iPhone lock screen's wallpaper, clock and widgets.
  The board's Live Activity and island count are concepts, because nothing uses ActivityKit yet. `base.css`
  paints them over with a plain island and real-format notifications ("<project> paged you" /
  "Approval needed: [Bash] …", from `Cloudflare/src/logic.ts`). The board's widget and notification still say
  "PAGE"; `base.css` (`.wpatch` / `.wlabel`) and `screen-lock.html` set the iPhone app's name, Page Relay, there.
- **Real renders keep their own words.** Old names baked into a render (for example the Mac widget's "Page" label)
  change only when the app is re-rendered, never by painting over the render.
- **Demo data only.** Use the fixture names: page (but not next to the brand: prefer payments-api), bottle-flip, payments-api, sensor-hub, llm-play,
  tokenizer-lab, acme-*, Studio MBP. Leave out any screen that shows this repo's own folder name, a real path
  or a QR code.
- **Copy must match the docs.** For example, live-session content is end-to-end encrypted but pages are not.
  One-tap Approve from a notification works only for Undoable commands (`NotificationService.swift`). Terminal
  capabilities come from `TerminalCatalog`.
