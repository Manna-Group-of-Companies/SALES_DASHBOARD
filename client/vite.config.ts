import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

// `loadEnv` is required here: Vite puts `.env*` values on `import.meta.env` for
// the app, but it does NOT put them on `process.env` for this config file. Read
// straight from `process.env` and `VITE_ERP_URL` is undefined, the proxy
// silently falls back to localhost, and every /api call comes back as a 500
// from the dev server rather than from ERPNext.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const target = env.VITE_ERP_URL || 'http://localhost:8000';

  return {
    plugins: [react()],
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url)),
      },
    },
    server: {
      port: 5174,
      // When VITE_USE_MOCK=false, ERPNext is reached through this proxy so the
      // browser sees same-origin requests and Frappe's session cookie sticks.
      proxy: {
        '/api': {
          target,
          changeOrigin: true,
          // Without this the upstream `Set-Cookie` keeps its original Domain
          // and the browser drops the `sid` — a login that "succeeds" but
          // leaves every following request unauthenticated.
          cookieDomainRewrite: '',
        },
        /*
         * Attachments — odometer photos and expense bills.
         *
         * Frappe stores them under `/private/files/...` (session-gated) and
         * `/files/...` (public), NOT under `/api`. Without these an <img>
         * pointing at a photo is served by Vite, 404s, and silently degrades
         * to a broken image — which is exactly what a reviewer needs to see.
         *
         * `/assets` is deliberately NOT proxied: that is Vite's own namespace.
         */
        '/private': { target, changeOrigin: true, cookieDomainRewrite: '' },
        '/files': { target, changeOrigin: true, cookieDomainRewrite: '' },
      },
    },
  };
});
