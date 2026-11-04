"""Make the website's product images (public/img/{aura,orbit,power}/) from the apps' real screenshots.

    python3 website/scripts/product-shots.py            # from the repo root; needs Pillow
    PAGE_AURA=/path/to/page-studio-apps python3 ...             # if page-studio-apps isn't checked out next to this repo

Reads (never writes) page-studio-apps' docs/ screenshots and this repo's docs/images/src/assets/ renders (fixture
data). Writes WebP files, each with smaller copies for srcset, and prints the sizes to register in
src/data/images.ts (imageSize and imageVariants). Crop boxes are in 2000-px-wide preview coordinates.
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
AURA = os.path.join(os.environ.get('PAGE_AURA', os.path.join(REPO, '..', 'page-studio-apps')), 'docs')
ORBIT = os.path.join(AURA, 'orbit')
ASSETS = os.path.join(REPO, 'docs', 'images', 'src', 'assets')
OUT = os.path.join(REPO, 'website', 'public', 'img')

# name: (source, crop box in preview px or None, preview width or None, output widths (largest first))
JOBS = {
    # ---- Page Aura (sources 3200 x 1880, preview 2000) ----
    'aura/hero':      (f'{AURA}/hero.png', None, None, [2000, 1200, 720]),
    'aura/light':     (f'{AURA}/light.png', None, None, [1600, 900]),
    'aura/tools':     (f'{AURA}/tools-menu.png', (1405, 145, 1825, 1170), 2000, [672, 420]),
    'aura/approval':  (f'{AURA}/approval.png', (668, 205, 1672, 410), 2000, [1300, 760]),
    'aura/context':   (f'{AURA}/context.png', (540, 60, 1460, 1000), 2000, [1100, 640]),
    'aura/memory':    (f'{AURA}/memory.png', (540, 374, 1460, 800), 2000, [1100, 640]),
    'aura/notes':     (f'{AURA}/notes.png', (652, 270, 1348, 906), 2000, [900, 560]),
    'aura/branch':    (f'{AURA}/edit-branch.png', None, None, [900, 560]),
    'aura/balance':   (f'{AURA}/balance.png', None, None, [494]),
    'aura/desktop':   (f'{AURA}/desktop-linux.png', None, None, [1280, 760]),
    'aura/settings':  (f'{AURA}/desktop-settings.png', None, None, [560]),
    # ---- Page Orbit (sources 2880 x 1800, preview 2000) ----
    'orbit/session':  (f'{ORBIT}/session.png', None, None, [2000, 1200, 720]),
    'orbit/overview': (f'{ORBIT}/overview.png', None, None, [1600, 900]),
    'orbit/agent':    (f'{ORBIT}/agent.png', None, None, [1600, 900]),
    'orbit/tools':    (f'{ORBIT}/agent.png', (362, 700, 1870, 1040), 2000, [1300, 760]),
    'orbit/versions': (f'{ORBIT}/versions.png', (360, 228, 762, 440), 2000, [580]),
    'orbit/restore':  (f'{ORBIT}/versions.png', (770, 748, 1390, 820), 2000, [620]),
    'orbit/diagnose': (f'{ORBIT}/diagnose.png', (362, 88, 1638, 1162), 2000, [1300, 760]),
    'orbit/timeline': (f'{ORBIT}/session.png', (1446, 156, 2000, 1250), 2000, [800, 480]),
    'orbit/schedule': (f'{ORBIT}/schedule.png', (360, 20, 1880, 510), 2000, [1300, 760]),
    'orbit/vault':    (f'{ORBIT}/vault.png', (360, 20, 1880, 492), 2000, [1300, 760]),
    'orbit/memory':   (f'{ORBIT}/memory.png', (360, 20, 1880, 975), 2000, [1300, 760]),
    'orbit/environment': (f'{ORBIT}/environment.png', (360, 20, 1880, 900), 2000, [1300, 760]),
    # ---- Page Power: raw app renders (fixture data) ----
    'power/lock':     (f'{ASSETS}/board-lock-screen.webp', None, None, [782, 480]),
    'power/now':      (f'{ASSETS}/ios-now.webp', None, None, [720, 440]),
    'power/decision': (f'{ASSETS}/ios-decision-undoable.webp', None, None, [720, 440]),
    'power/pairing':  (f'{ASSETS}/ios-pairing.webp', None, None, [834, 480]),
}

sizes, variants = {}, {}
total = 0
for name, (src, box, pw, widths) in JOBS.items():
    im = Image.open(src).convert('RGB')
    if box:
        s = im.width / pw
        im = im.crop(tuple(round(v * s) for v in box))
    for i, w in enumerate(widths):
        w = min(w, im.width)
        h = round(im.height * w / im.width)
        out = im.resize((w, h), Image.LANCZOS) if w != im.width else im
        path = f'{OUT}/{name}.webp' if i == 0 else f'{OUT}/{name}-{w}.webp'
        os.makedirs(os.path.dirname(path), exist_ok=True)
        out.save(path, 'WEBP', quality=84, method=6)
        kb = os.path.getsize(path) // 1024
        total += kb
        if i == 0:
            sizes[name] = [w, h]
        else:
            variants.setdefault(name, []).append([w, f'{name}-{w}'])
        print(f'{os.path.relpath(path, REPO):58s} {w}x{h} {kb} KB')
print('total', total, 'KB\n\n// imageSize')
for k, v in sizes.items():
    print(f"  '{k}': [{v[0]}, {v[1]}],")
print('// imageVariants')
for k, v in variants.items():
    print(f"  '{k}': [" + ', '.join(f"[{w}, '{n}']" for w, n in v) + '],')
