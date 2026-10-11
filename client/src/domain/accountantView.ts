/**
 * The accountant's view of an order at Hi-Tech (8 October 2026).
 *
 * Every approved order goes to Hi-Tech Pretreads' SAP on the inter-company
 * customer, Manna Treads (10118), so the production floor never sees the real
 * customer. The accountant has to. This decides, for one order, what the
 * accountant is shown:
 *
 *   - once Hi-Tech has issued ANY delivery against the sales order, the
 *     delivery's contents, and only those: the items and kilos that left, at
 *     the approved rate. The sales order is no longer what matters, because
 *     what was delivered is what the customer is billed for;
 *   - until then, the sales order's contents as approved.
 *
 * The delivered kilos and the delivery numbers are written onto each order
 * line by the office order sync (PASS B: `custom_hitech_delivered_kg`,
 * `custom_hitech_delivery_refs`), counting only deliveries SAP has not
 * cancelled. One order's deliveries are shown together, line by line, as the
 * sync records them.
 *
 * The kilos and rate for a delivered order are `billableLines`' — the shared
 * Manna Treads rule (`shared/fixtures/manna_treads_reorder.json`) — so what the
 * accountant sees here is exactly what that rule would bill.
 *
 * Read only. Raising the order in Manna Treads' SAP from this screen is off
 * for now (user, 8 October 2026); the sync's PASS C and the
 * `manna_mt_so_request` Server Script are left in place, unused.
 */

import { approvedRate, billableLines, roundTo, type MtLineInput } from './mannaTreadsReorder';

const SAP_CLOSED = 'bost_close';
const SAP_CANCELLED = 'bost_cancelled';

export interface AcctLineInput extends MtLineInput {
  item_name: string;
  /** ERPNext `qty` — rolls on this site, whatever the uom says. */
  rolls: number;
}

export interface AcctOrderInput {
  /** Hi-Tech's DocNum. */
  sap_sales_order: string;
  /** Hi-Tech's status, verbatim: bost_Open / bost_Close / bost_Cancelled. */
  sap_status: string;
  lines: AcctLineInput[];
  /** Delivery refs as the sync writes them, per line, e.g. "DN 6 (26-09-2026)". */
  delivery_refs: string[];
}

/**
 * - `delivered`: Hi-Tech has closed the order and delivered against it.
 * - `part_delivered`: delivered against, and the order is still open.
 * - `awaiting`: open, nothing delivered yet.
 * - `invoiced`: invoiced straight from the sales order, no delivery note.
 * - `closed`: closed by Hi-Tech with nothing delivered or invoiced.
 * - `cancelled`: cancelled by Hi-Tech.
 */
export type AcctState = 'delivered' | 'part_delivered' | 'awaiting' | 'invoiced' | 'closed' | 'cancelled';

/** Which document the lines are read from. */
export type AcctDocument = 'delivery' | 'sales_order';

export interface AcctLine {
  item: string;
  itemName: string;
  kg: number;
  /** Rolls, from the sales order. Unknown on a delivery, which is in kilos. */
  rolls: number | null;
  /** Per kilo, GST-inclusive — what the manager approved. */
  rate: number;
  amount: number;
}

export interface AcctView {
  state: AcctState;
  shows: AcctDocument;
  lines: AcctLine[];
  totalKg: number;
  total: number;
  /** The deliveries behind `lines` when `shows` is 'delivery'; else empty. */
  deliveries: string[];
}

const clean = (v: unknown) => String(v ?? '').trim();
const status = (s: string) => clean(s).toLowerCase();

export function accountantView(order: AcctOrderInput): AcctView {
  const lines = order.lines ?? [];
  const sap = status(order.sap_status);
  const names = new Map(lines.map((l) => [clean(l.item), clean(l.item_name) || clean(l.item)]));

  const billed = billableLines(lines);
  if (billed.basis === 'delivered' && billed.lines.length > 0) {
    const shown: AcctLine[] = billed.lines.map((l) => ({
      item: l.item,
      itemName: names.get(l.item) ?? l.item,
      kg: l.kg,
      rolls: null,
      rate: l.rate,
      amount: l.amount,
    }));
    return {
      // Only Hi-Tech says an order is finished; a delivery on an open order may
      // be followed by another.
      state: sap === SAP_CLOSED ? 'delivered' : 'part_delivered',
      shows: 'delivery',
      lines: shown,
      totalKg: roundTo(shown.reduce((s, l) => s + l.kg, 0), 3),
      total: billed.total,
      deliveries: [...new Set((order.delivery_refs ?? []).map(clean).filter(Boolean))],
    };
  }

  const shown: AcctLine[] = lines.map((l) => ({
    item: clean(l.item),
    itemName: names.get(clean(l.item)) ?? clean(l.item),
    kg: roundTo(Number(l.ordered_kg) || 0, 3),
    rolls: Number(l.rolls) || 0,
    rate: approvedRate(l),
    amount: roundTo(Number(l.amount) || 0, 2),
  }));
  const invoiced = lines.some((l) => roundTo(Number(l.invoiced_kg) || 0, 3) > 0);
  const state: AcctState =
    sap === SAP_CANCELLED ? 'cancelled' : invoiced ? 'invoiced' : sap === SAP_CLOSED ? 'closed' : 'awaiting';
  return {
    state,
    shows: 'sales_order',
    lines: shown,
    totalKg: roundTo(shown.reduce((s, l) => s + l.kg, 0), 3),
    total: roundTo(shown.reduce((s, l) => s + l.amount, 0), 2),
    deliveries: [],
  };
}

export const ACCT_STATE_LABEL: Record<AcctState, string> = {
  delivered: 'Delivered',
  part_delivered: 'Part delivered',
  awaiting: 'Awaiting delivery',
  invoiced: 'Invoiced, no delivery note',
  closed: 'Closed, not delivered',
  cancelled: 'Cancelled at Hi-Tech',
};

export const ACCT_STATE_TONE: Record<AcctState, 'ok' | 'info' | 'warn' | 'neutral' | 'danger'> = {
  delivered: 'ok',
  part_delivered: 'info',
  awaiting: 'neutral',
  invoiced: 'warn',
  closed: 'neutral',
  cancelled: 'danger',
};

/** The screen's filters. */
export type AcctTab = 'all' | 'delivered' | 'not_delivered' | 'cancelled';

export const ACCT_TABS: AcctTab[] = ['all', 'delivered', 'not_delivered', 'cancelled'];

export const ACCT_TAB_LABEL: Record<AcctTab, string> = {
  all: 'All',
  delivered: 'Delivered',
  not_delivered: 'Not delivered',
  cancelled: 'Cancelled',
};

export function tabOf(state: AcctState): Exclude<AcctTab, 'all'> {
  if (state === 'delivered' || state === 'part_delivered') return 'delivered';
  if (state === 'cancelled') return 'cancelled';
  return 'not_delivered';
}

/** Matches a search against what the accountant would type: customer, either order number, a delivery. */
export function matchesSearch(
  q: string,
  o: { customerName: string; customer: string; name: string; sapSalesOrder: string; deliveries: string[] },
): boolean {
  const t = q.trim().toLowerCase();
  if (!t) return true;
  return [o.customerName, o.customer, o.name, o.sapSalesOrder, ...o.deliveries].some((v) =>
    clean(v).toLowerCase().includes(t),
  );
}
