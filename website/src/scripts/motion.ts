// Night Watch signature motion for the website. No libraries: Web Animations, CSS and one scroll listener.
// Only runs when the head script set html.motion (motion allowed, not printing, not opted out); otherwise
// the CSS default, the finished design, is what shows. Timings are the apps' own (iOS/Page/Models).

const root = document.documentElement;
const ENABLED = root.classList.contains('motion');

// ---- curves (MotionCurves.swift) ---------------------------------------------------------------------------
const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const smooth = (x: number) => { const t = clamp01(x); return t * t * (3 - 2 * t); };
const easeOut = (x: number) => 1 - Math.pow(1 - clamp01(x), 3);
/** SwiftUI's .spring(response:dampingFraction:) step response, as in MotionCurve.spring. */
function spring(t: number, response: number, damping: number) {
  if (t <= 0) return 0;
  const w = (2 * Math.PI) / response;
  if (damping >= 1) return 1 - Math.exp(-w * t) * (1 + w * t);
  const d = damping * w, wd = w * Math.sqrt(1 - damping * damping);
  return 1 - Math.exp(-d * t) * (Math.cos(wd * t) + (d / wd) * Math.sin(wd * t));
}
const LINEAR_OK = typeof CSS !== 'undefined' && CSS.supports?.('animation-timing-function', 'linear(0, 1)');
/** The spring as a CSS easing over `ms`, so the browser runs it on its own clock. */
function springEasing(response: number, damping: number, ms: number) {
  if (!LINEAR_OK) return 'cubic-bezier(0.2, 0.85, 0.25, 1)';
  const n = 28, pts: string[] = [];
  for (let i = 0; i <= n; i++) pts.push(i === n ? '1' : spring((ms / 1000) * (i / n), response, damping).toFixed(4));
  return `linear(${pts.join(', ')})`;
}
const OUT = 'cubic-bezier(0.25, 0.8, 0.3, 1)';
const IN_OUT = 'cubic-bezier(0.45, 0, 0.55, 1)';

/** One-shot, seekable (fill both keeps it in document.getAnimations()). */
function play(el: Element, frames: Keyframe[], ms: number, opts: KeyframeAnimationOptions = {}) {
  return el.animate(frames, { duration: ms, fill: 'both', easing: 'linear', ...opts });
}
/** Keyframes on one master timeline: [ms, props, easing-to-next?]. */
function timeline(total: number, points: [number, Keyframe, string?][]): Keyframe[] {
  return points.map(([t, k, e]) => ({ ...k, offset: clamp01(t / total), ...(e ? { easing: e } : {}) }));
}

function onEnter(els: Iterable<Element>, run: (el: Element) => void, threshold = 0.2) {
  const list = [...els];
  if (!list.length) return;
  if (!('IntersectionObserver' in window)) { list.forEach(run); return; }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { io.unobserve(e.target); run(e.target); }
  }, { threshold, rootMargin: '0px 0px -6% 0px' });
  list.forEach((el) => io.observe(el));
}

// ---- 2. Final approach -------------------------------------------------------------------------------------
// ApproachModel: leaves the pulse, contrail at 180 ms, lands at 360, settled with its glow off at 520;
// spring(response 0.5, damping 0.8); several arrivals leave 90 ms apart.
function approachCard(el: HTMLElement, delay: number) {
  const ms = 520;
  play(el, [{ opacity: 0 }, { opacity: 1 }], 160, { delay, easing: OUT });
  play(el, [{ transform: 'translateY(-34px) scale(0.965)' }, { transform: 'none' }], ms, { delay, easing: springEasing(0.5, 0.8, ms) });
  const glow = document.createElement('span');
  glow.className = 'fa-glow';
  glow.setAttribute('aria-hidden', 'true');
  if (getComputedStyle(el).position === 'static') el.style.position = 'relative';
  el.appendChild(glow);
  play(glow, timeline(ms, [[0, { opacity: 0 }, OUT], [180, { opacity: 0.9 }], [360, { opacity: 0.9 }, IN_OUT], [ms, { opacity: 0 }]]), ms, { delay });
}

