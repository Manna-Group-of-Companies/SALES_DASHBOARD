/**
 * Datetimes as the SAP-sync Server Scripts write them, and "how long ago".
 *
 * The credit scripts send `isoformat()`; the stock and order scripts send
 * Python's `str()` — `2026-09-24 16:33:26.747115`, a space and microseconds.
 * Chrome reads both. Safari reads the second as Invalid Date, which would put
 * "Last synced: Never" and no cooldown on every iPhone. So the space becomes a
 * `T` and the fraction is cut to milliseconds before parsing. Either way it is
 * read as local time, which is what the scripts mean.
 */

/** Milliseconds since the epoch, or NaN for blank or unreadable. */
export function parseServerDate(v: string | null | undefined): number {
  if (!v) return NaN;
  const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)(\.\d{1,3})?\d*$/.exec(v.trim());
  return new Date(m ? `${m[1]}T${m[2]}${m[3] ?? ''}` : v).getTime();
}

/** "just now", "12 minutes ago", "3 hours ago", "2 days ago" — or "never". */
export function agoText(v: string | null | undefined, now: Date): string {
  const then = parseServerDate(v);
  if (Number.isNaN(then)) return 'never';
  const mins = Math.floor((now.getTime() - then) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} minute${mins === 1 ? '' : 's'} ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs} hour${hrs === 1 ? '' : 's'} ago`;
  const days = Math.floor(hrs / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}
