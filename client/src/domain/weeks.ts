/**
 * Monday-to-Sunday weeks.
 *
 * A week is the unit orders are grouped and closed in, so its boundaries have
 * to be exact and identical everywhere. Two rules make them so:
 *
 *   - **Monday to Sunday**, not the locale's idea of a week.
 *   - **On the date only, never the time.** An order taken at 23:55 on Sunday
 *     and one at 00:05 on Monday belong to different weeks. Comparing
 *     timestamps instead of dates puts them in the same one whenever the
 *     boundary lands mid-request.
 *
 * Dates are handled as `YYYY-MM-DD` strings throughout. That is what Frappe
 * stores, it is what a `between` filter compares, and it has no timezone to be
 * wrong about — a `Date` at midnight local shifts across the boundary the
 * moment anything serialises it as UTC.
 */

export interface Week {
  /** Monday, `YYYY-MM-DD`. */
  start: string;
  /** Sunday, `YYYY-MM-DD`. */
  end: string;
  /** "4 Aug – 10 Aug 2026" */
  label: string;
}

/** `YYYY-MM-DD` for a Date, read in local terms — never `toISOString`. */
export function isoDate(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** Parse `YYYY-MM-DD` as local midnight. */
export function fromIso(iso: string): Date {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number);
  return new Date(y, (m || 1) - 1, d || 1);
}

/** The Monday of the week containing `d`. */
export function mondayOf(d: Date): Date {
  const out = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  // getDay(): 0 = Sunday. Sunday belongs to the week that started six days ago.
  const back = (out.getDay() + 6) % 7;
  out.setDate(out.getDate() - back);
  return out;
}

export function addDays(d: Date, n: number): Date {
  const out = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  out.setDate(out.getDate() + n);
  return out;
}

const MONTH = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "4 Aug – 10 Aug 2026", with the year stated once. */
export function weekLabel(start: Date, end: Date): string {
  const a = `${start.getDate()} ${MONTH[start.getMonth()]}`;
  const b = `${end.getDate()} ${MONTH[end.getMonth()]}`;
  return `${a} – ${b} ${end.getFullYear()}`;
}

/** The week containing a given day. */
export function weekOf(day: Date): Week {
  const start = mondayOf(day);
  const end = addDays(start, 6);
  return { start: isoDate(start), end: isoDate(end), label: weekLabel(start, end) };
}

/**
 * This week and the `count` before it, newest first.
 *
 * `now` is passed in rather than read here so callers must hand over the
 * server's clock — the list decides which orders a manager is looking at, and
 * a browser clock a day fast would show them a week that has not happened.
 */
export function recentWeeks(now: Date, count = 13): Week[] {
  const thisMonday = mondayOf(now);
  return Array.from({ length: count }, (_, i) => weekOf(addDays(thisMonday, -7 * i)));
}

/**
 * The most recently *finished* week — the one before the current one.
 *
 * This is where "close the week" opens, because the week you are in is still
 * taking orders and grouping it would strand everything booked after the run.
 */
export function lastClosedWeek(now: Date): Week {
  return weekOf(addDays(mondayOf(now), -7));
}

/** Whether a week has finished, i.e. its Sunday is behind us. */
export function isClosed(week: Week, now: Date): boolean {
  return isoDate(now) > week.end;
}

/** Step a week back (`-1`) or forward (`+1`). */
export function shiftWeek(week: Week, by: number): Week {
  return weekOf(addDays(fromIso(week.start), 7 * by));
}

/*
 * `editCutoff` and `pastCutoff` stood here until 11 Oct 2026: 13:00 on the
 * delivery date, after which nobody but the GM could change an order. The
 * cutoff is gone — approval alone ends editing
 * (order_locked_after_approval.json).
 */

/** "08/08/2026" — for dates written out in a sentence. */
export function shortDate(iso: string | undefined | null): string {
  if (!iso) return '—';
  const d = fromIso(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()}`;
}
