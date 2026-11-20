/**
 * Vulcanizing solution on an order line: counted and priced by the can, held
 * in SAP in litres.
 *
 * `custom_total_weight` is a line's quantity in SAP's unit — kilos for tread
 * rubber and gum, **litres for solution** (cans × tin size). The dashboard has
 * written litres on a line it edits since `orderLineValues`; the phone wrote 0
 * until 20 Nov 2026, so the order sync refused every solution order it took
 * (SAL-ORD-2026-00162, 6 × 30 L). Now both write the litres.
 *
 * That makes three places that read the field as kilos wrong for solution,
 * which is what this file is for: its `custom_rate_per_kg` is a rate per CAN,
 * so the price is cans × rate, never litres × rate.
 *
 * The phone writes the category as 'Vulcanizing Solution'; imports and the
 * fixtures write 'VS'. Both are solution. The phone's `isSolutionCategory` in
 * `app/lib/core/proforma_columns.dart` reads it the same way.
 */

export function isSolutionCategory(category: unknown): boolean {
  const t = String(category ?? '').trim().toLowerCase();
  return t === 'vs' || t.includes('solution') || t.includes('vulcan');
}

/** The unit a line's `custom_total_weight` is in: litres for solution, else kg. */
export function weightUnit(category: unknown): 'L' | 'kg' {
  return isSolutionCategory(category) ? 'L' : 'kg';
}

/**
 * ERPNext's per-unit `rate` for a line priced at `ratePerKg`.
 *
 * Tread rubber is counted in rolls and priced by the kilogram, so its unit
 * rate is `ratePerKg × weight / qty` — what keeps `qty × rate` equal to
 * `weight × ratePerKg`. Solution's "per kg" rate is already per can and its
 * qty is cans, so the rate is the rate: with the litres in the weight, the
 * tread formula would make 6 cans at 5,130 cost 5,130 × 180 / 6 = 153,900
 * each. A line with no quantity or weight falls back to `fallback`, the rate
 * as stored.
 */
export function unitRateFor(line: {
  category?: unknown;
  qty: number;
  weight: number;
  ratePerKg: number;
  fallback: number;
}): number {
  if (isSolutionCategory(line.category)) return line.ratePerKg > 0 ? line.ratePerKg : line.fallback;
  return line.qty > 0 && line.weight > 0 ? (line.ratePerKg * line.weight) / line.qty : line.fallback;
}

/** What a line comes to at `rate` per kg — or, for solution, per can. */
export function lineAmountAt(
  line: { category?: unknown; qty: number; totalWeight: number },
  rate: number,
): number {
  return (isSolutionCategory(line.category) ? line.qty : line.totalWeight) * rate;
}
