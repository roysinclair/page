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
  [`${D}/family.png`, 'family-visual', { left: 0, top: 372, width: 2400, height: 1128 }, [1200], 'family'],
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
for (const [src, name, box, widths = [], special] of crops) {
  if (only && !name.includes(only)) continue;
  let img = sharp(src).extract(box);
  if (special === 'family') {
    // The subtitle's last line ends 3px above the relay lock box: paint it out with the sky colour,
    // feathered, so the crop can keep some air above the lock.
    const buf = await img.png().toBuffer();
    // The sky behind it is not one colour: darker at the left, lighter round the relay's glow.
    const veil = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${box.width}" height="${box.height}">
      <defs>
        <linearGradient id="h" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="rgb(5,7,12)"/><stop offset="0.29" stop-color="rgb(7,10,19)"/><stop offset="0.54" stop-color="rgb(12,15,27)"/><stop offset="0.79" stop-color="rgb(7,13,20)"/><stop offset="1" stop-color="rgb(6,14,20)"/></linearGradient>
        <linearGradient id="v" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset="0.86" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
        <mask id="m"><rect x="0" y="0" width="${box.width}" height="43" fill="url(#v)"/></mask>
      </defs>
      <rect x="0" y="0" width="${box.width}" height="43" fill="url(#h)" mask="url(#m)"/></svg>`);
    img = sharp(buf).composite([{ input: veil, top: 0, left: 0 }]);
  }
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
