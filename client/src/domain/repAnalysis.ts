/**
 * Rep performance analysis — the arithmetic behind `/analysis`.
 *
 * Pure functions over two flat inputs, so the screen does not care where the
 * rows came from:
 *
 *   - `SaleLine`, one per order line: when, who, for whom, what, ₹ and kg.
 *   - `OutstandingPoint`, one per customer per snapshot date: what they owed
 *     and how old it was.
 *
 * As of 11 Oct 2026 neither exists in ERPNext with any depth. The site holds
 * 12 Sales Orders, nearly all of them tests, and no Sales Invoice or Delivery
 * Note at all — the selling history lives in SAP. And `custom_outstanding_*`
 * on Customer is overwritten by each credit sync, so there is no history of
 * it anywhere. The screen therefore runs on sample rows until a real source
 * is wired in (see `features/analysis/sampleData.ts`).
 *
 * Read only. Nothing here is a rule about money, approval or stock — it
 * reports, it never decides — so it has no twin in the phone app and no
 * fixture in `shared/`.
 *
 * Dates are `YYYY-MM-DD` strings throughout, for the reason given in
 * `weeks.ts`: a string has no timezone to be wrong about.
 */

import { addDays, fromIso, isoDate, mondayOf } from './weeks';

export interface SaleLine {
  /** The order's date — `transaction_date`, or SAP's DocDate. */
  date: string;
  /** Sales Person name. */
  rep: string;
  customer: string;
  customerName: string;
  /** Item group, the product family the mix chart groups by. */
  group: string;
  /** ₹, before tax. */
  amount: number;
  kg: number;
  /** Order reference, so orders can be counted rather than lines. */
  order: string;
}

export interface OutstandingPoint {
  date: string;
  rep: string;
  customer: string;
  total: number;
  d0_30: number;
  d30_60: number;
  d60_90: number;
  d90: number;
}

export type Grain = 'week' | 'month' | 'quarter';
export type Measure = 'amount' | 'kg';
export type Compare = 'previous' | 'lastYear' | 'none';

export interface Range {
  from: string;
  to: string;
}

export interface Bucket {
  key: string;
  label: string;
  start: string;
  end: string;
}

// ---------------------------------------------------------------- dates ---

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function startOf(day: Date, grain: Grain): Date {
  if (grain === 'week') return mondayOf(day);
  const month = grain === 'month' ? day.getMonth() : Math.floor(day.getMonth() / 3) * 3;
  return new Date(day.getFullYear(), month, 1);
}

function nextStart(start: Date, grain: Grain): Date {
  if (grain === 'week') return addDays(start, 7);
  return new Date(start.getFullYear(), start.getMonth() + (grain === 'month' ? 1 : 3), 1);
}

function labelFor(start: Date, grain: Grain): string {
  const yy = String(start.getFullYear()).slice(2);
  if (grain === 'month') return `${MONTHS[start.getMonth()]} ${yy}`;
  if (grain === 'quarter') return `Q${Math.floor(start.getMonth() / 3) + 1} ${yy}`;
  return `${start.getDate()} ${MONTHS[start.getMonth()]}`;
}

/** The bucket a date falls in — its key is the bucket's first day. */
export function bucketKey(date: string, grain: Grain): string {
  return isoDate(startOf(fromIso(date), grain));
}

/**
 * Every bucket touching the range, oldest first, empty ones included — a month
 * with no sales is a fact the chart must show, not a gap it closes up.
 */
export function bucketsBetween(range: Range, grain: Grain): Bucket[] {
  const out: Bucket[] = [];
  const last = fromIso(range.to);
  for (let s = startOf(fromIso(range.from), grain); s <= last; s = nextStart(s, grain)) {
    out.push({
      key: isoDate(s),
      label: labelFor(s, grain),
      start: isoDate(s),
      end: isoDate(addDays(nextStart(s, grain), -1)),
    });
  }
  return out;
}

