/**
 * Invented history for the analysis screen — a SAMPLE, so the layout can be
 * judged before the real source exists.
 *
 * Why invented: as of 11 Oct 2026 ERPNext holds 12 Sales Orders (nearly all
 * tests) and no invoices, and keeps only today's outstanding per customer, so
 * there is no real history to draw. The selling history is in SAP.
 *
 * The reps and customers are the manager's real ones where the site gives
 * them, so the sample reads like their own team; every figure is made up. The
 * page says so in a banner that cannot be dismissed. Replace this module with
 * a real loader and the screen needs no other change — it only reads
 * `SaleLine[]` and `OutstandingPoint[]`.
 *
 * Seeded, so the same team draws the same history on every reload; a sample
 * that reshuffles itself makes "what should change" impossible to discuss.
 */

import type { OutstandingPoint, SaleLine } from '@/domain/repAnalysis';
import { addDays, fromIso, isoDate } from '@/domain/weeks';

export interface SampleCustomer {
  id: string;
  name: string;
  rep: string;
}

export interface SampleData {
  lines: SaleLine[];
  outstanding: OutstandingPoint[];
  /** Earliest date the sample covers. */
  from: string;
}

/** Product family and a plausible ₹/kg, before tax. Invented. */
const GROUPS: Array<[string, number]> = [
  ['FG - TRP - Black Pearl', 238],
  ['FG - TRP - Diamond', 292],
  ['FG - TRP - Platinum', 274],
  ['FG - TRP - Polygold', 259],
  ['FG - TRP - Silver', 221],
  ['Cushion Gum', 318],
];

const PLACES = [
  'Tyres', 'Retreads', 'Tyre Works', 'Rubber Works', 'Treads', 'Auto Tyres', 'Tyre House', 'Retreading Co',
];
const TOWNS = [
  'Kozhikode', 'Thrissur', 'Palakkad', 'Malappuram', 'Kannur', 'Vadakara', 'Perinthalmanna', 'Manjeri',
  'Tirur', 'Ottapalam', 'Kasaragod', 'Wayanad', 'Ernakulam', 'Aluva', 'Kottayam', 'Pala',
];

/** mulberry32 — small, fast, and the same everywhere. */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return h >>> 0;
}

/** Invented customers for a rep the site gave none for. */
function inventCustomers(rep: string, n: number): SampleCustomer[] {
  const r = rng(hash(rep));
  return Array.from({ length: n }, (_, i) => {
    const town = TOWNS[Math.floor(r() * TOWNS.length)];
    const kind = PLACES[Math.floor(r() * PLACES.length)];
    return { id: `SAMPLE-${rep}-${i}`, name: `${town} ${kind}`, rep };
  });
}

/**
 * Tread rubber sells less in the monsoon (Jun–Aug) and picks up before Onam
 * and the year end. A rough shape, enough that a month chart is not flat.
 */
function season(month: number): number {
  return [1.05, 1.0, 1.1, 1.0, 0.95, 0.8, 0.72, 0.8, 1.1, 1.05, 1.0, 1.15][month];
}

export function buildSample(
  reps: string[],
  realCustomers: SampleCustomer[],
  today: string,
  months = 24,
): SampleData {
  const end = fromIso(today);
  const start = new Date(end.getFullYear(), end.getMonth() - months, 1);
  const lines: SaleLine[] = [];
  const outstanding: OutstandingPoint[] = [];
  let orderNo = 1;

  for (const rep of reps) {
    const own = realCustomers.filter((c) => c.rep === rep).slice(0, 30);
    const customers = own.length >= 6 ? own : [...own, ...inventCustomers(rep, 14 - own.length)];
    const repRand = rng(hash(`rep:${rep}`));
    // Each rep has a direction of travel, so the comparison shows something.
    const repTrend = -0.25 + repRand() * 0.7;

    for (const c of customers) {
      const r = rng(hash(`${rep}|${c.id}`));
      const monthlyKg = 150 + r() ** 2 * 2600;
      const everyDays = 7 + Math.floor(r() * 28);
      const trend = repTrend + (r() - 0.5) * 0.6;
      const preferred = GROUPS.filter(() => r() < 0.45);
      const mix = preferred.length ? preferred : [GROUPS[0]];
      // Some accounts open late, some go quiet — the rows a manager hunts for.
      const opensAt = r() < 0.15 ? addDays(start, Math.floor(r() * months * 25)) : start;
      const closesAt = r() < 0.12 ? addDays(end, -Math.floor(15 + r() * 200)) : end;
      const payDays = 20 + r() * 70;
      const totalDays = (end.getTime() - start.getTime()) / 86_400_000;

      // Daily ledger for the outstanding: what was sold, less what was paid.
      const invoices: Array<{ day: Date; amount: number; paid: Date }> = [];

      for (let d = addDays(opensAt, Math.floor(r() * everyDays)); d <= closesAt; d = addDays(d, everyDays + Math.floor((r() - 0.5) * 6))) {
        const elapsed = (d.getTime() - start.getTime()) / 86_400_000 / totalDays;
        const kgTarget = (monthlyKg * everyDays) / 30 * season(d.getMonth()) * (1 + trend * (elapsed - 0.5));
        const order = `SAMPLE-${String(orderNo++).padStart(5, '0')}`;
        const lineCount = 1 + Math.floor(r() * Math.min(3, mix.length));
        let orderAmount = 0;
        for (let i = 0; i < lineCount; i++) {
          const [group, perKg] = mix[Math.floor(r() * mix.length)];
          const kg = Math.max(20, Math.round((kgTarget / lineCount) * (0.6 + r() * 0.8)));
          const amount = Math.round(kg * perKg * (0.96 + r() * 0.08));
          orderAmount += amount;
          lines.push({ date: isoDate(d), rep, customer: c.id, customerName: c.name, group, amount, kg, order });
        }
        // Most pay on their terms; some pay late; a few drag on for months.
        const late = r() < 0.1 ? 40 + r() * 80 : r() < 0.03 ? 120 + r() * 150 : 0;
        const paid = addDays(d, Math.round(payDays * (0.6 + r() * 0.8) + late));
        invoices.push({ day: d, amount: orderAmount * 1.18, paid });
      }

      // Weekly snapshots, as a nightly sync would leave if it kept history.
      for (let s = addDays(start, 6); s <= end; s = addDays(s, 7)) {
        let total = 0;
        const age = [0, 0, 0, 0];
        for (const inv of invoices) {
          if (inv.day > s || inv.paid <= s) continue;
          total += inv.amount;
          const days = (s.getTime() - inv.day.getTime()) / 86_400_000;
          age[days <= 30 ? 0 : days <= 60 ? 1 : days <= 90 ? 2 : 3] += inv.amount;
        }
        outstanding.push({
          date: isoDate(s),
          rep,
          customer: c.id,
          total: Math.round(total),
          d0_30: Math.round(age[0]),
          d30_60: Math.round(age[1]),
          d60_90: Math.round(age[2]),
          d90: Math.round(age[3]),
        });
      }
    }
  }

  return { lines, outstanding, from: isoDate(start) };
}
