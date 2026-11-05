// Terminal theme packs (xterm.js ITheme). The family warm palette plus
// classics; light themes are named so the UI can pick a sane default per
// app theme.

export interface TermTheme {
  id: string;
  label: string;
  dark: boolean;
  theme: Record<string, string>;
}

export const termThemes: TermTheme[] = [
  {
    id: 'warm-dark',
    label: 'Warm Dark',
    dark: true,
    theme: {
      background: '#1a1917',
      foreground: '#e8e5e0',
      cursor: '#e8e5e0',
      selectionBackground: '#4a4a4a',
      black: '#1a1917',
      red: '#c9583a',
      green: '#8aa46a',
      yellow: '#c9a25a',
      blue: '#7a8fb5',
      magenta: '#a97fa0',
      cyan: '#6fa0a0',
      white: '#e8e5e0',
    },
  },
  {
    id: 'warm-light',
    label: 'Warm Light',
    dark: false,
    theme: {
      background: '#f5f2ed',
      foreground: '#2c2a26',
      cursor: '#2c2a26',
      selectionBackground: '#d8d2c8',
      black: '#2c2a26',
      red: '#b0572c',
      green: '#5f7a3d',
      yellow: '#a07d2c',
      blue: '#3d5a8a',
      magenta: '#8a4a7a',
      cyan: '#2c7a7a',
      white: '#f5f2ed',
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