function daysBetween(a: string, b: string): number {
  return Math.round((fromIso(b).getTime() - fromIso(a).getTime()) / 86_400_000);
}

/** The range a comparison is drawn against, or undefined for none. */
export function comparisonRange(range: Range, compare: Compare): Range | undefined {
  if (compare === 'none') return undefined;
  if (compare === 'lastYear') {
    const back = (iso: string) => {
      const d = fromIso(iso);
      return isoDate(new Date(d.getFullYear() - 1, d.getMonth(), d.getDate()));
    };
    return { from: back(range.from), to: back(range.to) };
  }
  // The same number of days, ending the day before this range starts.
  const len = daysBetween(range.from, range.to);
  const to = addDays(fromIso(range.from), -1);
  return { from: isoDate(addDays(to, -len)), to: isoDate(to) };
}

export function inRange<T extends { date: string }>(rows: T[], range: Range): T[] {
  return rows.filter((r) => r.date >= range.from && r.date <= range.to);
}

// ------------------------------------------------------------- summaries ---

export interface Totals {
  amount: number;
  kg: number;
  orders: number;
  customers: number;
  /** ₹ per kg across the set; 0 when nothing was weighed. */
  perKg: number;
}

export function totals(lines: SaleLine[]): Totals {
  let amount = 0;
  let kg = 0;
  const orders = new Set<string>();
  const customers = new Set<string>();
  for (const l of lines) {
    amount += l.amount;
    kg += l.kg;
    orders.add(l.order);
    customers.add(l.customer);
  }
  return { amount, kg, orders: orders.size, customers: customers.size, perKg: kg > 0 ? amount / kg : 0 };
}

/**
 * Fractional change, `0.12` for +12%. Null when there is nothing to compare
 * against: "up from nothing" is not a percentage, and showing +∞% or +100%
 * would read as a real growth figure.
 */
export function change(current: number, previous: number): number | null {
  if (!(previous > 0)) return null;
  return (current - previous) / previous;
}

export function measureOf(t: { amount: number; kg: number }, m: Measure): number {
  return m === 'amount' ? t.amount : t.kg;
}

// ---------------------------------------------------------------- series ---

export interface SeriesPoint extends Bucket {
  amount: number;
  kg: number;
  orders: number;
}

export function series(lines: SaleLine[], buckets: Bucket[], grain: Grain): SeriesPoint[] {
  const by = new Map(buckets.map((b) => [b.key, { ...b, amount: 0, kg: 0, orders: 0 }]));
  const seen = new Map<string, Set<string>>();
  for (const l of lines) {
    const k = bucketKey(l.date, grain);
    const p = by.get(k);
    if (!p) continue;
    p.amount += l.amount;
    p.kg += l.kg;
    const s = seen.get(k) ?? new Set<string>();
    s.add(l.order);
    seen.set(k, s);
  }
  for (const [k, s] of seen) by.get(k)!.orders = s.size;
  return [...by.values()];
}

/**
 * The comparison period laid against this one bucket for bucket.
 *
 * Positional: bucket 1 of last year's range against bucket 1 of this one. A
 * comparison range can straddle one more or one fewer week than the current
 * one; the surplus is dropped rather than squeezed in.
 */
export function alignedSeries(
  lines: SaleLine[],
  range: Range,
  grain: Grain,
  count: number,
): SeriesPoint[] {
  return series(lines, bucketsBetween(range, grain), grain).slice(0, count);
}

/** Least-squares slope per bucket, as a fraction of the mean. 0.05 = rising 5% a bucket. */
export function trendSlope(values: number[]): number {
  const n = values.length;
  if (n < 2) return 0;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  if (!(mean > 0)) return 0;
  const xMean = (n - 1) / 2;
  let num = 0;
  let den = 0;
  values.forEach((y, x) => {
    num += (x - xMean) * (y - mean);
    den += (x - xMean) ** 2;
  });
  return num / den / mean;
}

