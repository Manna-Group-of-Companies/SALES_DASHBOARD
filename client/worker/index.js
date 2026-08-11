/**
 * The Worker that serves the dashboard.
 *
 * Two jobs, and the order matters:
 *
 * 1. `/api`, `/private` and `/files` are forwarded to ERPNext by `proxy()`, so
 *    the browser only ever talks to this origin and Frappe's `SameSite=Lax`
 *    session cookie stays first-party. See `proxy.js` for why that is the only
 *    way the login works at all.
 * 2. Everything else is a static asset, or a React Router deep link that has no
 *    file behind it. `env.ASSETS` answers both — `not_found_handling:
 *    "single-page-application"` in `wrangler.jsonc` returns `index.html` with a
 *    200 for anything unmatched, so `/orders/SAL-ORD-2026-00106` loads the app
 *    instead of 404ing. That setting replaces the old `public/_redirects`,
 *    which Workers Assets rejects: its `/* -> /index.html` rule looks like an
 *    infinite loop once `.html` stripping is applied.
 *
 * `run_worker_first` in `wrangler.jsonc` narrows this Worker to the three
 * proxied prefixes, so a request for a hashed JS bundle is served straight off
 * the asset store and never runs this code. The `env.ASSETS` fallback below
 * still covers the case where the Worker runs for everything.
 */
import { proxy } from './proxy.js';

/**
 * Prefixes that belong to ERPNext rather than to this site.
 *
 * `/assets` is deliberately absent — that is Vite's own output namespace, and
 * proxying it upstream would blank the page.
 */
const PROXIED = ['/api', '/private', '/files'];

/**
 * Matched on a path-segment boundary, not a bare `startsWith`.
 *
 * `/files/x.png` and `/files` both belong upstream; a future `/filestore` route
 * of our own would not, and must not be swallowed here.
 */
function isProxied(pathname) {
  return PROXIED.some((prefix) => pathname === prefix || pathname.startsWith(prefix + '/'));
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (isProxied(pathname)) return proxy(request, env);
    return env.ASSETS.fetch(request);
  },
};
