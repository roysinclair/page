// Cuts the "visual" side out of each showcase slide (the slides carry their own headline on the left,
// which the website sets as live text instead), plus print JPEGs for the brochure.
// Sources: docs/images/*.png (read only) and public/img/showcase/hero.webp (the larger hero).
// Usage: npm run crops   (then npm run brochure to reprint the PDF)
import { mkdir, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import sharp from 'sharp';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const W = path.join(root, 'public', 'img');
const D = path.join(root, '..', 'docs', 'images');
const T = await mkdtemp(path.join(tmpdir(), 'page-crops-')); // lossless crops, the source of the print JPEGs
await mkdir(path.join(W, 'print'), { recursive: true });

// [source, out name, crop {left, top, width, height}, extra widths for srcset]
const crops = [
  [`${W}/showcase/hero.webp`, 'hero-visual', { left: 1200, top: 0, width: 1680, height: 1440 }, [960]],
  [`${D}/family.png`, 'family-visual', { left: 0, top: 388, width: 2400, height: 1112 }, [1200]], // starts just under the subtitle
  [`${D}/feature-battery.png`, 'feature-battery-visual', { left: 680, top: 90, width: 920, height: 870 }],
  [`${D}/feature-terminals.png`, 'feature-terminals-visual', { left: 640, top: 95, width: 945, height: 815 }],
  [`${D}/feature-widgets.png`, 'feature-widgets-visual', { left: 665, top: 80, width: 895, height: 870 }],
  [`${D}/feature-sessions.png`, 'feature-sessions-visual', { left: 715, top: 40, width: 845, height: 960 }],
  [`${D}/feature-lock-screen.png`, 'feature-lock-screen-visual', { left: 665, top: 70, width: 895, height: 895 }],
  [`${D}/feature-android.png`, 'feature-android-visual', { left: 620, top: 70, width: 980, height: 910 }],
  [`${D}/feature-relay.png`, 'feature-relay-visual', { left: 660, top: 45, width: 900, height: 930 }],
  [`${D}/feature-aura.png`, 'feature-aura-visual', { left: 640, top: 130, width: 920, height: 660 }],
];

const only = process.argv[2];
for (const [src, name, box, widths = []] of crops) {
  if (only && !name.includes(only)) continue;
  const img = sharp(src).extract(box);
  const png = await img.png().toBuffer();
  await sharp(png).toFile(path.join(T, `${name}.png`));
  await sharp(png).webp({ quality: 82, effort: 6 }).toFile(`${W}/showcase/${name}.webp`);
  for (const w of widths) await sharp(png).resize({ width: w }).webp({ quality: 80, effort: 6 }).toFile(`${W}/showcase/${name}-${w}.webp`);
  const meta = await sharp(png).metadata();
  console.log(name, meta.width, meta.height);
}

// Print copies for the brochure: JPEG, which Chromium embeds as-is (small PDF).
const print = [
  [path.join(T, 'family-visual.png'), 'family', 1800],
  [`${D}/feature-battery.png`, 'feature-battery', 1400],
  [`${D}/feature-lock-screen.png`, 'feature-lock-screen', 1400],
  [path.join(T, 'feature-terminals-visual.png'), 'feature-terminals-visual', 900],
  [path.join(T, 'feature-android-visual.png'), 'feature-android-visual', 900],
  [path.join(T, 'feature-relay-visual.png'), 'feature-relay-visual', 900],
  [path.join(T, 'feature-aura-visual.png'), 'feature-aura-visual', 900],
];
if (!only || only === 'print') for (const [src, name, w] of print) {
  const info = await sharp(src).resize({ width: w, withoutEnlargement: true }).jpeg({ quality: 82, mozjpeg: true }).toFile(`${W}/print/${name}.jpg`);
  console.log('print', name, info.width, info.height, Math.round(info.size / 1024) + 'KB');
}
