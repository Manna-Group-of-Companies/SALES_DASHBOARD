/**
 * Rules for `Manna Production Order` — the two flows in
 * `shared/PRODUCTION_FLOWS.md`.
 *
 * **Paired with `app/lib/core/production_order.dart`.** Both read
 * `shared/fixtures/production_order.json` in their tests. See
 * `shared/README.md`.
 */

import { FULFILMENT_MODE } from '@/api/endpoints';

/** A Sales Order Item, as ERPNext returns it. Only the three fields matter here. */
type Row = Record<string, unknown>;

/** Frappe returns an unset Data field as null, '' or the string 'null'. */
function clean(v: unknown): string {
  const s = typeof v === 'string' ? v.trim() : v == null ? '' : String(v).trim();
  return s === 'null' || s === 'undefined' ? '' : s;
}

/**
 * Whether an order line's production needs diverting to company stock — the
 * one join between the two flows. Cancelling a Sales Order after its goods
 * were made leaves rubber nobody is waiting for; this decides which lines
 * that is true for.
 *
 * All three have to hold:
 *   - the order is actually cancelled (`docstatus === 2`), separate from
 *     `custom_sales_status` — a rejected-before-approval order was never
 *     produced and is not this;
 *   - the line was being made for THIS customer (`custom_fulfilment_mode` is
 *     `New Production`) — a line served from the shelf or claimed off a
 *     replenishment run belongs to a pool already, and cancelling the order
 *     just releases the claim rather than diverting anything;
 *   - work had actually started (`custom_production_stage` is set) — a line
 *     still unstarted when the order was cancelled was never produced, and
 *     diverting it would put a batch of goods nobody made onto the shelf.
 */
export function needsStockDiversion(line: Row): boolean {
  const docstatus = Number(line.docstatus) || 0;
  const mode = clean(line.custom_fulfilment_mode);
  const started = clean(line.custom_production_stage) !== '';
  return docstatus === 2 && mode === FULFILMENT_MODE.newProduction && started;
}

/** One production order, reduced to what `alreadyDiverted` needs to check. */
export interface DivertLookup {
  salesOrderId?: string;
  itemCode: string;
  purpose: 'stock' | 'order';
}

/**
 * Already diverted — a `Manna Production Order` already exists for this
 * order/item pair. Diverting is a one-time act; without this check, opening
 * the same cancelled order twice would raise a second production order and a
 * second batch for goods that only exist once.
 */
export function alreadyDiverted(
  salesOrderId: string,
  itemCode: string,
  productionOrders: DivertLookup[],
): boolean {
  return productionOrders.some(
    (o) => o.purpose === 'order' && o.salesOrderId === salesOrderId && o.itemCode === itemCode,
  );
}
