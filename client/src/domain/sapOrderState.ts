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
import { PO_STATUS, statusPill, type StatusTone } from './orderStatus';

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

/** What SAP has told us about one LINE of an order. */
export interface SapLineState {
  productionOrder?: string | null;
  productionStage?: string | null;
  /** The delivery that carried THIS line. Blank means this line has not gone. */
  deliveryOrder?: string | null;
  deliveryDate?: string | null;
}

/**
 * One line's status.
 *
 * SAP raises a production order per item, so a four-item order has four
 * stages and an order-level stage hides which item is holding it up.
 *
 * THE DELIVERY IS THE LINE'S OWN, NOT THE ORDER'S
 *
 * A delivery need not carry the whole order: dropping a row from it is how the
 * floor ships what is ready and leaves the rest open, which is exactly what
 * happened to SAP order 381 on 16 Sep 2026 — three lines shipped, one stayed
 * open. Reading the order's delivery here would mark that fourth line
 * Dispatched while it sat unmade in the factory, which is the same lie as
 * calling an unmapped stage Ready.
 *
 * Everything else defers to `productionStatusFromSap`, so a line and an order
 * can never drift apart on the rules they share.
 */
export function lineStatusFromSap(line: SapLineState): ProductionStatus {
  return productionStatusFromSap({
    productionStage: line.productionStage,
    deliveryOrder: line.deliveryOrder,
  });
}

const RANK: Record<ProductionStatus, number> = {
  'Not Started': 0,
  'In Production': 1,
  Ready: 2,
  Dispatched: 3,
};

/**
 * The order's status, rolled up from its lines: the least advanced one wins.
 *
 * An order is Ready only when every line is. Rounding the other way would tell
 * a rep an order is made while one item is still in a press — the same error
 * `unknown_stage_is_in_production` exists to prevent.
 *
 * With no lines carrying SAP state at all, falls back to the order's own.
 */
export function orderStatusFromLines(lines: SapLineState[], order: SapOrderState): ProductionStatus {
  const known = lines.filter(
    (l) => clean(l.productionOrder) || clean(l.productionStage) || clean(l.deliveryOrder),
  );
  if (known.length === 0) return productionStatusFromSap(order);
  // Not short-circuited on the order's delivery: a partly-delivered order is
  // still open, and saying Dispatched would close it in a rep's mind while a
  // line is outstanding. It reaches Dispatched here only when every line has.
  return known
    .map(lineStatusFromSap)
    .reduce((worst, s) => (RANK[s] < RANK[worst] ? s : worst));
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

// ------------------------------------------------------------ cancelled ---

/** SAP's own enum value. Not free text, and the only one mapped to behaviour. */
const SAP_CANCELLED = 'bost_cancelled';

/**
 * Whether SAP has cancelled this order.
 *
 * `custom_sap_sales_order_status` is otherwise **shown verbatim, never
 * parsed** — the rest of SAP's vocabulary belongs to SAP and must change
 * without an app release. This is the single exception, and it earns it: a
 * cancelled order is not a shade of progress, it is the order not happening,
 * and an app that goes on calling it Approved is telling a manager to expect
 * goods nobody is making.
 *
 * `bost_Cancelled` is a SAP enum, not a stage name, so it is stable in a way
 * the stage list deliberately is not. The sync folds SAP's separate
 * `Cancelled = tYES` flag into the same value — see `Resolve-SoStatus` — so
 * this one check covers both ways SAP says it.
 *
 * Found on 18 September 2026: SAP order 399 (DocEntry 2884) had been cancelled
 * and ERPNext had recorded it correctly for days. Nothing read it, so the
 * sales manager's board still showed the order approved.
 */
export function cancelledInSap(s: SapOrderState): boolean {
  return clean(s.salesOrderStatus).toLowerCase() === SAP_CANCELLED;
}

/**
 * The pill an order shows, once SAP has had its say.
 *
 * One function rather than the same two-line check on four screens, which is
 * how the two apps drift. Cancellation outranks the approval status because it
 * is the later fact and the terminal one — the same reasoning that puts a
 * delivery above a stage in `productionStatusFromSap`.
 */
export function orderPill(
  poStatus: string | undefined | null,
  sap: SapOrderState,
): { text: string; tone: StatusTone } {
  if (cancelledInSap(sap)) return { text: 'CANCELLED IN SAP', tone: 'danger' };
  return statusPill(poStatus);
}

/** The four states a manager sorts their team's orders into. */
export type OrderBucket = 'to_approve' | 'approved' | 'rejected' | 'cancelled';

export const ORDER_BUCKET_LABEL: Record<OrderBucket, string> = {
  to_approve: 'To approve',
  approved: 'Approved',
  rejected: 'Rejected',
  cancelled: 'Cancelled in SAP',
};

/** Filter order: what a manager owes a decision on first, terminal states last. */
export const ORDER_BUCKETS: OrderBucket[] = ['to_approve', 'approved', 'rejected', 'cancelled'];

/**
 * Which bucket an order falls in, for filtering a manager's list.
 *
 * **The precedence is `orderPill`'s, deliberately.** Filter on Approved and
 * every row must show APPROVED; a cancelled order still carries
 * `custom_po_status = "PO Approved - Ready for SAP"`, so testing the approval
 * status first would file it under Approved while its own pill read CANCELLED
 * IN SAP. Two answers to the same question on one screen.
 *
 * `approved` is passed in rather than derived because the two doctypes do not
 * agree on what approved means: a Sales Order has the single
 * `PO Approved - Ready for SAP`, while a Lead Order also counts `Approved` and
 * `Converted` (see `leadOrderApproved`). The caller already knows which it is
 * holding.
 *
 * Note `to_approve` is NOT `awaitingManager`. That predicate counts rejected
 * as still owing a decision — correct for the header count, since the rep will
 * resubmit — but a manager filtering "To approve" wants the ones they can act
 * on now, and Rejected is its own bucket here.
 */
export function orderBucket(input: {
  approved: boolean;
  poStatus?: string | null;
  salesOrderStatus?: string | null;
}): OrderBucket {
  if (cancelledInSap({ salesOrderStatus: input.salesOrderStatus })) return 'cancelled';
  // Both doctypes spell rejection the same way: PO_STATUS.rejected and
  // LEAD_ORDER_STATUS.rejected are both the string 'Rejected'.
  if (clean(input.poStatus) === PO_STATUS.rejected) return 'rejected';
  if (input.approved) return 'approved';
  return 'to_approve';
}
