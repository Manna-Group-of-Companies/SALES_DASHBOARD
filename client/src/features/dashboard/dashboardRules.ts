/**
 * Small shared helpers for the three landing pages.
 *
 * Nothing here decides anything — the dashboards are read-only surfaces, so
 * this is presentation arithmetic only. Any rule with consequences belongs in
 * `domain/`, where every screen has to go through it.
 */

/** Whole days since an ISO timestamp. Never negative, so a clock skew reads 0. */
export function daysWaiting(iso: string, now: Date = new Date()): number {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return 0;
  return Math.max(0, Math.floor((now.getTime() - then) / 86_400_000));
}

/** `plural(1, 'order')` → "order"; `plural(2, 'order')` → "orders". */
export function plural(n: number, word: string, suffix = 's'): string {
  return n === 1 ? word : `${word}${suffix}`;
}