// --------------------------------------------------------------- rollups ---

export interface RepRow extends Totals {
  rep: string;
  previous?: Totals;
  share: number;
  outstanding: number;
  overdue90: number;
  spark: number[];
}

export function byRep(
  reps: string[],
  lines: SaleLine[],
  previous: SaleLine[] | undefined,
  outstanding: OutstandingPoint[],
  buckets: Bucket[],
  grain: Grain,
  measure: Measure,
): RepRow[] {
  const whole = measureOf(totals(lines), measure);
  const latest = latestOutstanding(outstanding);
  return reps.map((rep) => {
    const mine = lines.filter((l) => l.rep === rep);
    const t = totals(mine);
    const owed = latest.filter((o) => o.rep === rep);
    return {
      rep,
      ...t,
      previous: previous ? totals(previous.filter((l) => l.rep === rep)) : undefined,
      share: whole > 0 ? measureOf(t, measure) / whole : 0,
      outstanding: owed.reduce((s, o) => s + o.total, 0),
      overdue90: owed.reduce((s, o) => s + o.d90, 0),
      spark: series(mine, buckets, grain).map((p) => measureOf(p, measure)),
    };
  });
}

export type CustomerFlag = 'new' | 'lost' | 'dormant' | 'falling' | 'rising';

export interface CustomerRow extends Totals {
  customer: string;
  customerName: string;
  rep: string;
  previous: Totals;
  lastOrder?: string;
  daysSinceLast?: number;
  outstanding?: OutstandingPoint;
  spark: number[];
  flags: CustomerFlag[];
}

/**
 * One row per customer seen in either period.
 *
 * A customer who bought last period and not this one is the most important row
 * on the page — that is a lost account — so the previous period is folded in
 * rather than only used for a percentage.
 */
export function byCustomer(
  lines: SaleLine[],
  previous: SaleLine[],
  outstanding: OutstandingPoint[],
  buckets: Bucket[],
  grain: Grain,
  measure: Measure,
  asOf: string,
  dormantDays = 45,
): CustomerRow[] {
  const latest = new Map(latestOutstanding(outstanding).map((o) => [o.customer, o]));
  const ids = new Map<string, { name: string; rep: string }>();
  for (const l of [...previous, ...lines]) ids.set(l.customer, { name: l.customerName, rep: l.rep });

  return [...ids].map(([customer, meta]) => {
    const mine = lines.filter((l) => l.customer === customer);
    const before = previous.filter((l) => l.customer === customer);
    const t = totals(mine);
    const p = totals(before);
    const lastOrder = mine.reduce<string | undefined>((m, l) => (!m || l.date > m ? l.date : m), undefined);
    const daysSinceLast = lastOrder ? daysBetween(lastOrder, asOf) : undefined;
    const spark = series(mine, buckets, grain).map((s) => measureOf(s, measure));

    const flags: CustomerFlag[] = [];
    const cur = measureOf(t, measure);
    const prev = measureOf(p, measure);
    if (cur > 0 && prev === 0 && previous.length) flags.push('new');
    if (cur === 0 && prev > 0) flags.push('lost');
    if (cur > 0 && daysSinceLast !== undefined && daysSinceLast > dormantDays) flags.push('dormant');
    const ch = change(cur, prev);
    if (ch !== null && ch <= -0.2 && cur > 0) flags.push('falling');
    if (ch !== null && ch >= 0.2) flags.push('rising');

    return {
      customer,
      customerName: meta.name,
      rep: meta.rep,
      ...t,
      previous: p,
      lastOrder,
      daysSinceLast,
      outstanding: latest.get(customer),
      spark,
      flags,
    };
  });
}

export interface GroupRow {
  group: string;
  amount: number;
  kg: number;
  perKg: number;
  share: number;
}

