# Hosting the dashboard

The code lives on GitHub; **Cloudflare Pages** builds and serves it. Push to
`main` and the site redeploys.

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

GitHub Pages has no proxy. Cloudflare Pages does, via Functions.

## What is in the repo

| Path | Purpose |
|---|---|
| `functions/api/[[path]].js` | proxies `/api/*` to ERPNext |
| `functions/private/[[path]].js` | proxies `/private/*` — session-gated attachments |
| `functions/files/[[path]].js` | proxies `/files/*` — public attachments |
| `functions/_proxy.js` | the shared proxy; strips `Domain=` from `Set-Cookie` |
| `public/_redirects` | SPA fallback so deep links and refresh work |
| `.env.production` | **turns the mock data off** |

`.env.production` is not optional. `USE_MOCK` defaults to `true` in
`src/api/config.ts`, so a production build without it ships the fixture
database — and nothing on screen says so.

## One-time setup

1. Push this repo to GitHub.
2. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** →
   **Connect to Git**, and pick the repo.
3. Build settings:

   | Setting | Value |
   |---|---|
   | Framework preset | None |
   | Root directory | `client` |
   | Build command | `npm run build` |
   | Build output directory | `dist` |

4. If the build fails on the Node version, set `NODE_VERSION = 22` as a build
   environment variable. `.nvmrc` pins it too, but Cloudflare reads that only
   for some project types.

5. **Settings → Environment variables**, for Production *and* Preview:

   ```
   ERP_URL = https://mannarubber.m.frappe.cloud
   ```

   This is read by the proxy at runtime, not baked into the bundle, so pointing
   at a staging site later needs no rebuild.

6. Deploy. The site is at `https://<project>.pages.dev`, or add your own domain
   under **Custom domains**.

## Testing it locally before you push

```bash
npm run build
npx wrangler pages dev dist --port 8788 \
  --compatibility-date=2024-11-01 \
  --binding ERP_URL=https://mannarubber.m.frappe.cloud
```

Four things to check, all verified working on 11 Aug 2026:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/                       # 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/orders/SAL-ORD-2026-00106  # 200, NOT 404
curl -s -i http://127.0.0.1:8788/api/method/frappe.auth.get_logged_user | head -8      # Frappe's own 403
curl -s -i http://127.0.0.1:8788/api/method/frappe.auth.get_logged_user | grep -i set-cookie
```

The third should show `Server: Frappe Cloud` — that proves the proxy reached
ERPNext rather than the static site answering. The fourth should show five
separate `Set-Cookie` lines with **no `Domain=`** on any of them.

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
  login over plain HTTP. Cloudflare Pages is HTTPS by default; a custom domain
  needs its certificate active before login works.
- **Responses are `no-store, private`.** Authenticated data must never be cached
  at the edge — one user's order list served to the next would be the worst
  failure this could have.
- **The bundle carries no secrets.** Only `VITE_USE_MOCK` and
  `VITE_MIN_STOCK_POLL_MS` reach the client. `ERP_URL` lives in the Cloudflare
  environment and is used only by the proxy.
- **`xlsx` is 429 kB** of the bundle and loads on every page. It is only needed
  by the Excel export, so it is worth code-splitting if first load matters.
