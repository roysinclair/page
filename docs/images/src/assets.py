#!/usr/bin/env python3
"""Crops the real renders (and the few design boards) the compositions use into ./assets/*.webp.

    python3 assets.py --mac <dir> --ios <dir> --android <dir> [--aura ~/projects/page-studio-apps/docs] [--only budget|panel]

--mac      output of `.build/debug/ClaudePowerMode --render-ui <dir> --card-glow full`
--ios      output of `iOS/Tools/render-screens.sh <dir> full` (files named <screen>-glow-full.png or <screen>-full.png)
--android  output of `android/tools/screens.sh <dir> --glow full` (files named <screen>.png)
--aura     the Page Aura repo's docs/ folder (approval.png)
--only     budget: write only the budget crops (needs only the budget renders:
           Mac tower-budget and popover-budget-editor, iOS decision-budget and now-budget,
           Android decision-budget and now-budget)
           panel: write only the menu-bar panel crops (needs only --mac: popover-sessions-idle-collapsed,
           popover-sessions-swipe-close, popover-sessions-undo-close and tower-terminals-tall)

Design boards come from Designs/v4 in this repo. Every crop below was checked by eye for demo data only.
Needs Pillow with WebP support.
"""
import argparse
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(HERE, "assets")


def find(folder, *names):
    for n in names:
        p = os.path.join(folder, n)
        if os.path.exists(p):
            return p
    sys.exit(f"missing render: one of {names} in {folder}")