export function byGroup(lines: SaleLine[], measure: Measure): GroupRow[] {
  const by = new Map<string, { amount: number; kg: number }>();
  for (const l of lines) {
    const g = by.get(l.group) ?? { amount: 0, kg: 0 };
    g.amount += l.amount;
    g.kg += l.kg;
    by.set(l.group, g);
  }
  const whole = [...by.values()].reduce((s, g) => s + measureOf(g, measure), 0);
  return [...by]
    .map(([group, g]) => ({
      group,
      ...g,
      perKg: g.kg > 0 ? g.amount / g.kg : 0,
      share: whole > 0 ? measureOf(g, measure) / whole : 0,
    }))
    .sort((a, b) => measureOf(b, measure) - measureOf(a, measure));
}

// ----------------------------------------------------------- outstanding ---

/** Each customer's most recent snapshot. */
export function latestOutstanding(points: OutstandingPoint[]): OutstandingPoint[] {
  const by = new Map<string, OutstandingPoint>();
  for (const p of points) {
    const had = by.get(p.customer);
    if (!had || p.date > had.date) by.set(p.customer, p);
  }
  return [...by.values()];
}

export interface OutstandingBucket extends Bucket {
  total: number;
  d0_30: number;
  d30_60: number;
  d60_90: number;
  d90: number;
}

/**
 * Outstanding at the END of each bucket: per customer, the last snapshot on or
 * before the bucket's end, summed. A balance is a level, not a flow — adding
 * up every snapshot in a month would count the same debt thirty times.
 */
export function outstandingSeries(points: OutstandingPoint[], buckets: Bucket[]): OutstandingBucket[] {
  const sorted = [...points].sort((a, b) => a.date.localeCompare(b.date));
  return buckets.map((b) => {
    const at = new Map<string, OutstandingPoint>();
    for (const p of sorted) {
      if (p.date > b.end) break;
      at.set(p.customer, p);
    }
    const sum = (k: keyof Pick<OutstandingPoint, 'total' | 'd0_30' | 'd30_60' | 'd60_90' | 'd90'>) =>
      [...at.values()].reduce((s, p) => s + p[k], 0);
    return {
      ...b,
      total: sum('total'),
      d0_30: sum('d0_30'),
      d30_60: sum('d30_60'),
      d60_90: sum('d60_90'),
      d90: sum('d90'),
    };
  });
}

/**
 * Days of sales outstanding: what is owed now, against average daily sales
 * over the range. "This rep's customers owe 52 days of what they buy."
 */
export function dso(outstanding: number, salesAmount: number, range: Range): number {
  const days = daysBetween(range.from, range.to) + 1;
  const perDay = salesAmount / days;
  return perDay > 0 ? outstanding / perDay : 0;
}

// ---------------------------------------------------------------- presets ---

export type Preset = '4w' | '12w' | '26w' | '3m' | '6m' | '12m' | 'fy' | 'ytd' | 'custom';

/**
 * A preset ending today. The Indian financial year starts 1 April, which is
 * what "FY" means to anybody reading this screen.
 */
export function presetRange(preset: Exclude<Preset, 'custom'>, today: string): Range {
  const d = fromIso(today);
  const weeksBack = (n: number) => isoDate(addDays(mondayOf(d), -7 * (n - 1)));
  const monthsBack = (n: number) => isoDate(new Date(d.getFullYear(), d.getMonth() - (n - 1), 1));
  switch (preset) {
    case '4w':
      return { from: weeksBack(4), to: today };
    case '12w':
      return { from: weeksBack(12), to: today };
    case '26w':
      return { from: weeksBack(26), to: today };
    case '3m':
      return { from: monthsBack(3), to: today };
    case '6m':
      return { from: monthsBack(6), to: today };
    case '12m':
      return { from: monthsBack(12), to: today };
    case 'ytd':
      return { from: `${d.getFullYear()}-01-01`, to: today };
    case 'fy': {
      const y = d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1;
      return { from: `${y}-04-01`, to: today };
    }
  }
}
