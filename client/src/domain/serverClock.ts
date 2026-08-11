/**
 * The clock every deadline is judged against.
 *
 * Two things in this app turn on the time: whether an order can still be
 * edited (13:00 on the delivery date), and which week an order belongs to.
 * Both decide whether a user is allowed to do something, so neither may be
 * judged against a clock that user controls. A browser clock is a setting.
 *
 * Frappe returns a `Date` header on every response, so the offset between the
 * server and this machine is measured from ordinary traffic — no clock
 * endpoint, no extra request. Until the first response lands the offset is
 * zero and `now()` is the local time; that is the honest fallback, and
 * `isSynced` lets a screen say so rather than implying an authority it does
 * not yet have.
 */

let offsetMs = 0;
let synced = false;

/**
 * Record the server's clock from a response's `Date` header.
 *
 * The header has one-second resolution, so this is accurate to about a second
 * — far finer than the hour-scale deadlines it governs. Network latency is
 * deliberately not corrected for: it would add complexity to a figure whose
 * error is already an order of magnitude below what anything reads it for.
 */
export function noteServerDate(header: string | undefined | null): void {
  if (!header) return;
  const server = Date.parse(header);
  if (Number.isNaN(server)) return;
  offsetMs = server - Date.now();
  synced = true;
}

/** The current time, on the server's clock. */
export function serverNow(): Date {
  return new Date(Date.now() + offsetMs);
}

/** Whether a server response has been seen yet. */
export function isSynced(): boolean {
  return synced;
}

/**
 * How far this machine's clock is from the server's, in seconds.
 *
 * Surfaced so a screen can warn when the two disagree by enough to change an
 * answer — a user whose clock is a day out would otherwise see a different
 * week selected than the one their actions land in.
 */
export function clockSkewSeconds(): number {
  return Math.round(offsetMs / 1000);
}