function approachVisual(el: HTMLElement) {
  // A lead visual: the same spring, a touch longer because it travels further.
  const ms = 760;
  play(el, [{ opacity: 0 }, { opacity: 1 }], 260, { easing: OUT });
  play(el, [{ transform: 'translateY(-30px) scale(0.975)' }, { transform: 'none' }], ms, { easing: springEasing(0.62, 0.8, ms) });
}

function approachHero(stage: HTMLElement) {
  // The home hero: the pulse sends one ripple, then the whole composition descends from it into place,
  // trailing a contrail; the amber glow is off once it has settled.
  const visual = stage.querySelector<HTMLElement>('.fa-item');
  const contrail = stage.querySelector('.hero-contrail');
  const glow = stage.querySelector('.hero-glow');
  if (!visual) return;
  const delay = 340, ms = 1300;
  play(visual, [{ opacity: 0 }, { opacity: 1 }], 300, { delay, easing: OUT });
  play(visual, [{ transform: 'translateY(-72px) scale(0.93)' }, { transform: 'none' }], ms, { delay, easing: springEasing(1.0, 0.8, ms) });
  if (contrail) play(contrail, timeline(ms, [[0, { opacity: 0, transform: 'scaleY(0)' }, OUT], [260, { opacity: 0.9, transform: 'scaleY(1)' }], [620, { opacity: 0.7, transform: 'scaleY(1)' }, IN_OUT], [1000, { opacity: 0, transform: 'scaleY(1)' }], [ms, { opacity: 0, transform: 'scaleY(1)' }]]), ms, { delay });
  if (glow) play(glow, timeline(ms, [[0, { opacity: 0 }, OUT], [320, { opacity: 1 }], [700, { opacity: 0.8 }, IN_OUT], [ms, { opacity: 0 }]]), ms, { delay });
}

function initApproach() {
  const hooks = document.querySelectorAll<HTMLElement>('[data-motion="final-approach"]');
  const hero = [...hooks].filter((h) => h.dataset.approach === 'hero');
  hero.forEach((stage) => {
    const img = stage.querySelector('img');
    let started = false;
    const go = () => { if (!started) { started = true; approachHero(stage); } };
    if (img && !img.complete) { img.decode?.().then(go, go); setTimeout(go, 900); } else go();
  });
  onEnter([...hooks].filter((h) => h.dataset.approach !== 'hero'), (hook) => {
    const el = hook as HTMLElement;
    const items = el.classList.contains('fa-item') ? [el] : [...el.querySelectorAll<HTMLElement>('.fa-item')];
    if (el.dataset.approach === 'cards') items.forEach((c, i) => approachCard(c, i * 90));
    else items.forEach((v) => approachVisual(v));
  }, 0.12);
}

