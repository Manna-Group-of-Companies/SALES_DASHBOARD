/**
 * The reverse proxy that makes hosted auth work.
 *
 * In development Vite proxies `/api`, `/private` and `/files` to ERPNext so the
 * browser only ever sees one origin. Production has to do the same thing, and
 * it is not a convenience — it is the only way the login works at all.
 *
 * Frappe sets its session cookie as:
 *
 *     sid=…; Secure; HttpOnly; Path=/; SameSite=Lax
 *
 * `SameSite=Lax` means the browser will not attach that cookie to a
 * cross-site request. So a dashboard on another domain calling ERPNext
 * directly gets a login that appears to succeed and then every subsequent
 * request arrives unauthenticated. `HttpOnly` rules out reading the cookie in
 * JavaScript and re-sending it, and the site's CORS header is pinned to its
 * own origin anyway.
 *
 * Proxying sidesteps all three: the browser talks only to this host, so the
 * cookie stays first-party and `SameSite=Lax` is satisfied.
 */

/** Hop-by-hop headers that must not be forwarded. */
const STRIP_REQUEST = new Set([
  'host',
  'connection',
  'content-length',
  'cf-connecting-ip',
  'cf-ipcountry',
  'cf-ray',
  'cf-visitor',
  'x-forwarded-host',
  'x-forwarded-proto',
]);

const STRIP_RESPONSE = new Set(['content-encoding', 'content-length', 'transfer-encoding']);

/**
 * Remove any `Domain=` from a Set-Cookie so it binds to *this* host.
 *
 * Frappe Cloud currently sends no Domain at all, which already scopes the
 * cookie to whoever served it — exactly what we want. This is kept as a guard:
 * if that ever changes, an upstream `Domain=mannarubber.m.frappe.cloud` would
 * be silently dropped by the browser and every login would break with no error
 * anywhere. Vite's `cookieDomainRewrite: ''` does the same job in dev.
 */
function stripCookieDomain(value) {
  return value
    .split(/,(?=[^;]+?=)/) // split multiple cookies, not the commas inside Expires
    .map((cookie) =>
      cookie
        .split(';')
        .filter((part) => !/^\s*domain=/i.test(part))
        .join(';'),
    )
    .join(', ');
}

/**
 * Forward one request to ERPNext and return its response.
 *
 * `env.ERP_URL` is a Cloudflare environment variable, not a build-time
 * constant, so the same bundle can point at a staging site without rebuilding.
 */
export async function proxy(request, env) {
  const upstream = (env && env.ERP_URL) || 'https://mannarubber.m.frappe.cloud';
  const incoming = new URL(request.url);
  const target = new URL(incoming.pathname + incoming.search, upstream);

  const headers = new Headers();
  for (const [key, value] of request.headers) {
    if (!STRIP_REQUEST.has(key.toLowerCase())) headers.set(key, value);
  }
  // Frappe checks Origin/Referer on write requests; make them look local to it.
  headers.set('Origin', upstream);
  headers.set('Referer', upstream + '/');

  const init = {
    method: request.method,
    headers,
    redirect: 'manual',
  };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = await request.arrayBuffer();
  }

  const response = await fetch(target.toString(), init);

  const out = new Headers();
  for (const [key, value] of response.headers) {
    if (STRIP_RESPONSE.has(key.toLowerCase())) continue;
    if (key.toLowerCase() === 'set-cookie') continue; // handled below
    out.set(key, value);
  }

  // `getSetCookie` keeps multiple Set-Cookie headers separate; Frappe sends
  // five on login and collapsing them into one string loses all but the first.
  const cookies =
    typeof response.headers.getSetCookie === 'function'
      ? response.headers.getSetCookie()
      : [response.headers.get('set-cookie')].filter(Boolean);
  for (const cookie of cookies) {
    out.append('Set-Cookie', stripCookieDomain(cookie));
  }

  // Never let a CDN cache an authenticated response — one user's order list
  // served to the next is the worst failure this could have.
  out.set('Cache-Control', 'no-store, private');

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: out,
  });
}