def save(img, name, width=None, quality=90):
    if width and img.width > width:
        img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
    path = os.path.join(OUT, name + ".webp")
    img.save(path, "WEBP", quality=quality, method=6)
    print(f"{name}.webp  {img.width}x{img.height}  {os.path.getsize(path) // 1024} KB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True)
    ap.add_argument("--ios")
    ap.add_argument("--android")
    ap.add_argument("--aura", default=os.path.expanduser("~/projects/page-studio-apps/docs"))
    ap.add_argument("--only", choices=["budget", "panel"])
    a = ap.parse_args()
    if a.only != "panel" and not (a.ios and a.android):
        ap.error("--ios and --android are needed unless --only panel")
    os.makedirs(OUT, exist_ok=True)
    if a.only is None:
        everything_else(a)
    if a.only in (None, "budget"):
        budget(a)
    if a.only in (None, "panel"):
        panel(a)


def rgba(p):
    return Image.open(p).convert("RGBA")


def rgb(p):
    return Image.open(p).convert("RGB")


def ios_screen(a, s):
    return rgb(find(a.ios, f"{s}-glow-full.png", f"{s}-full.png"))


def budget(a):
    """Budgets (feature-budgets, feature-budget-stop). Fixture names only: payments-api, sensor-hub, llm-play."""
    # Tower > Budget: the rings and the first three project rows (payments-api stopped, sensor-hub near, tokenizer-lab).
    save(rgb(find(a.mac, "tower-budget.png")).crop((56, 56, 2296, 1300)), "mac-tower-budget", width=1600)
    # The popover's payments-api card with its Set budget editor open (popover x 56..816).
    save(rgba(find(a.mac, "popover-budget-editor.png")).crop((74, 1172, 798, 1970)), "mac-popover-budget")
    # The phones: the "Stopped at its budget" sheet, and Now with the budget card under Decide.
    save(ios_screen(a, "decision-budget"), "ios-decision-budget", width=900)
    save(ios_screen(a, "now-budget"), "ios-now-budget", width=900)
    for screen in ("decision-budget", "now-budget"):
        save(rgb(find(a.android, f"{screen}-full.png", f"{screen}.png")), f"android-{screen}", width=900)


def panel(a):
    """The menu-bar panel (feature-panel, feature-panel-close). Fixture names only: sensor-hub, llm-play,
    payments-api, tokenizer-lab, docs-site, mobile-shell."""
    # The whole popover with IDLE collapsed to its names (popover x 56..816, y 56..1952).
    save(rgba(find(a.mac, "popover-sessions-idle-collapsed.png")).crop((56, 56, 816, 1952)), "mac-popover-sessions")
    # sensor-hub's FINISHED card mid-swipe, "Dismiss · close tab" uncovered (the setting on).
    save(rgba(find(a.mac, "popover-sessions-swipe-close.png")).crop((74, 318, 816, 720)), "mac-popover-swipe")
    # Tower > Terminals, the foot: THE NOW PANEL toggle, Agent hooks, Apply (window content x 600..2296).
    save(rgb(find(a.mac, "tower-terminals-tall.png")).crop((600, 2506, 2296, 3056)), "mac-tower-terminals-dismiss", width=1400)
    # The popover's foot: "Closing tokenizer-lab's cmux tab in 5s · Undo" over the footer.
    undo = rgba(find(a.mac, "popover-sessions-undo-close.png"))
    save(undo.crop((56, undo.height - 300, 816, undo.height - 56)), "mac-popover-undo-close")


def everything_else(a):
    # ---- Mac (render harness, 2x; surfaces sit on a stand-in backdrop with 56 px of padding) ----
    # Popover cards: x 56..816; their radius is 40 px. The CSS masks the corners.
    save(rgba(find(a.mac, "popover-needs-you.png")).crop((56, 56, 816, 1964)), "mac-popover-needs")
    save(rgba(find(a.mac, "popover-on-battery.png")).crop((56, 56, 816, 520)), "mac-popover-battery-head")
    # Tower windows: x 56..2296, radius 22 px. Top part only (the bottom paragraph is scrolled).
    save(rgb(find(a.mac, "tower-power.png")).crop((56, 56, 2296, 1210)), "mac-tower-power", width=1600)
    # The Page Aura row of Tower > Agents (the card's bottom row only).
    save(rgb(find(a.mac, "tower-agents.png")).crop((652, 772, 2200, 890)), "mac-tower-aura-row")
    # Widget faces (Small and Medium only: the Large face lists other demo projects).
    faces = rgba(find(a.mac, "widgets-faces-01.png"))
    save(faces.crop((50, 105, 388, 444)), "mac-widget-small-page")
    save(faces.crop((426, 105, 764, 444)), "mac-widget-small-usage")
    save(faces.crop((50, 513, 776, 852)), "mac-widget-medium-page")

    # ---- iPhone (simulator, 1179x2556) ----
    ios = lambda s: ios_screen(a, s)
    for screen, name in [("now", "ios-now"), ("decision-undoable", "ios-decision-undoable"),
                         ("room-codex", "ios-room-codex"), ("room-local", "ios-room-local")]:
        save(ios(screen), name, width=900)
    # Tower > Pairing & encryption (end-to-end encrypted, your relay).
    save(ios("tower-widgets-lockscreen").crop((44, 1976, 1137, 2556)), "ios-pairing", width=834)

    # ---- Android (headless emulator, 1080x2400) ----
    for screen, name in [("now", "android-now"), ("decision-undoable", "android-decision-undoable"), ("tower", "android-tower")]:
        save(rgb(find(a.android, f"{screen}-full.png", f"{screen}.png")), name, width=900)

    # ---- Design board (Designs/v4): the system lock screen's wallpaper, clock and widgets (base.css paints over its concepts) ----
    v4 = os.path.join(REPO, "Designs", "v4", "everywhere")
    save(rgb(os.path.join(v4, "25-iphone-lock-screen.png")), "board-lock-screen")
    # The iOS app icon, for the lock-screen notifications.
    save(rgb(os.path.join(REPO, "iOS", "Page", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")), "app-icon", width=256, quality=92)

    # ---- Page Aura ----
    ap = rgb(os.path.join(a.aura, "approval.png"))
    save(ap.crop((1050, 110, 2700, 700)), "aura-chat", width=1320)   # the chat and its tool approval
    save(ap.crop((24, 24, 330, 108)), "aura-logo")
    save(ap, "aura-window", width=1200)                             # the whole window (family image)


if __name__ == "__main__":
    main()
