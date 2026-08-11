# Hosting the dashboard

The code lives on GitHub; **Cloudflare Workers** builds and serves it. Push to
`main` and the site redeploys.

> **This was Cloudflare Pages until 11 Aug 2026.** The project's deploy command
> is `npx wrangler deploy`, which is the *Workers* path, and Workers does not
> read `functions/`. The two products are configured differently and the
> difference is not cosmetic — see "Why `wrangler.jsonc` is committed" below
> before changing any of it.

## Why not GitHub Pages

It cannot work for this app, and the reason is worth recording so nobody tries
again.

The dashboard authenticates with Frappe's session cookie. The live site sends it
as:

```
sid=…; Secure; HttpOnly; Path=/; SameSite=Lax
```

Three separate blockers follow from that:

- **`SameSite=Lax`** — the browser will not attach that cookie to a *cross-site*
  request. A dashboard on `you.github.io` calling `mannarubber.m.frappe.cloud`
  gets a login that appears to succeed, then every request after it arrives
  unauthenticated.
- **`HttpOnly`** — JavaScript cannot read the cookie and re-send it by hand, so
  there is no client-side way around the first point.
- **CORS is pinned** to `Access-Control-Allow-Origin: https://mannarubber.m.frappe.cloud`,
  so another origin is refused before any of this matters.

All three would have to be weakened on the ERPNext site — for the mobile app
too — to make a static-only host work. A reverse proxy avoids the question
entirely: the browser only ever talks to one origin, so the cookie stays
first-party and `SameSite=Lax` is satisfied.

GitHub Pages has no proxy. Cloudflare does — as a Worker here, or as Pages
Functions on the old setup.

## What is in the repo

| Path | Purpose |
|---|---|
| `wrangler.jsonc` | Worker name, the `dist` asset binding, SPA fallback, `ERP_URL` |
| `worker/index.js` | the live entry point: routes `/api`, `/private`, `/files` to the proxy |
| `functions/_proxy.js` | the shared proxy; strips `Domain=` from `Set-Cookie` |
| `functions/api/[[path]].js` | the Pages equivalent of `worker/index.js` — **not used by Workers** |
| `functions/private/[[path]].js` | ditto, for `/private/*` — session-gated attachments |
| `functions/files/[[path]].js` | ditto, for `/files/*` — public attachments |
| `.env.production` | **turns the mock data off** |

`functions/` is kept so a move back to Pages needs no code, but nothing under
it runs today apart from `_proxy.js`, which both entry points import. Fix the
proxy in `_proxy.js` and both hosts get the fix.

## Why `wrangler.jsonc` is committed

Run `wrangler deploy` in a project with no config and it does not fail. It runs
its first-time setup, guesses "Vite" from the layout, and writes an
assets-only config with no `main`. The deploy then succeeds and ships the
bundle **without the reverse proxy** — which is the failure the whole first
half of this document exists to prevent: a login that appears to work followed
by every request arriving unauthenticated.

`public/_redirects` was deleted in the same change. Its one rule —
`/*  /index.html  200` — is rejected outright by Workers, which already strips
`.html` and `/index` and so reads the rule as an infinite loop:

```
Invalid _redirects configuration:
Line 11: Infinite loop detected in this rule. [code: 100324]
```

`"not_found_handling": "single-page-application"` does the same job. It has one
sharp edge, which is why `run_worker_first` sits next to it: on its own it
answers *every* unmatched path with `index.html`, so `/api/**` would get a page
of HTML instead of ERPNext. The path list in `wrangler.jsonc` and the `PROXIED`
regex in `worker/index.js` must stay in step.

`.env.production` is not optional. `USE_MOCK` defaults to `true` in
`src/api/config.ts`, so a production build without it ships the fixture
database — and nothing on screen says so.

## One-time setup

1. Push this repo to GitHub.
2. Cloudflare dashboard → **Workers & Pages** → **Create** → **Workers** →
   **Connect to Git**, and pick the repo.
3. Build settings:

   | Setting | Value |
   |---|---|
   | Root directory | `client` |
   | Build command | `npm run build` |
   | Deploy command | `npx wrangler deploy` |

   There is no "build output directory" to set. `wrangler.jsonc` names `dist`
   as the asset directory, which is why that file has to be committed.

4. If the build fails on the Node version, set `NODE_VERSION = 22` as a build
   environment variable. `.nvmrc` pins it too, but Cloudflare reads that only
   for some project types.

5. `ERP_URL` needs no dashboard entry — it is in `wrangler.jsonc` under `vars`,
   deliberately, because the fallback in `_proxy.js` is the live site and an
   unset variable therefore fails silently rather than loudly. It is still read
   at runtime, so pointing at a staging site is a config edit, not a rebuild.

   A dashboard variable of the same name is **overwritten** on every deploy by
   the value in `wrangler.jsonc`. Change it in the file.

6. Deploy. The site is at `https://<worker>.<subdomain>.workers.dev`, or add
   your own domain under **Domains & Routes**.

## Testing it locally before you push

```bash
npm run build
npx wrangler dev --port 8788 --local
```

No `--binding` flag: `wrangler.jsonc` supplies `ERP_URL`, and startup prints it
back to you along with the `ASSETS` binding. Four things to check, all verified
working on 11 Aug 2026:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/                       # 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/orders/SAL-ORD-2026-00106  # 200, NOT 404
curl -s -i http://127.0.0.1:8788/api/method/frappe.auth.get_logged_user | head -8      # Frappe's own 403
curl -s -i http://127.0.0.1:8788/api/method/frappe.auth.get_logged_user | grep -i set-cookie
```

The third should show `Server: Frappe Cloud` — that proves the proxy reached
ERPNext rather than the static site answering. The fourth should show five
separate `Set-Cookie` lines with **no `Domain=`** on any of them.

The second is the one that catches a broken `wrangler.jsonc`, and the third is
the one that catches a missing `main`. Run both before pushing a change to
either file.

## Who can get in

The URL is public; the login screen is the gate. ERPNext authenticates every
user and the `custom_is_*` flags on `User` decide what they see — the same
posture as the mobile app. No unauthenticated request reaches any data: every
API call needs the `sid` cookie.

To give someone access, enable their ERPNext user and set the right flag. To
remove it, disable the user. There is no separate account system here to drift
out of step.

## Things to know

- **HTTPS is required.** The cookies are `Secure`, so the site will not hold a
  login over plain HTTP. A `workers.dev` URL is HTTPS by default; a custom domain
  needs its certificate active before login works.
- **Responses are `no-store, private`.** Authenticated data must never be cached
  at the edge — one user's order list served to the next would be the worst
  failure this could have.
- **The bundle carries no secrets.** Only `VITE_USE_MOCK` and
  `VITE_MIN_STOCK_POLL_MS` reach the client. `ERP_URL` lives in the Cloudflare
  environment and is used only by the proxy.
- **`xlsx` is 429 kB** of the bundle and loads on every page. It is only needed
  by the Excel export, so it is worth code-splitting if first load matters.
