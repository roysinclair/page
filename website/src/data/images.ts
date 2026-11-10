// Intrinsic sizes of the files in public/img (WebP), so every <img> gets width/height and no layout shift.
export const imageSize: Record<string, [number, number]> = {
  'agents-compared': [1500, 1195],
  'android-decision': [720, 1597],
  'android-notifications': [720, 1099],
  'android-room': [720, 1238],
  'app-icon': [384, 384],
  'iphone-brief': [720, 1844],
  'iphone-decision': [720, 1660],
  'iphone-dispatch': [720, 1660],
  'iphone-paired': [720, 1557],
  'iphone-scan': [720, 1557],
  'iphone-sky': [720, 1991],
  'iphone-tower': [720, 1916],
  'iphone-welcome': [720, 1557],
  'mac-menubar-states': [1700, 1020],
  'mac-tower': [1700, 1063],
  'problem-states': [1700, 797],
  'room-codex': [720, 1628],
  'room-ollama': [720, 1417],
  'signature-motion': [1700, 1337],
  'widgets': [1700, 720],
  // Showcase art (public/img/showcase). The *-visual files are the device side of each slide, cut by
  // scripts/showcase-crops.mjs (npm run crops): the slides carry their own headline, which the pages set as live text.
  'showcase/hero': [2880, 1440],
  'showcase/og': [1200, 630],
  'showcase/family': [2400, 1500],
  'showcase/hero-visual': [1680, 1440],
  'showcase/family-visual': [2400, 1112],
  'showcase/feature-battery-visual': [920, 870],
  'showcase/feature-terminals-visual': [945, 815],
  'showcase/feature-widgets-visual': [895, 870],
  'showcase/feature-sessions-visual': [845, 960],
  'showcase/feature-lock-screen-visual': [895, 895],
  'showcase/feature-android-visual': [980, 910],
  'showcase/feature-relay-visual': [900, 930],
  'showcase/feature-aura-visual': [920, 660],
  'showcase/feature-budgets-visual': [950, 910],
  'showcase/feature-budget-stop-visual': [860, 900],
  // Product screenshots for Page Aura, Page Orbit and Page Power, cut from the apps' own docs screenshots and
  // renders (fixture data) by scripts/product-shots.py. Each has smaller copies in imageVariants for srcset.
  'aura/hero': [2000, 1175],
  'aura/light': [1600, 940],
  'aura/tools': [672, 1640],
  'aura/approval': [1300, 266],
  'aura/context': [1100, 1124],
  'aura/memory': [1100, 510],
  'aura/notes': [900, 822],
  'aura/branch': [900, 836],
  'aura/balance': [494, 180],
  'aura/desktop': [1280, 860],
  'aura/settings': [560, 780],
  'orbit/session': [2000, 1250],
  'orbit/overview': [1600, 1000],
  'orbit/agent': [1600, 1000],
  'orbit/tools': [1300, 293],
  'orbit/versions': [579, 306],
  'orbit/restore': [620, 72],
  'orbit/diagnose': [1300, 1093],
  'orbit/timeline': [798, 1575],
  'orbit/schedule': [1300, 419],
  'orbit/vault': [1300, 403],
  'orbit/memory': [1300, 817],
  'orbit/environment': [1300, 752],
  'power/lock': [782, 1690],
  'power/now': [720, 1561],
  'power/decision': [720, 1561],
  'power/pairing': [834, 443],
};

/** Smaller copies for srcset, as [width, name]. */
export const imageVariants: Record<string, [number, string][]> = {
  'showcase/hero-visual': [[960, 'showcase/hero-visual-960']],
  'showcase/family-visual': [[1200, 'showcase/family-visual-1200']],
  'aura/hero': [[1200, 'aura/hero-1200'], [720, 'aura/hero-720']],
  'aura/light': [[900, 'aura/light-900']],
  'aura/tools': [[420, 'aura/tools-420']],
  'aura/approval': [[760, 'aura/approval-760']],
  'aura/context': [[640, 'aura/context-640']],
  'aura/memory': [[640, 'aura/memory-640']],
  'aura/notes': [[560, 'aura/notes-560']],
  'aura/branch': [[560, 'aura/branch-560']],
  'aura/desktop': [[760, 'aura/desktop-760']],
  'orbit/session': [[1200, 'orbit/session-1200'], [720, 'orbit/session-720']],
  'orbit/overview': [[900, 'orbit/overview-900']],
  'orbit/agent': [[900, 'orbit/agent-900']],
  'orbit/tools': [[760, 'orbit/tools-760']],
  'orbit/diagnose': [[760, 'orbit/diagnose-760']],
  'orbit/timeline': [[480, 'orbit/timeline-480']],
  'orbit/schedule': [[760, 'orbit/schedule-760']],
  'orbit/vault': [[760, 'orbit/vault-760']],
  'orbit/memory': [[760, 'orbit/memory-760']],
  'orbit/environment': [[760, 'orbit/environment-760']],
  'power/lock': [[480, 'power/lock-480']],
  'power/now': [[440, 'power/now-440']],
  'power/decision': [[440, 'power/decision-440']],
  'power/pairing': [[480, 'power/pairing-480']],
};

// ---- Single place that decides which file an image name points at -------------------------------------------
// Every <img> on the site goes through imageSrc()/imageDims(). To swap a screenshot for a polished showcase
// composite later, add an entry here (path relative to public/, plus its size), e.g.
//   'hero-aurora': { src: 'img/showcase/hero.webp', size: [1600, 1000] },
import { u } from './site';

export const imageOverrides: Record<string, { src: string; size?: [number, number] }> = {};

export const imageSrc = (name: string): string => u(imageOverrides[name]?.src ?? `img/${name}.webp`);
export const imageDims = (name: string): [number, number] => imageOverrides[name]?.size ?? imageSize[name];
/** srcset for an image name: its smaller copies plus the full file, or undefined when there is only one. */
export const imageSrcset = (name: string): string | undefined => {
  const v = imageVariants[name];
  if (!v || imageOverrides[name]) return undefined;
  return [...v.map(([w, n]) => `${u(`img/${n}.webp`)} ${w}w`), `${imageSrc(name)} ${imageDims(name)[0]}w`].join(', ');
};

/** Social preview image (produced by the showcase art pass). 1200 x 630 WebP. */
export const OG_IMAGE = 'img/showcase/og.webp';
export const OG_SIZE: [number, number] = [1200, 630];
