/**
 * Totals for the GM's Product Sales report: per product and per day.
 * Pure, so the report's ranking and best/slowest picks are tested.
 */
import type { SoldLine } from '@/api/productSales';

export type Measure = 'amount' | 'kg';

export interface ProductTotal {
  itemCode: string;
  itemName: string;
  amount: number;
  kg: number;
  rolls: number;
  /** Distinct orders it was on. */
  orders: number;
  /** Distinct reps who sold it. */
  reps: number;
}

export interface DayTotal {
  date: string;
  amount: number;
  kg: number;
  orders: number;
}

/** Products sold, best first by `measure`; ties by name. */
export function byProduct(lines: SoldLine[], measure: Measure): ProductTotal[] {
  const by = new Map<string, ProductTotal & { _o: Set<string>; _r: Set<string> }>();
  for (const l of lines) {
    let p = by.get(l.itemCode);
    if (!p) {
      p = { itemCode: l.itemCode, itemName: l.itemName, amount: 0, kg: 0, rolls: 0, orders: 0, reps: 0, _o: new Set(), _r: new Set() };
      by.set(l.itemCode, p);
    }
    p.amount += l.amount;
    p.kg += l.kg;
    p.rolls += l.rolls;
    p._o.add(l.order);
    if (l.rep) p._r.add(l.rep);
  }
  return [...by.values()]
    .map(({ _o, _r, ...p }) => ({ ...p, orders: _o.size, reps: _r.size }))
    .filter((p) => p[measure] > 0)
    .sort((a, b) => b[measure] - a[measure] || a.itemName.localeCompare(b.itemName));
}

/** Every day from `from` to `to` (inclusive), zero where nothing was ordered. */
export function byDay(lines: SoldLine[], from: string, to: string): DayTotal[] {
  const by = new Map<string, DayTotal & { _o: Set<string> }>();
  const d = new Date(`${from}T00:00:00`);
  const end = new Date(`${to}T00:00:00`);
  const iso = (x: Date) =>
    `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
  for (; d <= end; d.setDate(d.getDate() + 1)) {
    const k = iso(d);
    by.set(k, { date: k, amount: 0, kg: 0, orders: 0, _o: new Set() });
  }
  for (const l of lines) {
    const t = by.get(l.date);
    if (!t) continue;
    t.amount += l.amount;
    t.kg += l.kg;
    t._o.add(l.order);
  }
  return [...by.values()].map(({ _o, ...t }) => ({ ...t, orders: _o.size }));
}

/**
 * The best and slowest day by `measure`. Slowest is among days with orders:
 * a Sunday with none tells nobody anything. Null when no day sold anything.
 */
export function bestAndSlowest(days: DayTotal[], measure: Measure): { best: DayTotal; slowest: DayTotal } | null {
  const sold = days.filter((d) => d[measure] > 0);
  if (!sold.length) return null;
  let best = sold[0];
  let slowest = sold[0];
  for (const d of sold) {
    if (d[measure] > best[measure]) best = d;
    if (d[measure] < slowest[measure]) slowest = d;
  }
  return { best, slowest };
}

// ------------------------------------------------------------- prices ---

/**
 * A line's price as the rep quoted it: per kg where they quoted per kg
 * (`custom_rate_per_kg`, tread rubber), else per unit of the line's UOM.
 * Prices are only ever compared like with like — per kg with per kg.
 */
export interface Price {
  value: number;
  /** `kg`, or the line's UOM (`Nos`, `Can`…). */
  per: string;
}

export function priceOf(l: SoldLine): Price {
  if (l.ratePerKg > 0) return { value: l.ratePerKg, per: 'kg' };
  return { value: l.rate, per: l.uom || 'unit' };
}

export interface RepShare {
  rep: string;
  amount: number;
  kg: number;
  orders: number;
  /** Their highest price for this product, in the product's usual unit. */
  topPrice: number;
}

export interface ProductDetail {
  lines: SoldLine[];
  /** The unit most of its lines are priced in; prices in another unit are left out of the range. */
  per: string;
  highest: SoldLine | null;
  lowest: SoldLine | null;
  /** Weighted: total value over total quantity in `per`. */
  average: number;
  reps: RepShare[];
}

/** One product's sales: every line, its price range, and each rep's share. */
export function productDetail(lines: SoldLine[], itemCode: string): ProductDetail {
  const mine = lines.filter((l) => l.itemCode === itemCode).sort((a, b) => b.date.localeCompare(a.date));
  const units = new Map<string, number>();
  for (const l of mine) units.set(priceOf(l).per, (units.get(priceOf(l).per) ?? 0) + 1);
  const per = [...units.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? 'kg';
  const priced = mine.filter((l) => priceOf(l).per === per && priceOf(l).value > 0);

  let highest: SoldLine | null = null;
  let lowest: SoldLine | null = null;
  let value = 0;
  let measure = 0;
  for (const l of priced) {
    const p = priceOf(l).value;
    if (!highest || p > priceOf(highest).value) highest = l;
    if (!lowest || p < priceOf(lowest).value) lowest = l;
    const q = per === 'kg' ? l.kg : l.qty;
    value += p * q;
    measure += q;
  }

  const by = new Map<string, RepShare & { _o: Set<string> }>();
  for (const l of mine) {
    const k = l.rep || '—';
    const r = by.get(k) ?? { rep: k, amount: 0, kg: 0, orders: 0, topPrice: 0, _o: new Set<string>() };
    r.amount += l.amount;
    r.kg += l.kg;
    r._o.add(l.order);
    const p = priceOf(l);
    if (p.per === per && p.value > r.topPrice) r.topPrice = p.value;
    by.set(k, r);
  }
  const reps = [...by.values()]
    .map(({ _o, ...r }) => ({ ...r, orders: _o.size }))
    .sort((a, b) => b.amount - a.amount);

  return { lines: mine, per, highest, lowest, average: measure > 0 ? value / measure : 0, reps };
}

/**
 * The highest price anything was sold at in the period — per kg, since that is
 * how tread rubber, most of the trade, is priced. Falls back to the highest
 * per-unit price when nothing was quoted per kg.
 */
export function mostExpensiveSale(lines: SoldLine[]): SoldLine | null {
  const perKg = lines.filter((l) => l.ratePerKg > 0);
  const pool = perKg.length ? perKg : lines.filter((l) => l.rate > 0);
  let best: SoldLine | null = null;
  for (const l of pool) if (!best || priceOf(l).value > priceOf(best).value) best = l;
  return best;
}
