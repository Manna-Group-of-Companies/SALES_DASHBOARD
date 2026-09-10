/**
 * What SAP says about an order, and what the apps do with it.
 *
 * From 11 September 2026 the manufacturing floor lives in SAP. An approved
 * order becomes a SAP Sales Order; SAP links it to a production order and
 * moves it through stages; a SAP Delivery Order eventually carries several
 * orders out together. Neither app owns any of that any more — they report it.
 *
 * WHY THE STAGE IS FREE TEXT AND THE STATUS IS NOT
 *
 * The stage list belongs to the factory and has to change without an app
 * release, so `custom_sap_production_stage` is never an enum here. Screens
 * print it as SAP wrote it. This file is the only place a stage becomes
 * behaviour, mapping it onto the four values `custom_production_status` has
 * always carried — so every screen built against those keeps working.
 *
 * THE ONE THAT ROUNDS IN THE SAFE DIRECTION
 *
 * A stage nobody has mapped means the floor has started and we do not know how
 * far. That is `In Production`, never `Ready`. Calling an unknown stage Ready
 * would tell a rep an order is made when it is halfway through a press.
 *
 * Pinned by `shared/fixtures/sap_order_state.json`; the Dart twin is
 * `app/lib/core/sap_order_state.dart`.
 */

export type ProductionStatus = 'Not Started' | 'In Production' | 'Ready' | 'Dispatched';

/** What SAP has told us about one order. All of it optional; none is ours. */
export interface SapOrderState {
  salesOrder?: string | null;
  salesOrderStatus?: string | null;
  productionOrder?: string | null;
  productionStage?: string | null;
  deliveryOrder?: string | null;
  deliveryDate?: string | null;
  syncedAt?: string | null;
  syncError?: string | null;
}

const clean = (v: string | null | undefined): string => {
  const s = (v ?? '').trim();
  // Frappe reads an unset Link back as the string 'null' when it was written
  // by naive interpolation, and that would print literally.
  return s === 'null' ? '' : s;
};

/**
 * Stages that mean the floor has NOT begun.
 *
 * Deliberately short. Everything unrecognised counts as started, because the
 * error that costs money is claiming progress that has not happened — and the
 * opposite error, showing In Production for something merely queued, costs a
 * phone call.
 */
const NOT_STARTED = new Set(['', 'planned', 'open', 'not started', 'pending']);

/** Stages that mean the floor has finished with it. */
const FINISHED = new Set(['finished', 'closed', 'completed', 'ready']);

/**
 * The four-value status the screens act on.
 *
 * Order matters: delivery beats stage, because a delivery order is the later
 * fact. An order can sit at "Curing" in a stale production record and still
 * have shipped.
 */
export function productionStatusFromSap(s: SapOrderState): ProductionStatus {
  if (clean(s.deliveryOrder)) return 'Dispatched';

  const stage = clean(s.productionStage).toLowerCase();
  if (FINISHED.has(stage)) return 'Ready';
  if (NOT_STARTED.has(stage)) return 'Not Started';
  return 'In Production';
}

/** Whether SAP has taken the order at all. */
export function reachedSap(s: SapOrderState): boolean {
  return clean(s.salesOrder).length > 0;
}

/**
 * Why an order is not in SAP, or null when it is.
 *
 * "Not picked up yet" and "the push failed" look identical from the outside —
 * both are an order with no SAP number — so they are never shown the same way.
 * One is a wait; the other needs somebody.
 */
export function sapProblem(s: SapOrderState): string | null {
  const err = clean(s.syncError);
  if (err) return err;
  if (!reachedSap(s)) return null;
  return null;
}

/** True when SAP has an order but nothing has reconciled it recently. */
export function sapStale(s: SapOrderState, now: Date, hours = 24): boolean {
  if (!reachedSap(s)) return false;
  const at = clean(s.syncedAt);
  if (!at) return true;
  const t = new Date(at);
  if (Number.isNaN(t.getTime())) return true;
  return now.getTime() - t.getTime() > hours * 3600_000;
}

/**
 * One line a rep can read: where the order is and when it leaves.
 *
 * Returns null when there is nothing worth saying, so a caller renders nothing
 * rather than an empty row.
 */
export function sapSummary(s: SapOrderState): string | null {
  const bits: string[] = [];
  const stage = clean(s.productionStage);
  const delivery = clean(s.deliveryOrder);
  const date = clean(s.deliveryDate);

  if (delivery) {
    bits.push(`Delivery ${delivery}`);
    if (date) bits.push(`due ${date}`);
  } else if (stage) {
    bits.push(stage);
  }
  const so = clean(s.salesOrder);
  if (so) bits.push(`SAP ${so}`);
  return bits.length ? bits.join(' · ') : null;
}
