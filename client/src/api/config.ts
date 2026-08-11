/** Runtime switches, read once so nothing else has to touch `import.meta.env`. */

function flag(value: string | undefined, fallback: boolean): boolean {
  if (value == null || value === '') return fallback;
  return value === 'true' || value === '1';
}

function int(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/**
 * With mocking on, every service resolves from the in-memory fixture DB and no
 * network call is made. Flip `VITE_USE_MOCK=false` once the ERPNext doctypes in
 * `docs/ERPNEXT_DOCTYPES.md` exist and the same screens talk to the real site.
 */
export const USE_MOCK = flag(import.meta.env.VITE_USE_MOCK as string | undefined, true);

/** How often reps re-read the min-stock ledger to see each other's holds (1.2). */
export const MIN_STOCK_POLL_MS = int(
  import.meta.env.VITE_MIN_STOCK_POLL_MS as string | undefined,
  10_000,
);

/** Simulated latency for mock calls, so loading states are real in dev. */
export const MOCK_LATENCY_MS = 220;

export const CURRENCY = '₹';
