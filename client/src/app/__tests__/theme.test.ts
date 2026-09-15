import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { readTheme, saveTheme, THEME_KEY } from '../theme';

function memory(initial: Record<string, string> = {}) {
  const data = { ...initial };
  return {
    data,
    getItem: (k: string) => (k in data ? data[k] : null),
    setItem: (k: string, v: string) => {
      data[k] = v;
    },
  };
}

describe('theme', () => {
  it('starts light for someone who has never chosen', () => {
    // The dashboard went dark on people who never asked for it once already.
    expect(readTheme(memory())).toBe('light');
  });

  it('remembers dark once chosen', () => {
    const s = memory();
    saveTheme(s, 'dark');
    expect(readTheme(s)).toBe('dark');
    saveTheme(s, 'light');
    expect(readTheme(s)).toBe('light');
  });

  it('reads anything unexpected as light', () => {
    expect(readTheme(memory({ [THEME_KEY]: 'Dark' }))).toBe('light');
    expect(readTheme(undefined)).toBe('light');
    const blocked = {
      getItem: () => {
        throw new Error('SecurityError');
      },
      setItem: () => {
        throw new Error('SecurityError');
      },
    };
    expect(readTheme(blocked)).toBe('light');
    expect(() => saveTheme(blocked, 'dark')).not.toThrow();
  });

  it('shares its key with the pre-paint script in index.html', () => {
    // Rename one without the other and a dark choice flashes white on every
    // load, then is forgotten.
    const html = readFileSync(new URL('../../../index.html', import.meta.url), 'utf8');
    expect(html).toContain(`'${THEME_KEY}'`);
  });

  it('is never driven by the operating system', () => {
    const css = readFileSync(new URL('../../styles/global.css', import.meta.url), 'utf8');
    expect(css).not.toMatch(/@media\s*\(\s*prefers-color-scheme/);
    expect(css).toContain(":root[data-theme='dark']");
  });
});
