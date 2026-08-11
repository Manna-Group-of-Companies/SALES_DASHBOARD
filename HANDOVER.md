# Manna Treads — Sales & HR Dashboard

A React dashboard for the sales managers, the General Manager, production and
HR. It talks to the same ERPNext site as the field-sales mobile app —
`https://mannarubber.m.frappe.cloud` — and holds no database of its own.

Everything here is also on GitHub at `Mannagoc/SALES_DASHBOARD`. This zip is
the same code, for when cloning is not convenient.

## What is in the zip

```
client/                 the whole application
  src/                  source
  functions/            the reverse proxy (see "Hosting" below)
  public/_redirects     SPA fallback
  .env.production       turns the fixture data off — not optional
  .nvmrc                Node 22
  DEPLOY.md             full hosting instructions
package.json etc.
```

`node_modules/` and `dist/` are deliberately absent. Both are rebuilt from the
lockfile, and shipping them makes a 200 MB zip that is out of date on arrival.

## Running it locally

```bash
cd client
npm ci          # not `npm install` — `ci` honours the lockfile exactly
npm run dev
```

Opens on <http://localhost:5174>. Sign in with an ERPNext username and
password; the dashboard has no accounts of its own.

Useful checks:

```bash
npm test        # 117 unit tests over the pricing, stock and approval rules
npm run build   # production build into client/dist
```

## Hosting

**Read `client/DEPLOY.md` before choosing a host.** The short version: this
cannot be served as plain static files.

The dashboard authenticates with Frappe's session cookie, which the site sends
as `SameSite=Lax; HttpOnly; Secure`. A `Lax` cookie is never attached to a
cross-site request, so a dashboard on a different domain calling ERPNext
directly gets a login that appears to succeed followed by requests that arrive
unauthenticated. `HttpOnly` rules out any JavaScript workaround, and the site's
CORS header is pinned to its own origin.

The fix is a reverse proxy, so the browser only ever talks to one origin. That
is what `client/functions/` does, and why GitHub Pages, S3 or any static-only
host will not work.

Two ways to deploy, both on Cloudflare Pages:

### A. Connected to Git — redeploys on every push

Settings: root directory `client`, build `npm run build`, output `dist`, and an
environment variable `ERP_URL = https://mannarubber.m.frappe.cloud` for both
Production and Preview.

### B. Direct upload — no Git needed

Use the accompanying `…-deploy.zip`, which contains an already-built `dist/`
and the `functions/` directory. In Cloudflare: **Workers & Pages → Create →
Pages → Upload assets**, then set the same `ERP_URL` variable.

Direct upload has to be repeated by hand for every change, so option A is worth
setting up once the team has repository access.

## Two things the new owner should know

- **`ERP_URL` is read at runtime, not baked into the build.** Pointing the
  dashboard at a staging site needs no rebuild — but forgetting to set it means
  the proxy falls back to a hardcoded default and keeps working against the
  live site while looking like it is not.
- **`.env.production` sets `VITE_USE_MOCK=false`.** The flag defaults to `true`
  in `src/api/config.ts`, so a build without that file ships the fixture
  database and nothing on screen says so.

## Where the rules live

Business logic is kept out of the screens, in `client/src/domain/`, so it can be
read and tested on its own:

| File | Holds |
|---|---|
| `productRules.ts` | line pricing, weights, the `qty × rate` identity |
| `minimumStock.ts` | the shelf, production runs, the order split |
| `production.ts` | stage sequences and the order roll-up |
| `orderStatus.ts` | approval vocabulary, escalation, GM exemptions |
| `geo.ts` | trip distances and what they can honestly prove |
| `weeks.ts` | Monday–Sunday weeks and the 1 pm edit freeze |

`client/src/domain/__tests__/` covers all of it, including a `live-parity` suite
that asserts this dashboard writes order lines byte-identically to the mobile
app.
