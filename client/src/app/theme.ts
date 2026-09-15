/**
 * Light or dark, chosen by the person at the keyboard.
 *
 * Never the operating system. Until 21 August 2026 the dashboard followed
 * `prefers-color-scheme`, and anyone whose laptop was set to dark got a dark
 * dashboard with no way back; it was pinned light for that reason. Dark came
 * back on 15 September 2026 as a header toggle, starting light for everyone.
 *
 * The choice is per browser, in localStorage, and is applied as
 * `data-theme="dark"` on <html>. `index.html` applies it before first paint so
 * a dark page does not flash white on load; keep the key in step with it.
 */

import { useCallback, useState } from 'react';

export type Theme = 'light' | 'dark';

/** Also read by the inline script in index.html. */
export const THEME_KEY = 'manna.theme';

type Storage = Pick<globalThis.Storage, 'getItem' | 'setItem'>;

/** Anything but an explicit "dark" — missing, garbage, unreadable — is light. */
export function readTheme(storage: Storage | undefined): Theme {
  try {
    return storage?.getItem(THEME_KEY) === 'dark' ? 'dark' : 'light';
  } catch {
    // Storage can throw when blocked; that is not a reason to go dark.
    return 'light';
  }
}

export function saveTheme(storage: Storage | undefined, theme: Theme): void {
  try {
    storage?.setItem(THEME_KEY, theme);
  } catch {
    // Still applied for this visit; it just will not survive a reload.
  }
}

export function applyTheme(root: HTMLElement, theme: Theme): void {
  if (theme === 'dark') root.dataset.theme = 'dark';
  else delete root.dataset.theme;
}

function storage(): Storage | undefined {
  return typeof localStorage === 'undefined' ? undefined : localStorage;
}

export function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState<Theme>(() => readTheme(storage()));
  const toggle = useCallback(() => {
    setTheme((current) => {
      const next: Theme = current === 'dark' ? 'light' : 'dark';
      saveTheme(storage(), next);
      applyTheme(document.documentElement, next);
      return next;
    });
  }, []);
  return [theme, toggle];
}
