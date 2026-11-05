/**
 * Product sales for the GM's report (5 Nov 2026): what was ordered in a date
 * range, line by line.
 *
 * "Sold" means ordered: every Sales Order raised in the range, less cancelled
 * (docstatus 2) and rejected ones — the same orders Team Targets counts as
 * Orders/Ordered. Not invoiced; that is Achieved on Team Targets.
 *
 * The lines come in the same request as the orders (Frappe joins the child
 * table when its fields are named, as api/mannaTreads.ts does), because
 * `Sales Order Item` answers 403 on its own endpoint.
 */
import { listDocs } from './client';

export interface SoldLine {
  order: string;
  date: string;
  company: string;
  rep: string;
  itemCode: string;
  itemName: string;
  /** Before GST. */
  amount: number;
  kg: number;
  rolls: number;
  qty: number;
  /** The line's selling unit (`uom`), e.g. Nos, Kg. */
  uom: string;
  /** Price per unit of `uom`, before GST. */
  rate: number;
  /** What the rep quoted per kg (`custom_rate_per_kg`); 0 when not quoted per kg. */
  ratePerKg: number;
}

const CHILD = '`tabSales Order Item`';
const num = (v: unknown): number => {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string => (v == null ? '' : String(v));

/** Every order line raised between two dates (inclusive, yyyy-mm-dd). */
export async function getSoldLines(from: string, to: string): Promise<SoldLine[]> {
  const rows = await listDocs<Record<string, unknown>>('Sales Order', {
    fields: [
      'name',
      'transaction_date',
      'custom_company',
      'custom_sales_person',
      `${CHILD}.item_code`,
      `${CHILD}.item_name`,
      `${CHILD}.amount`,
      `${CHILD}.custom_total_weight`,
      `${CHILD}.custom_rolls`,
      `${CHILD}.qty`,
      `${CHILD}.uom`,
      `${CHILD}.rate`,
      `${CHILD}.custom_rate_per_kg`,
    ],
    filters: [
      ['transaction_date', 'between', [from, to]],
      ['docstatus', '!=', 2],
      ['custom_po_status', '!=', 'Rejected'],
    ],
    orderBy: '`tabSales Order`.transaction_date asc',
    limit: 0,
  });
  // A refused field list comes back as parent rows with no lines; say so
  // rather than show a month with nothing sold.
  if (rows.length && rows.every((r) => !('item_code' in r))) {
    throw new Error('The order lines could not be read for this login.');
  }
  return rows
    .filter((r) => str(r.item_code))
    .map((r) => ({
      order: str(r.name),
      date: str(r.transaction_date).slice(0, 10),
      company: str(r.custom_company),
      rep: str(r.custom_sales_person),
      itemCode: str(r.item_code),
      itemName: str(r.item_name) || str(r.item_code),
      amount: num(r.amount),
      kg: num(r.custom_total_weight),
      rolls: num(r.custom_rolls),
      qty: num(r.qty),
      uom: str(r.uom),
      rate: num(r.rate),
      ratePerKg: num(r.custom_rate_per_kg),
    }));
}