// ---- 3. The receipt thread ---------------------------------------------------------------------------------
// ReceiptThread.swift: the thread reaches the relay in 0.5 s and the Mac 0.36 s later; it is verified 0.6 s
// after it lands; the outcome is shown in words. Here a page first travels Mac -> relay -> phone, then the
// reply's thread comes back and turns green only when the Mac confirms.
function threadDiagram(hook: Element) {
  const T = 4600;
  for (const svg of hook.querySelectorAll('svg')) {
    const rt = svg.querySelector('.rt');
    if (!rt) continue;
    const q = (s: string) => [...rt.querySelectorAll(s)];
    const tall = !!rt.querySelector('.rt-v');
    const S = (v: number) => (tall ? `scaleY(${v})` : `scaleX(${v})`);
    const grow = (a: number, b: number): Keyframe[] => timeline(T, [[0, { transform: S(0) }], [a, { transform: S(0) }, OUT], [b, { transform: S(1) }], [T, { transform: S(1) }]]);
    // page: Mac -> relay (0-420), relay -> phone (560-980)
    q('.rt-amber .rt-a').forEach((e) => play(e, grow(0, 420), T));
    q('.rt-amber .rt-b').forEach((e) => play(e, grow(560, 980), T));
    q('.rt-amber').forEach((e) => play(e, timeline(T, [[0, { opacity: 1 }], [1500, { opacity: 1 }, IN_OUT], [1900, { opacity: 0 }], [T, { opacity: 0 }]]), T));
    // reply: phone -> relay (2000-2500, "sent"), relay -> Mac (2560-2920, "typed")
    q('.rt-blue .rt-b').forEach((e) => play(e, grow(2000, 2500), T));
    q('.rt-blue .rt-a').forEach((e) => play(e, grow(2560, 2920), T));
    q('.rt-blue').forEach((e) => play(e, timeline(T, [[0, { opacity: 1 }], [3520, { opacity: 1 }, IN_OUT], [3980, { opacity: 0 }], [T, { opacity: 0 }]]), T));
    // verified 0.6 s after it reached the Mac: the thread turns green and stays
    q('.rt-green').forEach((e) => play(e, timeline(T, [[0, { opacity: 0 }], [3520, { opacity: 0 }, OUT], [3900, { opacity: 1 }], [T, { opacity: 1 }]]), T));
    const flash = (sel: string, color: string, at: number) => q(sel).forEach((e) => {
      (e as SVGElement).style.stroke = color;
      play(e, timeline(T, [[0, { opacity: 0 }], [at, { opacity: 0 }, OUT], [at + 160, { opacity: 0.9 }, IN_OUT], [at + 700, { opacity: 0 }], [T, { opacity: 0 }]]), T);
    });
    flash('.rt-box-relay', '#F5B14C', 420);
    flash('.rt-box-phone', '#F5B14C', 980);
    flash('.rt-box-mac', '#34D399', 3520);
    const word = (sel: string, a: number, b: number | null) => q(sel).forEach((e) => play(e, timeline(T, b === null
      ? [[0, { opacity: 0 }], [a, { opacity: 0 }, OUT], [a + 260, { opacity: 1 }], [T, { opacity: 1 }]]
      : [[0, { opacity: 0 }], [a, { opacity: 0 }, OUT], [a + 220, { opacity: 1 }], [b - 220, { opacity: 1 }, IN_OUT], [b, { opacity: 0 }], [T, { opacity: 0 }]]), T));
    word('.rt-w-page', 120, 1700);
    word('.rt-w-sent', 2000, 2700);
    word('.rt-w-typed', 2760, 3520);
    word('.rt-w-verified', 3520, null);
  }
}
function threadChips(list: Element) {
  // The phone's delivery states light up in order: sending, queued, delivered (or failed, with the reason).
  [...list.children].filter((li) => li.tagName === 'LI').forEach((li, i) => {
    play(li, [{ opacity: 0.3, transform: 'translateY(3px)' }, { opacity: 1, transform: 'none' }], 360, { delay: i * 220, easing: OUT });
  });
}
function initThread() {
  onEnter(document.querySelectorAll('[data-motion="receipt-thread"]'), (el) => {
    if (el.tagName === 'OL') threadChips(el); else threadDiagram(el);
  }, 0.35);
}

