// Prints /brochure/ to public/page-studio-brochure.pdf with headless Chromium.
// Usage: npm run brochure   (builds the site, serves it with `astro preview` so the /page/ base path works,
// prints with background graphics, and copies the PDF into dist/ too).
import { spawn } from 'node:child_process';
import { copyFile, mkdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import net from 'node:net';
import { chromium } from 'playwright';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'public', 'page-studio-brochure.pdf');

const freePort = () =>
  new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
    s.on('error', reject);
  });

const port = await freePort();
const server = spawn('npx', ['astro', 'preview', '--host', '127.0.0.1', '--port', String(port)], { cwd: root, stdio: 'ignore' });
const stop = () => server.kill();
process.on('exit', stop);

const url = `http://127.0.0.1:${port}/page/brochure/`;
for (let i = 0; ; i++) {
  try { const r = await fetch(url); if (r.ok) break; } catch {}
  if (i > 60) { stop(); throw new Error('preview server did not start'); }
  await new Promise((r) => setTimeout(r, 500));
}

const browser = await chromium.launch(); // headless only, never opens a window
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 1400 } });
  await page.emulateMedia({ media: 'print' });
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(async () => {
    // Lazy images outside the printed sheets (the site chrome) would never load: make every image eager first.
    for (const i of document.images) i.loading = 'eager';
    await Promise.all([...document.images].map((i) => (i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; }))));
  });
  await page.pdf({ path: out, preferCSSPageSize: true, printBackground: true });
} finally {
  await browser.close();
  stop();
}

await mkdir(path.join(root, 'dist'), { recursive: true });
await copyFile(out, path.join(root, 'dist', 'page-studio-brochure.pdf'));
const { size } = await stat(out);
console.log(`Wrote ${path.relative(root, out)} (${(size / 1024).toFixed(0)} KB)`);
