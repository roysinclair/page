# Night Watch v5: depth, lift and life

v5 keeps v4's Night Watch world and the trust model. What changes is how the
phone apps feel: everything used to sit flat at the same weight. Now the page
has depth, and the eye goes where attention is needed.

**Reference:** the iOS app is the reference implementation (`iOS/Page/Design/NightWatch`,
`iOS/Page/Models/NightWatchDepth.swift`). The rendered reference set is the harness
screens of the same names. Android ports it; it does not redesign it.

## 1. The order of attention

| Tier | What | Surface |
|---|---|---|
| Information | The Horizon (the aurora, the pulse, the words), the Runway, Settled | Sky, smoked glass, quiet lists. No light of its own. |
| In progress | In flight sessions, finished turns (Review) | Raised navy cards with the project's colour on a band and a door; quiet buttons |
| Needs you | Decide (approve, question), Look (stuck, rate limit, forecast) | Jewels (saturated, lit, glowing) for Decide; raised card lit in amber for Look |

- **Separator:** the desk, a raised surface rising behind the Runway, is where information ends and work begins.
- **Order:** Decide jewels are always the brightest and most colourful mass on the screen. Session doors and bands come second. Settled is the quietest.

## 2. Tokens

### Surfaces

| Token | Value | Use |
|---|---|---|
| `surface` | `#131722` | Card fill (was `#14161C`) |
| `surfaceRaised` | `#1A1F2C` | Raised cards: Look, Review, In flight body, Lanes body, tiles (was `#1B1E25`) |
| Desk | `#0E1322` → `#0A0E1A` at 10% → `#070A13` | The surface the stream sits on |
| Instrument glass | `#182035` at 94% → `#0B1020` at 96% | The Runway |
| Chrome glass tint | `#04060A` at **34%** | Nav capsule, Mac chip, close buttons, room tabs (was 60%) |

### Jewels

The single table is `JewelTone` in `NightWatchDepth.swift`; Android must use the same bytes. Each jewel is opaque, built from `top`, `bottom`, `light` and `lightStrength`.

| Tone | top | bottom | light | strength | Used for |
|---|---|---|---|---|---|
| red | A3243A | 4A0E1C | FF7A8A | 0.32 | Irreversible |
| sky | 1D62AE | 0B2A55 | 7CC8FF | 0.15 | Considered; project sky |
| green | 0B6E51 | 05352A | 5EEAB0 | 0.12 | Undoable |
| amber | 9A4A08 | 451A05 | FFB347 | 0.20 | Question, Look, stuck |
| teal | 0D7A72 | 063A40 | 5EEAD4 | 0.08 | Finished; working; project teal |
| lime | 3A7A12 | 17340A | BEF264 | 0.06 | Project lime |
| violet | 5B3FC4 | 261860 | C4B5FD | 0.20 | Project violet |
| plum | 8E2A84 | 3D1040 | F5A8E8 | 0.12 | Project rose (never reads as Irreversible) |
| indigo | 3557A8 | 16244D | A5B8F0 | 0.15 | Project white (never grey) |

- **Mappings:** chip to tone and `ProjectHue` to tone, as in `JewelTone.init(chip:)` and `init(hue:)`.
- **Contrast:** white text holds 4.5:1 or better on `top`, on `bottom` and on the lit corner (`top` mixed toward `light` by `strength`).
- **Never mix a hue into the grey surface with alpha.** That is what turned red maroon and amber brown in v4.

### Type

SF on iOS. On Android: the default family; Rounded becomes Bold default; mono stays `FontFamily.Monospace`.

| Role | iOS | Android |
|---|---|---|
| Horizon headline (`hero`) | largeTitle, rounded, bold | 34 sp bold |
| Decision sheet ask (`sheetTitle`) | title, rounded, bold | 28 sp bold |
| Section (`section`) | title3 bold | 20 sp bold |
| Names (`name` / `nameLarge`) | subheadline / headline semibold | 15 / 17 sp semibold |
| Activity (`activity`) | subheadline semibold | 15 sp semibold |
| Meta (`meta` / `metaSmall`) | footnote / caption | 13 / 12 sp |
| Button (`button`) | callout semibold | 16 sp semibold |

