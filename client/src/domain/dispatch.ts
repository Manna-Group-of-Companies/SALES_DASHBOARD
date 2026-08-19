/**
 * How much of an order line remains to be dispatched.
 *
 * Paired with `app/lib/core/dispatch.dart`. Both read
 * `shared/fixtures/dispatch.json` in their tests. See `shared/README.md`.
 *
 * `custom_dispatched_rolls`/`custom_dispatched_loose_belts` are cumulative
 * across every `Manna Dispatch` that has ever touched this line — never one
 * dispatch's own amount. A line only reaches fully-dispatched once the
 * running total catches up with what was ordered, however many rounds that
 * takes.
 */

/** A Sales Order Item, as ERPNext returns it. Only these four fields matter here. */
type Row = Record<string, unknown>;

/** Frappe returns an unset Int as null, '' or the string 'null'. */
function num(v: unknown): number {
  if (v == null) return 0;
  const s = typeof v === 'string' ? v.trim() : v;
  if (s === '' || s === 'null' || s === 'undefined') return 0;
  const n = Number(s);
  return Number.isFinite(n) ? n : 0;
}

export interface RemainingQty {
  rolls: number;
  looseBelts: number;
}

/**
 * What is left of this line for a dispatch to carry.
 *
 * Clamped at zero, never negative — an over-dispatched line (a data mistake:
 * cumulative recorded greater than ordered) reads as nothing remaining rather
 * than a negative number a picker would have to guard against separately.
 * This is the opposite rounding direction from `production.ts`'s "errors
 * round down": under-reporting what has already left the building is the
 * more dangerous failure here, so this rounds the other way on purpose.
 */
export function remainingToDispatch(line: Row): RemainingQty {
  const rolls = num(line.custom_rolls) - num(line.custom_dispatched_rolls);
  const looseBelts = num(line.custom_loose_belts) - num(line.custom_dispatched_loose_belts);
  return { rolls: rolls < 0 ? 0 : rolls, looseBelts: looseBelts < 0 ? 0 : looseBelts };
}

/** True once both counters have nothing left — rolls and belts do not average out. */
export function isFullyDispatched(line: Row): boolean {
  const left = remainingToDispatch(line);
  return left.rolls <= 0 && left.looseBelts <= 0;
}
