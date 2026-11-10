// Screenshots every composition with headless Chromium (never a visible window).
//   npm install && node shoot.mjs [name ...]      -> raw PNGs in ./out/
//   python3 compress.py                           -> ../<name>.png and website/public/img/showcase/<name>.webp
import { chromium } from 'playwright';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdirSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, 'out');
mkdirSync(out, { recursive: true });

// name, html, CSS viewport, device scale factor -> output pixels
export const jobs = [
  { name: 'hero', html: 'hero.html', w: 1200, h: 600, dpr: 2 },            // 2400x1200 README banner
  { name: 'hero@web', html: 'hero.html', w: 1200, h: 600, dpr: 2.4 },      // 2880x1440 website
  { name: 'og', html: 'og.html', w: 1200, h: 630, dpr: 1 },                // 1200x630 social card
  { name: 'og-studio', html: 'og-studio.html', w: 1200, h: 630, dpr: 1 },  // the website home page's social card
  { name: 'feature-battery', html: 'feature-battery.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-lock-screen', html: 'feature-lock-screen.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-sessions', html: 'feature-sessions.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-terminals', html: 'feature-terminals.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-android', html: 'feature-android.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-widgets', html: 'feature-widgets.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-relay', html: 'feature-relay.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-aura', html: 'feature-aura.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-budgets', html: 'feature-budgets.html', w: 800, h: 500, dpr: 2 },
  { name: 'feature-budget-stop', html: 'feature-budget-stop.html', w: 800, h: 500, dpr: 2 },
  { name: 'family', html: 'family.html', w: 1200, h: 750, dpr: 2 },        // 2400x1500
  { name: 'screen-lock', html: 'screen-lock.html', w: 782, h: 1690, dpr: 1 }, // the website's power/lock (website/scripts/product-shots.py)
];

const only = process.argv.slice(2);
const browser = await chromium.launch(); // headless by default
try {
  for (const job of jobs.filter((j) => !only.length || only.some((o) => j.name.startsWith(o)))) {
    const ctx = await browser.newContext({ viewport: { width: job.w, height: job.h }, deviceScaleFactor: job.dpr });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => console.error(`${job.name}: ${e.message}`));
    await page.goto(pathToFileURL(join(here, job.html)).href);
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map((img) => img.decode().catch(() => { throw new Error('image failed: ' + img.src); })));
    });
    await page.waitForTimeout(150);
    const file = join(out, `${job.name}.png`);
    await page.screenshot({ path: file });
    console.log(`${file}  ${Math.round(job.w * job.dpr)}x${Math.round(job.h * job.dpr)}`);
    await ctx.close();
  }
} finally {
  await browser.close();
}
