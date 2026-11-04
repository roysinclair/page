// Shared facts, links and the terminal table. Everything here is sourced from the repo's
// README.md, docs/*.md, iOS/README.md, android/README.md, Cloudflare/README.md, the Page Aura README,
// and Sources/ClaudePowerMode/TerminalCatalog.swift. Nothing is invented.

/** Build an internal URL under the site's base path (always ends in "/" for pages). */
export const u = (path = ''): string => {
  const base = import.meta.env.BASE_URL.endsWith('/') ? import.meta.env.BASE_URL : import.meta.env.BASE_URL + '/';
  return base + path.replace(/^\/+/, '');
};

export const GITHUB = 'https://github.com/roysinclair/page';
export const AURA_GITHUB = 'https://github.com/roysinclair/page-studio-apps';
export const ORBIT_GUIDE = 'https://github.com/roysinclair/page-studio-apps/blob/main/docs/orbit/README.md';
export const ORBIT_DEMO = 'https://roysinclair.github.io/page-studio-apps/page-orbit.html?demo';
export const AURA_SITE = 'https://roysinclair.github.io/page-studio-apps/';
/** Page Aura as one HTML file, opened straight in the browser. */
export const AURA_APP = 'https://roysinclair.github.io/page-studio-apps/page-aura.html';
export const AURA_GUIDE = 'https://github.com/roysinclair/page-studio-apps/blob/main/docs/aura/README.md';
/** Page Aura and Page Orbit installers (Windows, macOS, Linux), with SHA256 checksums. */
export const STUDIO_RELEASES = 'https://github.com/roysinclair/page-studio-apps/releases/latest';
export const GUIDE = 'https://github.com/roysinclair/page/blob/main/docs/SELF-HOSTING.md';
export const GUIDE_AI = GUIDE + '#set-it-up-with-an-ai-agent';
export const BLOB = GITHUB + '/blob/main/';
export const PDF = 'page-studio-brochure.pdf';

export const nav = [
  { label: 'Studio', href: '' },
  { label: 'Mac', href: 'mac/' },
  { label: 'iPhone', href: 'iphone/' },
  { label: 'Android', href: 'android/' },
  { label: 'Relay', href: 'relay/' },
  { label: 'Aura', href: 'aura/' },
  { label: 'Orbit', href: 'orbit/' },
  { label: 'Brochure', href: 'brochure/' },
];

/** Page Studio for Mac and the Page Relay pages, shown together in the nav (a menu on wide screens, a sub-bar on its pages). */
export const powerPages = [
  { label: 'Mac', title: 'Page Studio for Mac', href: 'mac/', note: 'Page Power and Page Relay in your menu bar' },
  { label: 'iPhone', title: 'Page Relay for iPhone', href: 'iphone/', note: 'Pages on your lock screen' },
  { label: 'Android', title: 'Page Relay for Android', href: 'android/', note: 'No Google account needed' },
  { label: 'Relay', title: 'Page Relay Worker', href: 'relay/', note: 'Your own Cloudflare Worker' },
];

export const pieces = [
  {
    key: 'mac',
    name: 'Page Studio for Mac',
    kicker: 'Menu-bar app · Linux preview',
    href: 'mac/',
    body: 'Watches your Claude Code and Codex sessions. Page Power keeps the Mac awake while they work and pauses them gracefully at your battery cutoff; Page Relay pages your phone and types your replies into the exact terminal that asked. A Linux preview runs headless.',
    tone: 'teal',
  },
  {
    key: 'phone',
    name: 'Page Relay for iPhone and Android',
    kicker: 'The pages',
    href: 'iphone/',
    body: 'Approve, deny or reply from the lock screen. See live sessions with a transcript, start new work, and check what changed. Build it with your own developer account and pair by QR.',
    tone: 'amber',
  },
  {
    key: 'relay',
    name: 'Page Relay Worker',
    kicker: 'Cloudflare Worker',
    href: 'relay/',
    body: 'A small Worker on your own Cloudflare account carries pages and replies between your computer and your phone. Live session content is end-to-end encrypted. Nothing goes to the authors.',
    tone: 'sky',
  },
  {
    key: 'aura',
    name: 'Page Aura',
    kicker: 'Chat on your own credits',
    href: 'aura/',
    body: 'Chat over the API on your own credits, with context, web search and tools. It works with Page Relay through Page Studio on the same computer, so your phone is paged when a reply finishes or a chat asks to use a tool, and Page Power keeps the computer awake while a reply streams.',
    tone: 'violet',
  },
  {
    key: 'orbit',
    name: 'Page Orbit',
    kicker: 'Managed Agents control room',
    href: 'orbit/',
    body: 'Manage and control Anthropic Managed Agents over the API, with diagnostics that dig deep into what they are doing. With Page Relay, your phone is paged when an agent wants your approval or has finished, and you answer from the lock screen.',
    tone: 'violet',
  },
] as const;

