/**
 * Who is shown what of an item's stock.
 *
 * SAP holds finished goods in kilograms. An item carrying both UDFs —
 * belts-per-roll and weight-per-roll — converts to rolls and belts, and
 * everyone reads it that way. An item missing either cannot be converted, and
 * the question is who sees it at all.
 *
 * DECIDED 24 SEPTEMBER 2026
 *
 *   - **A sales manager sees it, in kilograms.** They are the one who can get
 *     the weights filled in, and 265 of 443 stocked items (about 34,760 kg)
 *     were in this state that day — hiding them would hide most of the shelf
 *     from the person responsible for it.
 *   - **Nobody else sees it.** A rep, the stock manager and the production
 *     manager read stock as rolls and belts only. A kilogram figure beside a
 *     roll count invites somebody to divide it in their head and promise the
 *     answer, which is the guess `stockFromKg` exists to refuse.
 *
 * Seeing an item in kilograms does not make it promisable. `shelfAvailable`
 * still reports nothing for it, so the order screens still say "Stock not set
 * up" and the split still sends the whole line to production. This is a
 * reading, not an allocation.
 *
 * The phone never shows kilograms — see `shared/DIVERGENCES.md`, 24 September.
 */

import type { MinStockLine, Role } from './types';
import { shelfAvailable } from './minimumStock';

/** How one item reads, or `null` when this viewer is not shown it. */
export type StockReading =
  | { kind: 'rolls'; rolls: number; belts: number }
  | { kind: 'weight'; qty: number; uom: string };

/** Only a sales manager is shown items the rolls cannot be worked out for. */
export function seesUnweighedStock(role: Role | undefined): boolean {
  return role === 'sales_manager';
}

export function stockReading(
  line: MinStockLine,
  role: Role | undefined,
): StockReading | null {
  if (line.weightsKnown) {
    const free = shelfAvailable(line);
    return { kind: 'rolls', rolls: free.rolls, belts: free.belts };
  }
  if (!seesUnweighedStock(role)) return null;
  const kg = Number(line.kg ?? 0);
  return {
    kind: 'weight',
    // Never negative. SAP's available-to-promise can dip below zero when more
    // is committed than is on hand, and "-12 kg" reads as a figure rather than
    // as "none".
    qty: Number.isFinite(kg) && kg > 0 ? kg : 0,
    uom: unitLabel(line.uom),
  };
}

/** Anything left to sell, in whichever unit this reading is in. */
export function hasStock(r: StockReading): boolean {
  return r.kind === 'rolls' ? r.rolls > 0 || r.belts > 0 : r.qty > 0;
}

function unitLabel(uom: string | undefined): string {
  const u = (uom ?? '').trim();
  return !u || u === 'Kg' ? 'kg' : u;
}

/** "3 rolls + 5 belts", "7 belts", "188.78 kg". */
export function describeReading(r: StockReading): string {
  if (r.kind === 'weight') {
    const n = Math.round(r.qty * 100) / 100;
    return `${n.toLocaleString('en-IN')} ${r.uom}`;
  }
  const parts: string[] = [];
  if (r.rolls > 0) parts.push(`${r.rolls} roll${r.rolls === 1 ? '' : 's'}`);
  if (r.belts > 0) parts.push(`${r.belts} belt${r.belts === 1 ? '' : 's'}`);
  return parts.join(' + ') || 'none';
}
