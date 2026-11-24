/**
 * Notices a new deploy while a tab is open, and picks it up.
 *
 * The dashboard is a single-page app: moving between screens, or signing out
 * and back in, never reloads its code. A tab opened before a deploy therefore
 * keeps running the old build for as long as it stays open. On 24 Nov 2026 a
 * manager's tab still showed the old order status an hour after the fix went
 * live, and it read as the fix not working.
 *
 * So the tab asks the site which build it now serves (the entry script named
 * in index.html, which Cloudflare sends with `max-age=0, must-revalidate`) on
 * start, every few minutes and whenever the tab comes back into view. When it
 * differs from the build this tab runs, the next screen change reloads the
 * page - leaving a screen loses nothing that staying would keep - and until
 * then `stale` is true so the shell can offer a Reload button.
 *
 * Production only: the dev server has no hashed entry script to compare.
 */
import { useEffect, useRef, useState } from 'react';

const ENTRY = /\/assets\/index-[A-Za-z0-9_-]+\.js/;
const EVERY_MS = 5 * 60_000;

/** The entry script this tab was started from, e.g. `/assets/index-CnorDnBn.js`, or null. */
export function runningBuild(doc: Document = document): string | null {
  for (const s of Array.from(doc.querySelectorAll('script[src]'))) {
    const m = ENTRY.exec((s as HTMLScriptElement).src);
    if (m) return m[0];
  }
  return null;
}

/** The entry script named in an index.html, or null. */
export function servedBuild(indexHtml: string): string | null {
  return ENTRY.exec(indexHtml)?.[0] ?? null;
}

/** True only when both are known and they differ. An unreadable answer is never "new". */
export function isNewBuild(running: string | null, served: string | null): boolean {
  return !!running && !!served && running !== served;
}

/**
 * `stale` once the site serves a newer build than this tab runs. Reloads the
 * page on the first change of `routeKey` after that.
 */
export function useNewBuild(routeKey: string): { stale: boolean; reload: () => void } {
  const [stale, setStale] = useState(false);
  const running = useRef<string | null>(null);
  const firstRoute = useRef(routeKey);

  useEffect(() => {
    if (import.meta.env.DEV) return;
    running.current = runningBuild();
    if (!running.current) return;
    let live = true;
    const check = () => {
      fetch('/', { cache: 'no-store', credentials: 'same-origin' })
        .then((r) => (r.ok ? r.text() : ''))
        .then((html) => {
          if (live && isNewBuild(running.current, servedBuild(html))) setStale(true);
        })
        .catch(() => undefined); // offline or a blip: try again next time
    };
    check();
    const id = window.setInterval(check, EVERY_MS);
    const onShow = () => {
      if (document.visibilityState === 'visible') check();
    };
    document.addEventListener('visibilitychange', onShow);
    window.addEventListener('focus', check);
    return () => {
      live = false;
      window.clearInterval(id);
      document.removeEventListener('visibilitychange', onShow);
      window.removeEventListener('focus', check);
    };
  }, []);

  // A new build is waiting and the user has moved to another screen: load it.
  useEffect(() => {
    if (stale && routeKey !== firstRoute.current) window.location.reload();
    firstRoute.current = routeKey;
  }, [routeKey, stale]);

  return { stale, reload: () => window.location.reload() };
}
