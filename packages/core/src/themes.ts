// Terminal theme packs (xterm.js ITheme). Neutral, tool-grade sets —
// the app chrome must recede behind terminal content, so themes carry
// no decorative hue of their own. "pilot-dark" is the Termius-style
// default (deep desaturated navy-black, soft green foreground, grey
// cursor); light pairs with the neutral light UI.

export interface TermTheme {
  id: string;
  label: string;
  dark: boolean;
  theme: Record<string, string>;
}

export const termThemes: TermTheme[] = [
  {
    id: 'pilot-dark',
    label: 'Pilot Dark (default)',
    dark: true,
    theme: {
      background: '#141728',
      foreground: '#c8ccd2',
      cursor: '#92a0a7',
      cursorAccent: '#141728',
      selectionBackground: '#3a4250',
      black: '#141728',
      red: '#e05b57',
      green: '#5cc97c',
      yellow: '#d9c96a',
      blue: '#5d9fef',
      magenta: '#ee7b79',
      cyan: '#478fef',
      white: '#d6dde0',
      brightBlack: '#4a5060',
      brightRed: '#e16866',
      brightGreen: '#7ddc9b',
      brightYellow: '#e7ebed',
      brightBlue: '#346baf',
      brightMagenta: '#ee7b79',
      brightCyan: '#5d9fef',
      brightWhite: '#ffffff',
    },
  },
  {
    id: 'pilot-light',
    label: 'Pilot Light',
    dark: false,
    theme: {
      background: '#f7f8f9',
      foreground: '#2b2e31',
      cursor: '#5a6a72',
      cursorAccent: '#f7f8f9',
      selectionBackground: '#d3dade',
      black: '#2b2e31',
      red: '#c23f3b',
      green: '#2e8b4f',
      yellow: '#9c7d18',
      blue: '#2f62a8',
      magenta: '#b44e4b',
      cyan: '#1f7aa8',
      white: '#c5c9cc',
      brightBlack: '#6e7175',
      brightRed: '#d0524e',
      brightGreen: '#3aa55e',
      brightYellow: '#b09420',
      brightBlue: '#3d76c2',
      brightMagenta: '#c65e5a',
      brightCyan: '#2a92c4',
      brightWhite: '#ffffff',
    },
  },
  {
    id: 'campbell',
    label: 'Campbell',
    dark: true,
    theme: {
      background: '#0c0c0c',
      foreground: '#cccccc',
      cursor: '#ffffff',
      selectionBackground: '#767676',
      black: '#0c0c0c',
      red: '#c50f1f',
      green: '#13a10e',
      yellow: '#c19c00',
      blue: '#0037da',
      magenta: '#881798',
      cyan: '#3a96dd',
      white: '#cccccc',
    },
  },
  {
    id: 'solarized-dark',
    label: 'Solarized Dark',
    dark: true,
    theme: {
      background: '#002b36',
      foreground: '#839496',
      cursor: '#93a1a1',
      selectionBackground: '#274642',
      black: '#073642',
      red: '#dc322f',
      green: '#859900',
      yellow: '#b58900',
      blue: '#268bd2',
      magenta: '#d33682',
      cyan: '#2aa198',
      white: '#eee8d5',
    },
  },
  {
    id: 'solarized-light',
    label: 'Solarized Light',
    dark: false,
    theme: {
      background: '#fdf6e3',
      foreground: '#657b83',
      cursor: '#586e75',
      selectionBackground: '#eee8d5',
      black: '#073642',
      red: '#dc322f',
      green: '#859900',
      yellow: '#b58900',
      blue: '#268bd2',
      magenta: '#d33682',
      cyan: '#2aa198',
      white: '#fdf6e3',
    },
  },
  {
    id: 'gruvbox-dark',
    label: 'Gruvbox Dark',
    dark: true,
    theme: {
      background: '#282828',
      foreground: '#ebdbb2',
      cursor: '#ebdbb2',
      selectionBackground: '#504945',
      black: '#282828',
      red: '#cc241d',
      green: '#98971a',
      yellow: '#d79921',
      blue: '#458588',
      magenta: '#b16286',
      cyan: '#689d6a',
      white: '#a89984',
    },
  },
];

export function findTermTheme(id: string): TermTheme {
  return termThemes.find((t) => t.id === id) ?? termThemes[0];
}