export type Support = 'yes' | 'no' | 'limited';

export interface Terminal {
  name: string;
  reply: Support;
  screen: Support;
  stop: Support;
  start: Support;
  answer: Support;
  photos: 'attached' | 'path';
  setup: string;
}

// From TerminalCatalog.entries (capabilities for Claude Code sessions).
export const terminals: Terminal[] = [
  { name: 'Terminal.app', reply: 'yes', screen: 'no', stop: 'no', start: 'no', answer: 'no', photos: 'path',
    setup: 'Built into macOS. macOS asks for Automation permission the first time Page Studio types here. Terminal cannot send a lone Esc, so a deny types the menu’s own “No” digit.' },
  { name: 'iTerm2', reply: 'yes', screen: 'no', stop: 'yes', start: 'no', answer: 'yes', photos: 'path',
    setup: 'Automation permission, asked once. Multi-line text is joined into one line.' },
  { name: 'tmux', reply: 'yes', screen: 'yes', stop: 'yes', start: 'no', answer: 'yes', photos: 'attached',
    setup: 'Nothing to set up: run Claude inside it. Works inside any terminal app. Refuses over a half-typed draft.' },
  { name: 'cmux', reply: 'yes', screen: 'yes', stop: 'yes', start: 'yes', answer: 'yes', photos: 'path',
    setup: 'One-time setup window in Page Studio: cmux’s socket must admit Page Studio (Password or Automation mode). Page Studio drives cmux only through its own CLI.' },
  { name: 'WezTerm', reply: 'yes', screen: 'yes', stop: 'yes', start: 'no', answer: 'yes', photos: 'path',
    setup: 'Nothing to set up. Page Studio addresses the pane by its id.' },
  { name: 'kitty', reply: 'yes', screen: 'yes', stop: 'yes', start: 'no', answer: 'yes', photos: 'path',
    setup: 'kitty.conf needs remote control on (socket only). Page Studio can add the lines for you, with a backup and an Undo. Restart kitty afterwards.' },
  { name: 'Herdr', reply: 'yes', screen: 'yes', stop: 'yes', start: 'no', answer: 'yes', photos: 'path',
    setup: 'Nothing to set up. Page Studio uses only the socket the session names, and only if you own it.' },
  { name: 'Claude Squad', reply: 'yes', screen: 'yes', stop: 'yes', start: 'no', answer: 'yes', photos: 'attached',
    setup: 'Nothing to set up. It runs each agent in tmux, so Page Studio types into the exact pane.' },
];

export const kinds = [
  { name: 'Approval', tone: 'teal', when: 'A tool call or plan is waiting for your OK.', actions: 'Approve · Deny · Deny with instructions', note: 'Pages at once.' },
  { name: 'Question', tone: 'sky', when: 'The agent asked something only you can answer.', actions: 'Typed reply, or pick an option', note: 'Pages at once.' },
  { name: 'Idle', tone: 'amber', when: 'The turn finished and nothing has been typed, while you are away.', actions: 'Carry on · typed reply', note: 'Waits until you step away.' },
  { name: 'Looks stuck', tone: 'amber', when: 'The same command failed three times in a row, or nothing was written for 15 minutes.', actions: 'Steer · Stop it (Esc)', note: 'Read from the transcript.' },
  { name: 'Rate limit', tone: 'red', when: 'A usage limit was hit. Page Studio shows the reset time.', actions: 'Information, or send a message at reset', note: 'Can hold the computer awake until the reset.' },
  { name: 'Low battery', tone: 'amber', when: 'Page Power paused the session at your cutoff.', actions: 'Carry on · stay paused · typed instructions', note: 'One page per paused session.' },
] as const;
