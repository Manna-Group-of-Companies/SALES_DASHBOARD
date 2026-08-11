/**
 * The Worker entry point.
 *
 * The site is deployed with `wrangler deploy` (Workers with static assets),
 * not `wrangler pages deploy`. Those two products route requests differently
 * and only one of them reads `functions/`:
 *
 * - **Pages** discovers `functions/api/[[path]].js` by file name and runs it
 *   before the static asset lookup. Nothing else is needed.
 * - **Workers** ignores `functions/` entirely. Routing is this file plus the
 *   `assets` block in `wrangler.jsonc`.
 *
 * So without this file a `wrangler deploy` succeeds and ships a static-only
 * site: no reverse proxy, and therefore a login that appears to work followed
 * by every request arriving unauthenticated. See `_proxy.js` for why the proxy
 * is load-bearing rather than a convenience.
 *
 * The proxy logic itself is unchanged and still lives in `../functions/_proxy.js`,
 * so both hosts run byte-identical code and there is one place to fix it.
 */
import { proxy } from '../functions/_proxy.js';

/**
 * Paths that belong to ERPNext rather than to the bundle.
 *
 * Kept in step with `run_worker_first` in `wrangler.jsonc` — that list decides
 * which requests reach this Worker at all, and this one decides what happens
 * to them once they do. A path in only one of the two is a bug.
 */
const PROXIED = /^\/(api|private|files)(\/|$)/;

export default {
  async fetch(request, env) {
    if (PROXIED.test(new URL(request.url).pathname)) {
      return proxy(request, env);
    }

    // Anything else is the SPA. `not_found_handling: single-page-application`
    // on the assets binding serves `index.html` for deep links such as
    // /orders/SAL-ORD-2026-00106, which is the job `public/_redirects` used to
    // do under Pages.
    return env.ASSETS.fetch(request);
  },
};
