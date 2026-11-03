// Deterministic star field + aurora for every composition (seeded, so re-renders match).
// Usage: <div class="sky" data-seed="7" data-density="1"></div> and
//        <div class="aurora" data-palette="teal,sky,violet" data-seed="3"></div>
(function () {
  function rng(seed) { let s = seed >>> 0 || 1; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }

  document.querySelectorAll('.sky').forEach((el) => {
    const r = rng(+el.dataset.seed || 7);
    const density = +el.dataset.density || 1;
    const fade = el.dataset.fade !== undefined ? +el.dataset.fade : 0.72; // stars thin out towards the horizon
    const c = document.createElement('canvas');
    const dpr = window.devicePixelRatio || 1;
    const w = el.clientWidth, h = el.clientHeight;
    c.width = w * dpr; c.height = h * dpr;
    el.appendChild(c);
    const g = c.getContext('2d');
    g.scale(dpr, dpr);
    const n = Math.round((w * h) / 2600 * density);
    for (let i = 0; i < n; i++) {
      const x = r() * w, y = Math.pow(r(), 1.35) * h;
      const depth = 1 - Math.min(1, y / (h * fade));
      const big = r() > 0.965;
      const rad = big ? 0.9 + r() * 0.7 : 0.35 + r() * 0.55;
      const a = (big ? 0.75 : 0.25 + r() * 0.5) * (0.25 + 0.75 * depth);
      const warm = r() > 0.8;
      g.fillStyle = warm ? `rgba(255,236,200,${a})` : `rgba(220,236,255,${a})`;
      g.beginPath(); g.arc(x, y, rad, 0, Math.PI * 2); g.fill();
      if (big) {
        const grd = g.createRadialGradient(x, y, 0, x, y, rad * 6);
        grd.addColorStop(0, `rgba(200,240,255,${a * 0.35})`); grd.addColorStop(1, 'rgba(200,240,255,0)');
        g.fillStyle = grd; g.beginPath(); g.arc(x, y, rad * 6, 0, Math.PI * 2); g.fill();
      }
    }
  });

  const colours = { teal: '#5EEAD4', sky: '#38BDF8', violet: '#A78BFA', amber: '#F5B14C', yellow: '#F2C94C', green: '#34D399' };
  document.querySelectorAll('.aurora[data-blobs]').forEach((el) => {
    // data-blobs="x,y,w,h,colour,opacity; ..." in % of the canvas
    el.dataset.blobs.split(';').map((s) => s.trim()).filter(Boolean).forEach((spec) => {
      const [x, y, w, h, col, op, blur] = spec.split(',').map((v) => v.trim());
      const i = document.createElement('i');
      Object.assign(i.style, { left: x + '%', top: y + '%', width: w + '%', height: h + '%',
        background: `radial-gradient(closest-side, ${colours[col] || col}, transparent)`, opacity: op || '.5' });
      if (blur) i.style.filter = `blur(${blur}px)`;
      el.appendChild(i);
    });
  });
})();
