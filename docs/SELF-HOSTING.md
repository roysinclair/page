# Run your own Page

This is the one guide from zero to "my phone gets pages from my Mac". Follow
it top to bottom. Plan on 30 to 60 minutes the first time.

Everything here runs on accounts you own. Nothing is shared with the author
of Page, and none of the author's keys, ids or URLs are needed.

## Contents

- [What you'll end up with](#what-youll-end-up-with)
- [What you need](#what-you-need)
- [Step 1: Your relay (Cloudflare)](#step-1-your-relay-cloudflare)
- [Step 2: The Mac app](#step-2-the-mac-app)
- [Step 3: The iPhone app](#step-3-the-iphone-app)
- [Step 4: Android (optional)](#step-4-android-optional)
- [Optional: Page Aura link](#optional-page-aura-link)
- [Checklist: every value that is yours](#checklist-every-value-that-is-yours)
- [Troubleshooting](#troubleshooting)
- [Set it up with an AI agent](#set-it-up-with-an-ai-agent)

## What you'll end up with

Three pieces, all yours. The **Mac app** (Page.app, in your menu bar) watches
your Claude Code and Codex sessions, keeps the Mac awake while they work, and
sends a "page" when one needs you. The **relay** is a small Cloudflare Worker
that you deploy to your own Cloudflare account. It holds the pages, queues
your replies while the Mac is offline, and asks Apple to push to your phone.
The **phone app** (iOS or Android) shows the pages and sends your answer back.
The Mac and the phone never talk to each other directly: the Mac connects out
to your relay, the phone connects out to your relay, and the two are matched
by a secret token that the Mac puts in a QR code. You scan the QR once to
pair.

## What you need

Required:

- A Mac running macOS 12 or later.
- Xcode Command Line Tools: `xcode-select --install`.
- A free [Cloudflare account](https://dash.cloudflare.com/sign-up). The free
  plan is enough for one person.
- Node.js 22.18 or later (`node --version`). It runs Wrangler, Cloudflare's
  deploy tool.
- `jq` and `curl` for the agent hooks. Both ship with recent macOS.

What else you need depends on the phone and on how much you want:

| You want | You need | What you get |
|---|---|---|
| Mac app only, no phone | Nothing more | Keep-awake and the battery pause. No pages to a phone |
| iPhone, no cost | Full Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), a free Apple ID | Pages arrive **only while the Page app is open**. No push notifications. Free provisioning expires after 7 days, so you rebuild and reinstall weekly |
| iPhone with push | The above, plus a paid Apple Developer Program team | Lock-screen pages and actions. Needs the `.p8` push key and the push entitlements file. Builds last as long as your membership |
| Android | Android SDK platform 35 and build-tools 35.0.0 (Android Studio's SDK Manager installs them), JDK 17 or later (Android Studio's bundled one works), `adb` | Full app, no Google account, no Play services. **No push**: see below |
| Signed Mac app that keeps its permissions and widgets | An "Apple Development" certificate (free Apple ID, signed in to Xcode) or a "Developer ID Application" certificate (paid) | See [Step 2](#step-2-the-mac-app) |

Android has no push because the relay's push path is APNs only. Instead the
Android app does one of three things. While Page is open it holds a live
connection and notifies you the moment a page opens. If you turn on **Stay
connected** (Tower, then Attention; off by default) it keeps that connection
in the background and you get pages within seconds. Otherwise a 15-minute
background check posts any page you haven't been told about. See
[`android/README.md`](../android/README.md#how-notifications-work-without-push).

## Step 1: Your relay (Cloudflare)

1. Clone the repo and install the Worker's dependencies:

   ```sh
   git clone https://github.com/roysinclair/page.git
   cd page/Cloudflare
   npm ci
   ```

2. Log in to your Cloudflare account. This opens a browser:

   ```sh
   npx wrangler login
   ```

3. Choose your iOS bundle id. This is a reverse-domain name that must be
   unique to your Apple developer team, for example `com.yourname.page`.
   The default, `app.page.Page`, may already belong to another team, so
   pick your own. You will use the same value in
   [Step 3](#step-3-the-iphone-app). Skip this if you won't use an iPhone.

4. Open [`Cloudflare/wrangler.toml`](../Cloudflare/wrangler.toml) and edit
   the two values under `[vars]`:

   ```toml
   [vars]
   APNS_ENV = "development"
   APNS_BUNDLE_ID = "com.yourname.page"
   ```

   - `APNS_BUNDLE_ID` must equal the iPhone app's bundle id exactly. If it
     doesn't, Apple rejects pushes with `DeviceTokenNotForTopic`.
   - `APNS_ENV` is only the default for phones that don't say which Apple
     push server their token belongs to. Current phones report their own, and
     that wins. Use `"development"` for builds you run from Xcode and
     `"production"` for TestFlight, Ad Hoc and App Store builds.
   - Leave the rest of the file alone. The Durable Object migration block is
     append-only.

5. (Paid Apple team only) Create the push key and store it as Worker
   secrets. Skip this if you have no paid team: the relay still works, it just
   can't wake a backgrounded phone.

   - At [developer.apple.com](https://developer.apple.com/account), go to
     Keys, press `+`, tick **Apple Push Notifications service (APNs)**, and
     download the `.p8` file. Apple lets you download it once. Keep it
     **outside** the repo folder.
   - Note the 10-character **Key ID** shown next to the key, and your
     10-character **Team ID** (Membership).
   - Set the secrets. Pipe the key file: an interactive paste can keep only
     its first line.

   ```sh
   cat ~/path/to/AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8
   npx wrangler secret put APNS_KEY_ID      # 10-character Key ID
   npx wrangler secret put APNS_TEAM_ID     # 10-character Team ID
   ```

   If this is a brand-new Worker, Wrangler may ask to create it first. Say yes.

6. Deploy. This runs the type check and the tests, then `wrangler deploy`:

   ```sh
   npm run deploy
   ```

   The first deploy may ask you to choose a `workers.dev` subdomain for your
   account. Wrangler then prints your URL, which looks like
   `https://page-relay.<your-subdomain>.workers.dev`. Copy it. This is your
   **relay URL**.

   If the tests fail because your Node is older than 22.18, upgrade Node.

7. Check it:

   ```sh
   curl https://page-relay.<your-subdomain>.workers.dev/health
   ```

   You should see `{"ok":true,"service":"page-relay","time":"…","apnsConfigured":true}`.
   `apnsConfigured` is `false` if you skipped the secrets or one is missing.
   That is fine for an Android-only or open-app-only setup.

If you change `wrangler.toml` or a secret later, run the deploy again (for
secrets, `wrangler secret put` takes effect on its own).

**What the relay stores, and who can see it.** The relay is yours alone: it
runs in your Cloudflare account and the author has no access to it. It keeps
one Durable Object per pairing token. Each holds your pending pages, your last
300 closed pages (with their context and your reply text), queued replies, and
your phone's push token. Live-session content (the Sessions tab) is
end-to-end encrypted and is never stored. There are no accounts: the token in
the QR code is the credential. [`SECURITY.md`](../SECURITY.md) lists what is
stored and for how long, and
[`Cloudflare/README.md`](../Cloudflare/README.md) covers routes, costs and
push troubleshooting.

## Step 2: The Mac app

1. From the repo root, build and install:

   ```sh
   cd ..            # back to the repo root if you are still in Cloudflare/
   ./install.sh
   ```

   This runs [`build.sh`](../build.sh), copies `Page.app` to `/Applications`,
   and registers a LaunchAgent (`local.Page`) so Page starts at login. It
   never uses sudo. To build without installing, run `./build.sh` and then
   `open ./Page.app`.

2. **Signing.** `build.sh` signs with `CODESIGN_IDENTITY` if you set it.
   Otherwise it takes the first "Apple Development" certificate in your
   keychain, then the first "Developer ID Application" one, then falls back
   to ad-hoc. List what you have with
   `security find-identity -v -p codesigning`.

   | Identity | What it means |
   |---|---|
   | **Apple Development** (free with an Apple ID signed in to Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates) | The best choice for yourself. The signature stays stable across rebuilds, so macOS keeps the Automation and Accessibility permissions you granted. The Mac widgets are built, because the identity has a team id |
   | **Developer ID Application** (paid program) | Same as above, and also what you'd use to hand the app to other people. Notarising is outside this guide |
   | **Ad-hoc** (no certificate found) | Works, but macOS forgets the permissions after every rebuild and the Mac widgets are **not** built |

   To force one:

   ```sh
   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./install.sh
   ```

   Gatekeeper: you build the app on your own Mac, so it carries no download
   quarantine and opens normally. If you instead copy a built app to another
   Mac, macOS will block it unless it is signed with a Developer ID and
   notarised. Build on each Mac instead.

3. Put Page's menu-bar icon to work. The first time Page types into
   Terminal.app or iTerm2, macOS asks for **Automation** permission. Allow it.

4. **Point the Mac at your relay.** Menu-bar icon, **Preferences…**, then
   **Macs & phones**. Turn on **Send pages to my phone**, paste your relay URL
   into **Relay URL**, and click **Test**. A `wss://…/ws` URL is rewritten to
   the `https://` base. Plain `http://` is refused except for localhost.
   The saved setting is `relayEnabled` and `relayURL` in
   `~/Library/Application Support/ClaudePowerMode/config.json`.
   (If the menu says "Phone relay: not set up — fix in Preferences…", that
   item opens this page.)

5. **Optional power helpers.** Two features need a narrow sudo rule: waking
   the Mac before a rate-limit resume, and keeping it awake with the lid
   closed on battery. In the app, either turn on **Keep awake with the lid
   closed on battery** in the menu, or open Preferences ▸ **Power** and click
   **Install…** on the Power helper row. macOS asks for your password once.
   The command-line route is `./install.sh --enable-power-helpers`; undo it
   with `./install.sh --disable-power-helpers`. [`SECURITY.md`](../SECURITY.md)
   lists the exact commands the rule allows.

6. **Optional agent hooks.** To get phone approvals from any Claude Code or
   Codex surface (not only tmux and Terminal.app), use the menu:
   **Integrations ▸ Install agent hooks…**. It shows the exact diff and asks
   before writing.

## Step 3: The iPhone app

Needs full Xcode (not just the command line tools), an iPhone on iOS 17 or
later, and a cable the first time. The app compiles Metal shaders, so install
Xcode's Metal Toolchain once: `xcodebuild -downloadComponent MetalToolchain`.

1. In Xcode, open Settings ▸ Accounts and add your Apple ID. Your team id is
   shown there (or at developer.apple.com under Membership).

2. Create your local settings file. It is git-ignored, so it never gets
   committed:

   ```sh
   cd iOS
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

3. Edit `iOS/Config/Local.xcconfig` (see
   [`Local.xcconfig.example`](../iOS/Config/Local.xcconfig.example)):

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PAGE_BUNDLE_ID = com.yourname.page
   PAGE_ENTITLEMENTS = Page/Page-Push.entitlements
   ```

   - `DEVELOPMENT_TEAM`: your 10-character team id.
   - `PAGE_BUNDLE_ID`: the same value you put in `APNS_BUNDLE_ID` in
     Step 1. The widget gets `<your id>.widget` automatically. Free
     accounts: pick an id nobody else has used, for example with your name in
     it.
   - `PAGE_ENTITLEMENTS`: **only for a paid team.** It turns on push. With a
     free Apple ID leave it out (the default, `Page/Page.entitlements`, has no
     push) or the build fails to sign.

4. Generate the Xcode project and open it:

   ```sh
   xcodegen generate
   open Page.xcodeproj
   ```

   Run `xcodegen generate` again whenever you edit `Local.xcconfig` or
   `project.yml`. Edit `project.yml`, never the `.xcodeproj`.

5. In Xcode pick the **Page** scheme and your iPhone, then Run. On the phone
   you may need to turn on Developer Mode (Settings ▸ Privacy & Security) and
   trust your developer profile (Settings ▸ General ▸ VPN & Device
   Management). Allow notifications when asked.

6. **Pair.** On the Mac: menu-bar icon, **Pair phone…**. It refuses until the
   relay is on and its URL is valid, so finish Step 2 first. On the phone:
   **Scan pairing code**. The phone checks your relay's `/health` and
   `/status` before it saves anything, then asks you to confirm.

   It worked if the phone shows your Mac as online.

**Treat the QR code as a password.** Anyone with the token can read your pages
and send replies. If it leaks, use **Regenerate token…** in the pairing
window and pair again.

More detail, including the Simulator and development shortcuts, is in
[`iOS/README.md`](../iOS/README.md).

## Step 4: Android (optional)

1. Install the Android SDK (platform 35, build-tools 35.0.0) and a JDK 17 or
   later. With Android Studio, install both from the SDK Manager and use its
   bundled JDK. Gradle will not download missing SDK parts for you; the build
   fails instead.

2. Tell Gradle where the SDK is (the file is git-ignored), and build a debug
   APK:

   ```sh
   cd android
   echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
   export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
   ./gradlew :app:assembleDebug
   ```

3. Install it with USB debugging on:

   ```sh
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

   Without `adb`, copy the APK to the phone and allow **Install unknown
   apps** for the app you open it with. The debug build is
   `app.page.android.debug`.

4. **Your own signing key (optional, for a release APK you keep).** The
   release build is signed with the debug key unless you give it your own.
   Updating keeps your pairing only if the new APK uses the same key, so make
   one key and keep it safe, **outside the repo**:

   ```sh
   keytool -genkeypair -v -keystore ~/page-release.jks -alias page \
     -keyalg RSA -keysize 2048 -validity 10000
   ```

   The build reads your key from environment variables, so nothing is written
   into the repo:

   ```sh
   export PAGE_KEYSTORE=~/page-release.jks
   export PAGE_KEYSTORE_PASSWORD='…'
   export PAGE_KEY_ALIAS=page          # optional, defaults to "page"
   export PAGE_KEY_PASSWORD='…'        # optional, defaults to the store password
   ./gradlew :app:assembleRelease
   ```

   The APK lands in `app/build/outputs/apk/release/`. Without `PAGE_KEYSTORE`
   the release build falls back to the debug key.

5. **Pair.** On the Mac: **Pair phone…**. In the app: **Pair with your Mac**
   scans the QR. Or choose **Paste a pairing link instead** and paste the
   JSON from **Copy pairing JSON**. Android 13 and later asks for the
   notification permission once, after pairing.

   For steady pages with the screen off, turn on **Stay connected** (Tower,
   then Attention) and exclude Page from battery optimisation if your phone's
   battery saver stops it.

## Optional: Page Aura link

[Page Aura](https://github.com/roysinclair/page-studio-apps) is a separate
bring-your-own-key Claude chat app for the Mac. If you use it, Page can keep
the Mac awake while Page Aura writes a reply, page your phone when a reply
finishes or a tool wants approval, and let you answer from the phone. They
talk over a local Unix socket on your Mac, and Page Aura never touches your
relay. It is on by default in Page (Preferences ▸ Agents ▸ **Page Aura**) and
you also switch it on in Page Aura's own settings. Nothing to deploy. The
protocol is in [`AURA-LINK.md`](AURA-LINK.md).

## Checklist: every value that is yours

None of the author's values are needed anywhere. Each of these is created by
you, in your accounts.

| Value | Where it comes from | Where you put it |
|---|---|---|
| Relay URL (`https://page-relay.<you>.workers.dev`) | Printed by `npm run deploy` | Mac: Preferences ▸ Macs & phones ▸ Relay URL (`relayURL` in `config.json`). Phones get it from the QR |
| Cloudflare account | Free sign-up | `npx wrangler login` (stored by Wrangler on your Mac) |
| iOS bundle id | You choose, unique to your team | `PAGE_BUNDLE_ID` in `iOS/Config/Local.xcconfig` **and** `APNS_BUNDLE_ID` in `Cloudflare/wrangler.toml`. The two must match |
| `APNS_ENV` | `development` for Xcode builds, `production` for TestFlight and App Store | `Cloudflare/wrangler.toml` |
| Apple team id | Xcode ▸ Settings ▸ Accounts, or developer.apple.com Membership | `DEVELOPMENT_TEAM` in `Local.xcconfig`; `APNS_TEAM_ID` Worker secret (push only) |
| Push entitlements | Paid team only | `PAGE_ENTITLEMENTS = Page/Page-Push.entitlements` in `Local.xcconfig` |
| APNs key (`.p8`) and its Key ID | developer.apple.com ▸ Keys (paid team only) | Worker secrets `APNS_KEY_P8`, `APNS_KEY_ID`. Keep the file outside the repo |
| Mac signing identity | Your keychain | `CODESIGN_IDENTITY` environment variable, or let `build.sh` pick one |
| Android keystore and passwords | You generate with `keytool` | Outside the repo; referenced from your `build.gradle.kts` edit |
| Relay token | Generated on your Mac | `relay_token.txt` in `~/Library/Application Support/ClaudePowerMode/`; reaches the phone only through the QR |

Never commit `Local.xcconfig`, a `.p8`, a keystore, or the relay token. The
repo's `.gitignore` covers `Local.xcconfig` but not `.p8` or keystore files,
so keep those outside the checkout.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Mac menu says the relay is off or misconfigured | Preferences ▸ Macs & phones: relay on, URL valid, **Test** passes. The `your-page-relay.workers.dev` placeholder counts as unset |
| `/health` says `apnsConfigured: false` | A secret is missing. Set all three: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` |
| No pushes, but pages show when the app is open | Push needs a paid team and `PAGE_ENTITLEMENTS = Page/Page-Push.entitlements`. Then `npx wrangler tail`, or `GET /status` with your token, shows Apple's reason (`lastPushError`) |
| `BadDeviceToken` | The token is for the other Apple push server. Xcode builds are `development`; TestFlight and App Store builds are `production`. Current phones report theirs; for older ones set `APNS_ENV` and redeploy |
| `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` in `wrangler.toml` doesn't match the app's bundle id. Fix it and redeploy |
| `InvalidProviderToken` | Wrong `APNS_KEY_ID` or `APNS_TEAM_ID`, or the key was revoked |
| `key_error … not valid base64` or `SEC1 "EC PRIVATE KEY"` | The secret was truncated by a paste (pipe the file), or the key isn't the original PKCS#8 `.p8` |
| Xcode: "no provisioning profile" or push entitlement error | Free Apple ID with `Page-Push.entitlements`. Remove the `PAGE_ENTITLEMENTS` line, or use a paid team. Check `PAGE_BUNDLE_ID` isn't taken by another team |
| App on iPhone stops opening after a week | Free provisioning expires after 7 days. Run it from Xcode again |
| Pair phone… refuses | The relay is off, or its URL is unset, invalid or still the placeholder |
| Phone refuses the QR | The relay must be `https://` (or `wss://`), not the placeholder, and must answer `/health` as a Page relay. A local `wrangler dev` (http) can't be paired from a phone |
| Phone says the Mac is offline | Check the Mac menu for the relay state. The Mac reconnects after wake. `GET /status` shows `macConnected` and `lastHeartbeatAt` |
| "No Mac has ever connected with this pairing" | You scanned an old QR or a token you regenerated. Pair again |
| Everything answers 410 `token_retired` | The token was regenerated on the Mac. Scan the new QR |
| Sessions tab says to re-pair | The pairing has no session key (made by an older Page). Unpair and scan again |
| macOS keeps asking for Automation or Accessibility permission again | You are building ad-hoc. Install an Apple Development certificate and rebuild |
| Mac widgets missing | Ad-hoc builds have no team id, so `build.sh` skips them. Sign with a real identity |
| Android: pages arrive late | No push on Android. Turn on Stay connected and exclude Page from battery optimisation |
| Android: Gradle says an SDK component is missing | Install platform 35 and build-tools 35.0.0 in the SDK Manager. Gradle won't download them |

Log locations: `~/Library/Logs/ClaudePowerMode.log` (the Mac app),
`~/Library/Logs/page-hook.log` (hooks), and `npx wrangler tail` (the Worker).
The main [README](../README.md#troubleshooting) has the rest.

## Set it up with an AI agent

You can hand steps 1 to 4 to Claude Code running on your Mac. The agent does
the commands; you do the parts that need you (browser logins, Apple sign-in,
choosing names, scanning the QR). Open Claude Code in an empty folder, with
the recommended model and effort below, and paste the prompt.

**Recommended:** Claude Opus 5.5 at **high** effort. Setup is long, touches
several tools and must stop at the right moments, so a strong model at high
effort is worth it. Start Claude Code in the folder you cloned like this:

```sh
claude --model claude-opus-5-5 --effort high
```

(Already inside Claude Code? Use `/model` to pick Opus 5.5 and `/effort high`.)

```text
You are helping me self-host "Page" on this Mac, following docs/SELF-HOSTING.md
from https://github.com/roysinclair/page. Do the work yourself with shell
commands, but stop and ask me whenever a step needs a human. Work one step at a
time, verify it, and report the result in one or two lines before moving on.

Rules:
- Never invent a value. Account names, bundle ids, team ids, key ids and URLs
  must come from me or from command output. If you do not have one, ask.
- Never commit anything. Do not run git commit, git push or git add. The only
  repo files you may edit are Cloudflare/wrangler.toml and the git-ignored
  iOS/Config/Local.xcconfig (and android/local.properties).
- Never print, log, echo or paste secrets: the .p8 key, passwords, the relay
  token, keystore passwords. Do not put them in files inside the repo.
- Never use sudo unless I say so. Page's install never needs it.
- Before each step, read the matching section of docs/SELF-HOSTING.md and the
  files it links (Cloudflare/wrangler.toml, iOS/Config/Local.xcconfig.example,
  build.sh, install.sh, android/README.md). If the doc and the code disagree,
  follow the code and tell me.

Start:
0. Clone https://github.com/roysinclair/page.git into a folder I name (ask me
   where) and cd into it. Check: macOS version, `xcode-select -p`,
   `node --version` (needs 22.18 or later), `jq --version`, `curl --version`.
   Tell me what is missing and how to install it. Then ask me:
   a) Do I have a paid Apple Developer Program team? (decides push)
   b) Do I want iPhone, Android, both, or neither?
   c) The bundle id I want for the iPhone app (reverse-domain, unique to my
      team, e.g. com.myname.page). Skip if no iPhone.

Step 1, relay:
1. `cd Cloudflare && npm ci`.
2. Run `npx wrangler login`. This opens a browser. Stop and wait until I say I
   have finished logging in. Then run `npx wrangler whoami` to confirm.
3. Edit Cloudflare/wrangler.toml [vars]: set APNS_BUNDLE_ID to my bundle id and
   APNS_ENV to "development" (Xcode builds) unless I said TestFlight, then
   "production". Show me the diff.
4. If I have a paid team: ask me for the path to my AuthKey_*.p8 (outside the
   repo), the 10-character Key ID and the 10-character Team ID. Then run
   `cat <path> | npx wrangler secret put APNS_KEY_P8`, and put APNS_KEY_ID and
   APNS_TEAM_ID the same way, typing the values I gave you. If wrangler asks
   for something interactive that you cannot answer, tell me exactly what to
   type in my own terminal.
5. `npm run deploy`. If wrangler asks me to choose a workers.dev subdomain,
   stop and ask me. Capture the printed URL, which looks like
   https://page-relay.<subdomain>.workers.dev.
6. Verify: `curl <url>/health` must return ok:true. If I set the APNs secrets,
   apnsConfigured must be true. Do not continue until it passes.

Step 2, Mac app:
1. From the repo root run `security find-identity -v -p codesigning` and tell me
   which identity build.sh will pick (Apple Development first, then Developer
   ID Application, else ad-hoc) and what that means (ad-hoc: no widgets, macOS
   forgets permissions each rebuild). Ask whether to continue or whether I want
   to create an Apple Development certificate in Xcode first.
2. Run `./install.sh`. It must finish with a successful codesign verify and
   Page.app in /Applications. Report any error in full.
3. Ask me to open the menu-bar Page icon, then Preferences, then Macs & phones,
   turn on "Send pages to my phone", paste the relay URL and click Test. Wait
   for me to say it passed. (Do not try to click through the Mac UI yourself.)
   You may instead check ~/Library/Application Support/ClaudePowerMode/config.json
   shows relayEnabled true and my relayURL, without printing any token.
4. Tell me the power helpers and agent hooks are optional and how to get them
   from the menu. Do not install them unless I ask.

Step 3, iPhone (only if I chose it):
1. Ask me to confirm Xcode is installed with my Apple ID signed in, and ask for
   my 10-character team id. Do not guess it.
2. `cd iOS`, copy Config/Local.xcconfig.example to Config/Local.xcconfig (keep it
   git-ignored) and set DEVELOPMENT_TEAM and PAGE_BUNDLE_ID. Set
   PAGE_ENTITLEMENTS = Page/Page-Push.entitlements ONLY if I have a paid team.
   Make sure APNS_BUNDLE_ID in wrangler.toml equals PAGE_BUNDLE_ID. If it does
   not, fix it and redeploy the Worker.
3. `xcodegen generate` (install it with brew only if I agree). Then try a
   device-signed build with `xcodebuild -project Page.xcodeproj -scheme Page
   -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build`.
   If the Metal toolchain is missing run `xcodebuild -downloadComponent MetalToolchain`.
   A build success is the check. If signing fails, show me the error and ask.
4. Ask me to run the app on my iPhone from Xcode (or tell me to if your build
   cannot install it), then on the Mac choose "Pair phone…" from the Page menu
   and scan the QR in the app. Wait for me. Verify with me that the phone shows
   the Mac as online. You cannot scan the QR for me.

Step 4, Android (only if I chose it):
1. Check for the Android SDK (platform 35, build-tools 35.0.0), a JDK 17 or
   later and `adb`. Tell me what is missing. Do not install SDK parts without
   asking.
2. In android/: write local.properties with sdk.dir, then
   `./gradlew :app:assembleDebug`. A successful build is the check.
3. With my phone connected and USB debugging on, `adb install -r
   app/build/outputs/apk/debug/app-debug.apk`. Then ask me to pair with
   "Pair phone…" on the Mac and "Pair with your Mac" in the app.
4. Only if I ask for my own signing key: help me make a keystore OUTSIDE the
   repo, and read passwords from environment variables, never from the repo.

Finish: summarise what is running, list every value I chose and where it is
stored (use the checklist in docs/SELF-HOSTING.md), confirm nothing secret is in
`git status`, and list anything left for me to do.
```