// ---- 4. The hold ring --------------------------------------------------------------------------------------
// HoldRing.swift: nothing for 300 ms, fill over 1.2 s, amber warming to red only in the final third; let go
// early and it unwinds (never slower than 1.2 s from full) and nothing is sent; full -> biometrics -> burst.
function initHoldRing() {
  document.querySelectorAll<HTMLElement>('[data-motion="hold-ring"]').forEach((demo) => {
    const btn = demo.querySelector<HTMLButtonElement>('.hr-btn');
    const status = demo.querySelector<HTMLElement>('.hr-status');
    if (!btn || !status) return;
    const fills = [...demo.querySelectorAll<SVGCircleElement>('.hr-fill')];
    const red = demo.querySelector<SVGCircleElement>('.hr-red')!;
    const label = demo.querySelector<HTMLElement>('.hr-label')!;
    const hand = demo.querySelector<SVGGElement>('.hr-hand')!;
    const face = demo.querySelector<SVGGElement>('.hr-face')!;
    const ok = demo.querySelector<SVGCircleElement>('.hr-core-ok')!;
    const burst = demo.querySelector<SVGCircleElement>('.hr-burst')!;
    const initial = status.textContent;
    const DEAD = 300, FILL = 1200, UNWIND = 1200;
    let progress = 0, raf = 0, phase: 'idle' | 'holding' | 'unwinding' | 'done' = 'idle', t0 = 0, from = 0, auto = false;

    const draw = (p: number) => {
      progress = p;
      fills.forEach((c) => c.setAttribute('stroke-dashoffset', String(100 - 100 * p)));
      red.setAttribute('opacity', String(clamp01((p - 2 / 3) * 3)));
    };
    const loop = (now: number) => {
      if (phase === 'holding') {
        const e = now - t0;
        draw(e <= DEAD ? 0 : Math.min(1, (e - DEAD) / FILL));
        if (progress >= 1) return complete();
      } else if (phase === 'unwinding') {
        draw(Math.max(0, from - (now - t0) / UNWIND));
        if (progress <= 0) { phase = 'idle'; return; }
      } else return;
      raf = requestAnimationFrame(loop);
    };
    const start = (isAuto = false) => {
      if (phase === 'done' || phase === 'holding') return;
      auto = isAuto;
      cancelAnimationFrame(raf);
      phase = 'holding';
      // resume from where an unwind left it, as if held that long already
      t0 = performance.now() - (progress > 0 ? DEAD + progress * FILL : 0);
      raf = requestAnimationFrame(loop);
    };
    const release = () => {
      if (phase !== 'holding') return;
      cancelAnimationFrame(raf);
      if (progress > 0) status.textContent = 'Let go early: the ring unwinds and nothing is sent.';
      else status.textContent = 'A tap does nothing here. Irreversible actions need a deliberate hold.';
      phase = 'unwinding'; from = progress; t0 = performance.now();
      raf = requestAnimationFrame(loop);
    };
    const complete = () => {
      phase = 'done';
      draw(1);
      label.textContent = 'Face ID…';
      hand.setAttribute('opacity', '0');
      face.setAttribute('opacity', '1');
      setTimeout(() => {
        ok.setAttribute('opacity', '1');
        face.setAttribute('stroke', '#05261B');
        label.textContent = 'Approved';
        status.textContent = auto
          ? 'Held for 1.5 s, then Face ID: approved. Your turn: press and hold. (A demo: it sends nothing.)'
          : 'Approved. In the app, Page would now type it into the exact terminal. (A demo: it sends nothing.)';
        if (ENABLED) play(burst, [{ opacity: 0.9, transform: 'scale(1)' }, { opacity: 0, transform: 'scale(1.45)' }], 600, { easing: OUT, fill: 'none' });
        setTimeout(reset, 2200);
      }, 450);
    };
    const reset = () => {
      ok.setAttribute('opacity', '0');
      face.setAttribute('opacity', '0');
      hand.setAttribute('opacity', '1');
      label.textContent = 'Hold to approve';
      phase = 'unwinding'; from = progress; t0 = performance.now();
      raf = requestAnimationFrame(loop);
    };

    btn.addEventListener('pointerdown', (e) => { if (e.button !== 0) return; btn.setPointerCapture?.(e.pointerId); status.textContent = initial; start(); });
    btn.addEventListener('pointerup', release);
    btn.addEventListener('pointercancel', release);
    btn.addEventListener('lostpointercapture', release);
    btn.addEventListener('contextmenu', (e) => e.preventDefault());
    btn.addEventListener('keydown', (e) => {
      if (e.key !== ' ' && e.key !== 'Enter') return;
      e.preventDefault();
      if (!e.repeat) { status.textContent = initial; start(); }
    });
    btn.addEventListener('keyup', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); release(); } });
    btn.addEventListener('blur', release);
    // A click on its own (a screen reader's double tap) is not a hold.
    btn.addEventListener('click', (e) => { e.preventDefault(); if (phase === 'idle' && progress === 0 && e.detail === 0) status.textContent = 'Press and hold Space or Enter: a tap does nothing for an irreversible action.'; });

    // Play it once by itself when it first comes into view (motion only).
    if (ENABLED && demo.dataset.autoplay) onEnter([demo], () => {
      setTimeout(() => {
        if (phase !== 'idle' || progress > 0) return;
        start(true);
      }, 500);
    }, 0.6);
  });
}

