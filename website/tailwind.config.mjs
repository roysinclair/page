/** @type {import('tailwindcss').Config} */
// "Night Watch" tokens, read off iOS/Page/Design/NightWatch/NWTheme.swift and Designs/_brand.md,
// plus the Page Aura and Page Orbit palettes (each product keeps its own colours inside one studio system).
export default {
  content: ['./src/**/*.{astro,html,js,ts,jsx,tsx,md,mdx}'],
  theme: {
    extend: {
      colors: {
        night: {
          950: '#04060A', // backgroundDeep
          900: '#05070D', // background
          850: '#0A0C11', // inset
          800: '#14161C', // surface
          700: '#1B1E25', // surfaceRaised
        },
        ink: {
          DEFAULT: 'rgba(255,255,255,0.96)',
          2: 'rgba(255,255,255,0.72)', // secondary
          3: 'rgba(255,255,255,0.58)', // tertiary (kept AA on night-900)
        },
        pulse: { teal: '#5EEAD4', sky: '#38BDF8' },
        // Page Aura (dark): teal, blue, violet, pink
        aura: { teal: '#22d3c5', blue: '#4f86ff', violet: '#9b7bff', pink: '#d98bf5', ink: '#8fb2ff' },
        // Page Orbit "Nebula" (dark), with its accent
        orbit: { violet: '#7d4ef2', magenta: '#b73bce', rose: '#da2978', accent: '#e78ae6' },
        signal: {
          amber: '#F5B14C',
          yellow: '#F2C94C',
          green: '#34D399',
          red: '#F26D6D', // irreversible only
          violet: '#A78BFA',
          star: '#FFF6E0', // the quiet pulse
          glass: '#5FD0C8',
        },
        onbright: '#06141A',
      },
      fontFamily: {
        sans: ['"Inter Variable"', 'Inter', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['"JetBrains Mono Variable"', '"JetBrains Mono"', '"SF Mono"', 'ui-monospace', 'monospace'],
      },
      maxWidth: { content: '1200px', wide: '1320px' },
      borderRadius: { card: '24px', row: '18px', inset: '14px', tile: '28px' },
      boxShadow: {
        glow: '0 0 40px -8px rgba(94,234,212,0.35)',
        amber: '0 0 40px -10px rgba(245,177,76,0.4)',
      },
    },
  },
};