**Monospace only for literal commands, paths, the delivery preview and diff stats.** Names, activity, Settled lines and labels are words.

### Shape and size

| Thing | Size |
|---|---|
| Buttons | 44 high, corner 13 |
| Nav capsule | 60 high; pulse 50; selected side in a glass bubble |
| Card | corner 22 |
| Row | corner 18 |
| Desk | top corners 32 |
| Icon tile | corner 0.3 × size |

## 3. Components (iOS name → Android)

| iOS | Recipe |
|---|---|
| `NWGlassBackground` (raised) | See below. |
| `NWJewelSurface(jewel, lift)` | See below. |
| `NWIconTile(symbol, jewel, size, glass)` | Squircle. See below. |
| `NWSoftTile(symbol, tint, size)` | tint 20% to 8% fill, tint 40% to 10% rim, glyph in tint. Quiet rows: session facts, Settled, steps. |
| `NWHueBand(jewel)` | Top-rounded band, `top` to `bottom` diagonal, radial light, gloss 7% to 0 over half, white 40% lip, `light` 35% hairline at the bottom. |
| `NWDesk(light)` | Desk ramp, top corners 32, mood-light radial (12%, radius 280) from the top centre, white 13% lip fading over 70, a horizon line. Black 70% shadow, radius 26, up 6. |
| `NWInstrumentGlass(light)` | See below. |
| `NWGlassBubble` | Selected tab: white 20% to 8% fill, white 42% to 6% stroke, black 25% shadow radius 6. |
| `NWCountBadge(count, colour)` | Capsule, colour+30% white to colour, dark ink text, white 45% top stroke, colour 55% glow radius 6. |
| `NWSectionHeader` | See below. |
| `NWButtonStyle` kinds | See below. |
| `NWHoldButton` | Red fill, a red sweep as it is held, gloss, red 50% glow (radius 12, y 6), white rim on a jewel. At the largest text sizes the glyph steps aside and the words take up to two lines. |
| `NWRecede` | Cards leaving the top of the stream scale to 0.94 (anchor bottom) and fade to 0.55. Top edge only; none with Reduce Motion. |

**`NWGlassBackground` (raised):**
- fill 4.5% lighter at the top;
- a 5% white sheen over the top 40%;
- rim white 22% → 6% at 35% → 4%;
- shadow black 60% (radius 20, y 14);
- a tint, when there is one, goes only into a top radial (13% × alpha), the rim (62% → 22% × alpha) and a 16% glow. **Never into the fill.**

**`NWJewelSurface(jewel, lift)`:**
- `top` → `bottom` diagonal;
- a `light` radial at `strength` from the top leading corner (radius 300);
- a 6% gloss over the top 35%;
- a `light` rim, 85% → 22%;
- a white 42% lip over the top 30%;
- a glow of `light` at 36% (radius 24 × lift, y 14 × lift);
- a black 55% contact shadow (radius 4, y 3).

**`NWIconTile(symbol, jewel, size, glass)`:**
- fill: `light` mixed 45% toward `top`, then `top`, then `bottom`;
- a 30% gloss over the top half;
- a white 50% → 6% rim;
- glow: `light` 45%, radius 0.25 × size.
- The glass variant (on a jewel) is white 20% → 7% with a glyph glowing in `light`.

**`NWInstrumentGlass(light)`:**
- the smoke ramp from the Surfaces table;
- a 7% sheen;
- a mood-light radial from the bottom;
- rim white 26% → 7% → light 35%;
- shadows: light 22% (radius 26, y 16) and black 65% (radius 14, y 10).

