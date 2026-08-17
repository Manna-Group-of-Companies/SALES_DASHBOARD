/**
 * What each proforma line puts in each column.
 *
 * **Paired with `app/lib/core/proforma_columns.dart`.** The phone renders a PDF
 * and the dashboard renders HTML, but to a customer they are the same document,
 * so both read `shared/fixtures/proforma_columns.json` in their tests.
 *
 * The columns are:
 *
 *     #  Description  Rolls  Belts  Cans  Qty  MRP  Amount
 *
 * **Rolls, belts and cans are columns, not a second line under the name.** They
 * are quantities; printing them as prose under the description meant a customer
 * checking a delivery had to read a sentence to find a number.
 *
 * **Every row must multiply out against a column the customer can see.** Tread
 * rubber and gum are billed by weight, so `Qty(kg) x MRP = Amount`. Solution is
 * billed by the can, so `Cans x MRP = Amount` — which is why MRP carries its
 * unit underneath rather than being assumed to be per kilogram.
 *
 * That last point fixed a real fault: the PDF printed solution as qty `90`
 * against a rate of `195` with an amount of `585`, three numbers that do not
 * reconcile, because it assumed `custom_rate_per_kg` was per kilogram on every
 * line. On solution it is per can.
 */

import type { ProductCategory } from './types';

/** A line as ERPNext returns it. */
export type ProformaRow = Record<string, unknown>;

export const PROFORMA_FIELD = {
  category: 'custom_product_category',
  rolls: 'custom_rolls',
  belts: 'custom_loose_belts',
  weight: 'custom_total_weight',
  ratePerKg: 'custom_rate_per_kg',
} as const;

function num(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(String(v ?? '').trim());
  return Number.isFinite(n) ? n : 0;
}

/** A count for a packing column. Zero prints as nothing, never as "0". */
function count(v: unknown): string {
  const n = num(v);
  return n > 0 ? String(n) : '';
}

const tidy = (n: number) => String(Number(n.toFixed(3)));

export interface ProformaCells {
  rolls: string;
  belts: string;
  cans: string;
  /** The billed quantity with its unit, e.g. "56.4 kg" or "90 L". */
  qty: string;
  mrp: number;
  /** Printed under the MRP so the row can be checked. */
  mrpUnit: string;
  amount: number;
}

/**
 * The cells for one line.
 *
 * A zero never prints in a packing column. An empty cell reads as "not
 * applicable"; a `0` reads as "none supplied", and on a packing column those
 * are different claims — hot rubber is not cut into belts at all, which is not
 * the same as a roll that yielded none.
 */
export function proformaCells(line: ProformaRow): ProformaCells {
  const category = String(line[PROFORMA_FIELD.category] ?? '') as ProductCategory;
  const weight = num(line[PROFORMA_FIELD.weight]);
  const perKg = num(line[PROFORMA_FIELD.ratePerKg]);
  const qty = num(line.qty);
  const rate = num(line.rate);
  const amount = num(line.amount);

  // Solution is counted and billed by the can. The tin size — 10 L or 30 L —
  // is already in the item name, so the column carries the COUNT.
  //
  // `qty` is the can count, not `custom_cans`: on the live orders those two
  // disagree (qty 3 against custom_cans 2 on SAL-ORD-2026-00129) and `qty` is
  // the one the amount was computed from.
  if (category === 'VS') {
    return {
      rolls: '',
      belts: '',
      cans: count(qty),
      qty: weight > 0 ? `${tidy(weight)} L` : '',
      mrp: rate,
      mrpUnit: 'per can',
      amount,
    };
  }

  // Everything else is billed by weight when a per-kilogram rate exists. An
  // order raised before that field did falls back to the stored qty and rate,
  // so an old proforma still reprints correctly rather than showing a nil line.
  const byWeight = perKg > 0 && weight > 0;

  return {
    // Gum has no packing count at all — it is sold by the kilogram.
    rolls: category === 'BG' ? '' : count(line[PROFORMA_FIELD.rolls]),
    // Only precured is cut into belts.
    belts: category === 'PCTR' ? count(line[PROFORMA_FIELD.belts]) : '',
    cans: '',
    qty: byWeight ? `${tidy(weight)} kg` : tidy(qty),
    mrp: byWeight ? perKg : rate,
    mrpUnit: byWeight ? 'per kg' : '',
    amount,
  };
}

/**
 * The column the row multiplies out on, for the test that proves it does.
 *
 * Not rendered. It exists so "every row reconciles" is a thing a test can
 * assert rather than a claim in a comment.
 */
export function reconcilesOn(line: ProformaRow): 'cans' | 'weight' | 'qty' {
  const category = String(line[PROFORMA_FIELD.category] ?? '');
  if (category === 'VS') return 'cans';
  return num(line[PROFORMA_FIELD.ratePerKg]) > 0 && num(line[PROFORMA_FIELD.weight]) > 0
    ? 'weight'
    : 'qty';
}
