/**
 * What SAP says about an order, and what the apps do with it.
 *
 * An approved order becomes a SAP Sales Order, and an A/R invoice raised
 * against it is what says it has gone. The apps report those two facts and
 * nothing in between:
 *
 *     Not Started  ->  Pushed to SAP  ->  Dispatched
 *     (no SAP no.)     (SAP has it)       (invoiced)
 *
 * WHY THERE IS NO PRODUCTION STAGE
 *
 * Decided 24 September 2026 for the initial release. Under MRP one production
 * order pools the demand of many sales orders, and SAP does not record which
 * order a pooled production order is for — MRP-created orders carry no
 * sales-order link at all, and the link table has no quantity column. Any
 * per-order stage would be an allocation guess dressed up as a fact, so the
 * release reports only what SAP records. `custom_sap_production_order` and
 * `custom_sap_production_stage` still exist in ERPNext and may hold old
 * values; nothing here reads them.
 *
 * WHY A DELIVERY IS NOT DISPATCH
 *
 * The floor posts a delivery before it invoices. Dispatch is the invoice, so a
 * delivered-but-uninvoiced order still reads Pushed to SAP. Also decided
 * 24 September 2026.
 *
 * The function names are older than this rule — `productionStatusFromSap`
 * predates the removal of stages — and are kept so their callers did not have
 * to change.
 *
 * Pinned by `shared/fixtures/sap_order_state.json`; the Dart twin is
 * `app/lib/core/sap_order_state.dart`.
 */
import { PO_STATUS, statusPill, type StatusTone } from './orderStatus';

export type ProductionStatus = 'Not Started' | 'Pushed to SAP' | 'Dispatched';

/** What SAP has told us about one order. All of it optional; none is ours. */
export interface SapOrderState {
  salesOrder?: string | null;
  salesOrderStatus?: string | null;
  /**
   * The invoice that completed the order. The sync writes it only once every
   * line has been invoiced, so a partly-invoiced order leaves it blank.
   */
  invoice?: string | null;
  invoiceDate?: string | null;
  syncedAt?: string | null;
  syncError?: string | null;
}

const clean = (v: string | null | undefined): string => {
  const s = (v ?? '').trim();
  // Frappe reads an unset Link back as the string 'null' when it was written
  // by naive interpolation, and that would print literally.
  return s === 'null' ? '' : s;
};

/** Whether SAP has taken the order at all. */
export function reachedSap(s: SapOrderState): boolean {
  return clean(s.salesOrder).length > 0;
}

/**
 * The order's status from its own fields.
 *
 * The invoice is checked first because it is the later fact: an order with an
 * invoice has gone, whatever else is or is not filled in.
 */
export function productionStatusFromSap(s: SapOrderState): ProductionStatus {
  if (clean(s.invoice)) return 'Dispatched';
  if (reachedSap(s)) return 'Pushed to SAP';
  return 'Not Started';
}

/**
 * What an order LIST shows as the order's progress.
 *
 * SAP's status once SAP has the order (or an invoice exists); before that the
 * stored in-app `custom_production_status`, which is what every order placed
 * before the floor moved to SAP carries. Never a mix: an in-app Dispatched on
 * an order SAP has not invoiced is not dispatch. An order is complete exactly
 * when this reads 'Dispatched'.
 *
 * Fixture: `order_progress`. The Dart twin is `orderProgress`.
 */
export function orderProgress(s: SapOrderState, storedProductionStatus?: string | null): string {
  if (reachedSap(s) || clean(s.invoice)) return productionStatusFromSap(s);
  return clean(storedProductionStatus) || 'Not Started';
}

/** What SAP has told us about one LINE of an order. */
export interface SapLineState {
  /** The invoice that carried THIS line. Blank means this line has not gone. */
  invoice?: string | null;
  invoiceDate?: string | null;
}

/** Whether SAP has said anything about this line of its own. */
export function lineHasSap(line: SapLineState): boolean {
  return clean(line.invoice).length > 0;
}

/**
 * One line's status.
 *
 * THE INVOICE IS THE LINE'S OWN, NOT THE ORDER'S
 *
 * An order can be invoiced in parts, so a line is Dispatched only when THAT
 * line was invoiced. A line has no SAP number of its own, though: it is Pushed
 * to SAP when its `order` is, which is why the order is passed in.
 */
export function lineStatusFromSap(line: SapLineState, order?: SapOrderState): ProductionStatus {
  if (lineHasSap(line)) return 'Dispatched';
  if (order && reachedSap(order)) return 'Pushed to SAP';
  return 'Not Started';
}

const RANK: Record<ProductionStatus, number> = {
  'Not Started': 0,
  'Pushed to SAP': 1,
  Dispatched: 2,
};

/**
 * The order's status, rolled up from its lines: the least advanced one wins.
 *
 * An order is Dispatched only when every line has been invoiced. A
 * partly-invoiced order is still open, and calling it Dispatched would close
 * it in a rep's mind while an item is outstanding.
 *
 * With no lines at all, falls back to the order's own fields.
 */
export function orderStatusFromLines(lines: SapLineState[], order: SapOrderState): ProductionStatus {
  if (lines.length === 0) return productionStatusFromSap(order);
  return lines
    .map((l) => lineStatusFromSap(l, order))
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
 * One line a rep can read: which invoice, when, and the SAP order number.
 *
 * Returns null when there is nothing worth saying, so a caller renders nothing
 * rather than an empty row.
 */
export function sapSummary(s: SapOrderState): string | null {
  const bits: string[] = [];
  const invoice = clean(s.invoice);
  const date = clean(s.invoiceDate);
  if (invoice) {
    bits.push(`Invoice ${invoice}`);
    if (date) bits.push(date);
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
 * `bost_Cancelled` is a SAP enum, so it is stable. The sync folds SAP's
 * separate `Cancelled = tYES` flag into the same value — see
 * `Resolve-SoStatus` — so this one check covers both ways SAP says it.
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
 * is the later fact and the terminal one.
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