**`NWSectionHeader`:**
- a 30 icon tile, the title in words (`SectionTitle.words`) and a count badge;
- 20 above it;
- glyphs: Decide `hand.raised.fill` (amber), Look `eye.fill`, Review `checkmark.seal.fill` (teal), In flight `airplane` (teal), with "Lanes ›" on the right.

**`NWButtonStyle` kinds:**

| Kind | Body | Use |
|---|---|---|
| quiet | white 12% → 6% | Secondary |
| bright | teal → sky | Primary on a dark card |
| amber | yellow → amber | Steer on a stuck agent |
| danger | as before | |
| white | white → `#E8EDF5`, dark ink | Primary on a jewel |
| glass | black 14% → 30% | Secondary on a jewel |
| soft | teal 16% → 7%, teal text | Steer on an In flight card |

Every kind also has:
- a sheen over the top 55% (bright and amber 30%; quiet, glass and soft 10%);
- a top rim;
- a glow of its own colour (bright and amber 45%, white 22%, soft 16%, quiet and glass black 35%);
- on press: scale 0.97, brightness −4%, 120 ms.

## 4. Screens

### Now

- **Layout, top to bottom:**
  1. **Horizon:** aurora, the night scene, the pulse, the headline and subline.
  2. **The sky:** the Runway in instrument glass, above the desk (z-order).
  3. **The desk:** its top rises 58 behind the Runway's lower half (the lift). The stream sits on it.
- **Night scene** (`NWNightScene`, drawn in the sky stack after the fade and before the pause band):
  - **Two ranges:**
    - Each range is a few Gaussian peaks plus fine grain, drawn as **one path per range**: down the left edge, along the crest, down the right edge.
    - The far range is filled with the land colour mixed 20% → 5% toward `c1`. Its crest is three strokes: 5 pt at 12%, 2.4 pt at 16% and 0.8 pt at 26% of `c1`. No blur.
    - The near range is the land colour mixed 50% toward black.
    - The land colour is `skyTop` mixed 55% toward `backgroundDeep`.
  - **Lake:** `land + 12% c1` → `backgroundDeep`. The near range is mirrored in it, at 80% height, fading.
  - **Waterline:** a 1 pt thread of `c1` at 38%.
- **Runway instrument (Now only; widgets keep the plain line):**
  - **Track:** 8 high; teal → sky up to `clearFraction`, amber 55% → 18% after it; a glow and a top highlight.
  - **Markers:** a 12 dot with a white centre, a pin up to a chip (tone 16% fill, tone 40% rim, caption2 semibold). Chips sit in lanes 22 high (scaled) and flip left past 0.66.
  - **Below the track:** hour ticks 1h–5h (5h is dropped when "on AC" shows) and "NOW".
- **Decide card:**
  - the jewel at lift 1.25;
  - top line: chip on the jewel (white on black 26%), project, and a clock chip (`WaitChip.text`);
  - a 44 glass emblem beside the ask;
  - the command in a dark well;
  - Deny is glass; Approve is white; Irreversible is the hold button.
- **Question card:** the amber jewel, the same top line and emblem, and a white "Answer" capsule.
- **Undoable row:** a slim green jewel row with a `terminal.fill` glass tile, reading "page · undoable » swipe to run".
- **Look card:** raised `surfaceRaised` with amber tint, a 48 amber icon tile, an amber Steer button 84 wide.
- **Review card:** raised with teal tint, a 36 teal tile, the project name in `nameLarge`.
- **In flight:**
  - **Doors:** 212 × 96, the project jewel at lift 0.7, crossing to amber as stuck. The emblem is the session star with a flare: two 84 × 1.6 rays and a radial glow. It sits bottom trailing, offset 30, clipped.
  - **Door text:** white; progress and health in black 28% pills.
  - **Strip:** must not clip the doors' glow.
  - **Session card:**
    - a `NWHueBand` header with the star in a glass tile, the name in white and a stuck pill;
    - the body is `surfaceRaised` mixed 30% toward the jewel's `bottom`;
    - facts are led by soft tiles, with no labels: NOW `waveform` teal, TIME `clock.fill` sky, WORKFLOWS `square.stack.3d.up.fill` violet, HEALTH `heart.fill` green, sky or amber;
    - Open is quiet, Steer is soft.