// ---- 5. Dusk and dawn --------------------------------------------------------------------------------------
// DawnModel: dusk falls over 1.6 s (stars exhale and dim to 30%), the paused sky holds only its horizon,
// then dawn sweeps up over 1.8 s, the stars relight and the gold settles away over 1.2 s.
function initSky() {
  const sky = document.querySelector('.nw-sky');
  if (!sky) return;
  const [, dusk, dawn] = [...sky.children] as HTMLElement[];
  let queued = false;
  const update = () => {
    queued = false;
    const max = root.scrollHeight - innerHeight;
    const p = max > 0 ? clamp01(scrollY / max) : 0;
    // Working aurora at the top, dusk through the middle of the page, dawn rising at the end.
    const d = smooth((p - 0.12) / 0.38) * (1 - smooth((p - 0.62) / 0.3));
    const a = smooth((p - 0.6) / 0.4);
    dusk.style.opacity = d.toFixed(3);
    dawn.style.opacity = a.toFixed(3);
  };
  addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(update); } }, { passive: true });
  addEventListener('resize', update);
  update();
}
function duskTile(tile: Element) {
  const T = 5600;
  const q = (s: string) => tile.querySelector(s);
  const work = q('.dd-work'), night = q('.dd-night'), dawn = q('.dd-dawn'), stars = q('.dd-stars'), horizon = q('.dd-horizon');
  if (work) play(work, timeline(T, [[0, { opacity: 1 }], [200, { opacity: 1 }, IN_OUT], [1800, { opacity: 0 }], [T, { opacity: 0 }]]), T);
  if (night) play(night, timeline(T, [[0, { opacity: 0 }], [200, { opacity: 0 }, IN_OUT], [1800, { opacity: 1 }], [2800, { opacity: 1 }, IN_OUT], [4600, { opacity: 0 }], [T, { opacity: 0 }]]), T);
  if (stars) play(stars, timeline(T, [[0, { opacity: 0.9, transform: 'scale(1)' }], [440, { opacity: 1, transform: 'scale(1.04)' }, IN_OUT], [1400, { opacity: 0.27, transform: 'scale(0.95)' }], [3400, { opacity: 0.27, transform: 'scale(0.95)' }, OUT], [4200, { opacity: 0.95, transform: 'scale(1.02)' }], [T, { opacity: 0.8, transform: 'none' }]]), T);
  if (horizon) play(horizon, timeline(T, [[0, { opacity: 0.15 }], [700, { opacity: 0.15 }, IN_OUT], [1800, { opacity: 1 }], [2800, { opacity: 1 }, IN_OUT], [3700, { opacity: 0.6 }], [T, { opacity: 0.6 }]]), T);
  if (dawn) play(dawn, timeline(T, [[0, { opacity: 0, transform: 'translateY(70%)' }], [2800, { opacity: 0, transform: 'translateY(70%)' }, OUT], [4600, { opacity: 1, transform: 'none' }], [4800, { opacity: 1, transform: 'none' }, IN_OUT], [T, { opacity: 0, transform: 'none' }]]), T);
}
function dawnBox(box: HTMLElement) {
  box.classList.add('dd-box');
  const sweep = document.createElement('i');
  sweep.className = 'dd-sweep';
  sweep.setAttribute('aria-hidden', 'true');
  box.prepend(sweep);
  const T = 3600;
  play(sweep, timeline(T, [[0, { opacity: 0, transform: 'translateY(100%)' }, OUT], [1800, { opacity: 1, transform: 'none' }], [2400, { opacity: 1, transform: 'none' }, IN_OUT], [T, { opacity: 0, transform: 'none' }]]), T, { delay: 200 });
}
function initDuskDawn() {
  initSky();
  onEnter(document.querySelectorAll('[data-motion="dusk-dawn"]'), (el) => {
    if (el.classList.contains('dd-tile')) duskTile(el); else dawnBox(el as HTMLElement);
  }, 0.5);
}

// ---- go ----------------------------------------------------------------------------------------------------
if (ENABLED) {
  root.classList.add('motion-live');
  initApproach();
  initThread();
  initDuskDawn();
  // Printing mid-animation: jump every one-shot to its end.
  addEventListener('beforeprint', () => document.getAnimations().forEach((a) => {
    if (a.effect?.getComputedTiming().iterations !== Infinity) a.finish();
  }));
}
// The hold ring is a control as well as a motion, so it works with Reduce Motion too (no burst, no autoplay).
initHoldRing();
