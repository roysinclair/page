// Intrinsic sizes of the files in public/img (WebP), so every <img> gets width/height and no layout shift.
export const imageSize: Record<string, [number, number]> = {
  'agents-compared': [1500, 1195],
  'android-decision': [720, 1597],
  'android-notifications': [720, 1099],
  'android-room': [720, 1238],
  'app-icon': [384, 384],
  'aura-approval': [1400, 823],
  'aura-desktop': [1100, 740],
  'aura-hero': [1600, 940],
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
  'showcase/family-visual': [2400, 1128],
  'showcase/feature-battery-visual': [920, 870],
  'showcase/feature-terminals-visual': [945, 815],
  'showcase/feature-widgets-visual': [895, 870],
  'showcase/feature-sessions-visual': [845, 960],
  'showcase/feature-lock-screen-visual': [895, 895],
  'showcase/feature-android-visual': [980, 910],
  'showcase/feature-relay-visual': [900, 930],
  'showcase/feature-aura-visual': [920, 660],
};

/** Smaller copies for srcset, as [width, name]. */
export const imageVariants: Record<string, [number, string][]> = {
  'showcase/hero-visual': [[960, 'showcase/hero-visual-960']],
  'showcase/family-visual': [[1200, 'showcase/family-visual-1200']],
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