- **Settled:** a gradient rule above it, a quiet "Settled" header, soft tiles (approved `checkmark` green, sent `paperplane.fill` sky, neutral `circle.dotted` slate, days `calendar`).

### Decision sheet

- **Background:** the sheet is `surface`. Its class's jewel fills the top 330, `top` → `bottom` at 55% → transparent, with a radial light and a white lip.
- **Header:** a 36 glass emblem, the chip on the jewel, and the meta line in white 88%. The ask is `sheetTitle`.
- **Labels:** "Why" and "The prompt offers" are words. Tags are capsules.

### Lanes

- **Project band:** each project is a card with a `NWHueBand` header: its jewel, or amber when one of its sessions needs you or is stuck. The header holds the star in a glass tile, the name, an urgent pill and a count.
- **Card body:** `surfaceRaised` mixed 30% toward the jewel's `bottom`.
- **Rows:** names in `name`, state in words (`SectionTitle.words`).

### Tower, Dispatch, Room

- **Tower:** sections get 28 icon tiles (power `bolt.fill` green, budget teal, Macs sky, attention amber, gestures and appearance violet, terminals and about indigo, widgets plum, pairing teal). The "The Tower" kicker is in words.
- **Dispatch:** Where, Who, What and When are 24 tiles with the word. The chosen folder is a capsule of its project jewel; the others are lit glass.
- **Room:** the title is title3, rounded, bold. Steps read "5 steps" with a soft tile. Story dividers are in words. The tabs are chrome glass with the selected one in a bubble.
- **Workflows lens and composer label (both platforms):** in words. Running / Done / Failed / Stopped, "Task from the workflow", group and status labels, run names, and the Decision composer's label. Monospace stays for counts, paths and the terminal.

## 5. Android

These are decisions, not options.

- **Lift is drawn, not elevated.**
  - minSdk is 26.
  - `Modifier.shadow` with coloured `ambientColor`/`spotColor` only works from API 28.
  - `Modifier.blur` and `RenderEffect` only work from API 31.
  - So draw each jewel, door and button glow in `drawBehind` as a radial or softened shape in the glow colour, offset down. Do not use elevation for lift.
- **No Liquid Glass.**
  - Chrome is smoke with a lit rim (white 30% → 6%) and the glass bubble.
  - Smoke without a blur lets rows show through, so the nav capsule is `#04060A` at **80%**, with a fade scrim behind it: the page colour, from clear 22 dp above the capsule to 85% at the screen edge.
  - Other chrome keeps 34%.
  - The selected-side bubble fades in rather than sliding.
- **Shapes:**
  - Continuous corners are circular arcs.
  - The Decision sheet's top corner is the sheet host's 28 (iOS 34).
  - The chosen Dispatch folder is 48 high (radius 24) to keep its touch target.
- **The night scene** is a `Canvas` with one `Path` per range and no per-frame blur.
- **Haptics and motion** stay as they are.

## 6. Invariants

- Red is only for Irreversible.
- Card glow is off by default.
- Glass is only on chrome.
- Text contrast is at least 4.5:1.
- The first Decide card is fully in view when something needs you.
- Buttons are 44 high.
- Mono is only for code.
- Reduce Motion stills `NWRecede` and the scene.

## 7. Measured

- **iOS:** every glass label measured is 5.8:1 or better at night and in the afternoon sky (the Mac chip, the nav capsule's labels, the room's tabs).
- **Android:** white text on the doors, bands and jewels samples at 6.2 to 12.2:1.

## 8. Not in v5

- The Mac app (`Sources/ClaudePowerMode`) and the widgets keep v4 tokens for now.
- Real-device checks of scroll smoothness and battery are still to be done.
