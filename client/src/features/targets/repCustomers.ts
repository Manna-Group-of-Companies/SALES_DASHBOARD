/**
 * One rep's customers for a month, as the Team Targets drill-down shows them.
 *
 * Display only — no rule here decides money, approval or stock. It joins what
 * already exists:
 *   - the customers assigned to the rep, with what SAP says they owe today
 *     (outstanding, overdue past their payment terms, and the aging buckets);
 *   - the orders the rep placed in the month, before GST;
 *   - the order lines SAP invoiced in the month, from `manna_sales_targets`.
 *
 * There is no "paid" figure. ERPNext does not hold payments against invoices,
 * only SAP's outstanding total per customer, and invoiced-minus-outstanding is
 * not what was paid: outstanding includes invoices from before the app.
 */

import type { InvoicedLine } from '@/domain/salesTarget';
import type { SalesCustomer } from '@/domain/types';
import type { RepMonthOrder } from '@/api/salesTargets';
import { agingOf, type CustomerRow } from '@/domain/credit';

/** One SAP invoice in the month, its lines added up. */
export interface InvoiceDoc {
  invoice: string;
  date: string;
  orders: string[];
  amount: number;
}

export interface RepCustomerRow {
  /** The Customer's name (id); '' for one only known from an invoice line. */
  id: string;
  name: string;
  /** Assigned to the rep today. False for one that came in through an order only. */
  assigned: boolean;
  paymentTerms?: string;
  orders: RepMonthOrder[];
  ordered: number;
  lastOrder?: string;
  invoices: InvoiceDoc[];
  invoiced: number;
  /** Null when the customer is not assigned to the rep, so not loaded. */
  outstanding: number | null;
  overdue: number;
  overdueDays: number;
  /** The credit fields as stored, for AgingBoxes. Null when not loaded. */
  credit: CustomerRow | null;
}

export type CustomerStatus = 'overdue' | 'owes' | 'clear' | 'unknown';

export function statusOf(r: RepCustomerRow): CustomerStatus {
  if (r.outstanding == null) return 'unknown';
  // A rupee left on an invoice is rounding (credit.ts OVERDUE_TOLERANCE).
  if (r.overdue > 1) return 'overdue';
  if (r.outstanding > 1) return 'owes';
  return 'clear';
}

const key = (s: string) => s.trim().toLowerCase();

export function buildRepCustomers(
  customers: SalesCustomer[],
  orders: RepMonthOrder[],
  lines: InvoicedLine[],
): RepCustomerRow[] {
  const rows: RepCustomerRow[] = [];
  const byId = new Map<string, RepCustomerRow>();
  // For invoice lines only, which carry a name and no id. The first customer
  // of a name keeps it: two customers of one name are still two rows.
  const byName = new Map<string, RepCustomerRow>();

  const add = (row: RepCustomerRow) => {
    rows.push(row);
    if (row.id) byId.set(row.id, row);
    if (!byName.has(key(row.name))) byName.set(key(row.name), row);
    return row;
  };

  for (const c of customers) {
    const credit: CustomerRow = {
      custom_outstanding_balance: c.outstanding,
      custom_credit_limit: c.creditLimit,
      custom_outstanding_0_30: c.outstanding0_30,
      custom_outstanding_30_60: c.outstanding30_60,
      custom_outstanding_60_90: c.outstanding60_90,
      custom_outstanding_90_plus: c.outstanding90Plus,
      custom_overdue_past_terms: c.overduePastTerms,
      custom_payment_terms: c.paymentTerms ?? '',
      custom_overdue_days: c.overdueDays,
    };
    add({
      id: c.id,
      name: c.name,
      assigned: true,
      paymentTerms: c.paymentTerms && c.paymentTerms !== 'null' ? c.paymentTerms : undefined,
      orders: [],
      ordered: 0,
      invoices: [],
      invoiced: 0,
      // Through credit.ts, which knows the stored total wins over the buckets.
      outstanding: agingOf(credit).total,
      overdue: c.overduePastTerms,
      overdueDays: Math.max(0, Math.round(c.overdueDays)),
      credit,
    });
  }

  const blank = (id: string, name: string): RepCustomerRow =>
    add({
      id,
      name,
      assigned: false,
      orders: [],
      ordered: 0,
      invoices: [],
      invoiced: 0,
      outstanding: null,
      overdue: 0,
      overdueDays: 0,
      credit: null,
    });

  const orderCustomer = new Map<string, RepCustomerRow>();
  for (const o of orders) {
    // An order names its customer exactly: matched by name it landed under a
    // different customer of the same name (11 Nov 2026, Drona Tyres and its
    // demo copy). Only an order with no customer id falls back to the name.
    const row =
      byId.get(o.customer) ??
      (o.customer ? blank(o.customer, o.customerName) : (byName.get(key(o.customerName)) ?? blank('', o.customerName)));
    row.orders.push(o);
    row.ordered += o.netTotal;
    if (!row.lastOrder || o.placedOn > row.lastOrder) row.lastOrder = o.placedOn;
    orderCustomer.set(o.id, row);
  }

  for (const l of lines) {
    // Lines name the customer only; the order, when it was placed this month,
    // pins the exact one.
    const row = orderCustomer.get(l.order) ?? byName.get(key(l.customerName)) ?? blank('', l.customerName);
    let inv = row.invoices.find((d) => d.invoice === l.invoice);
    if (!inv) {
      inv = { invoice: l.invoice, date: l.invoiceDate, orders: [], amount: 0 };
      row.invoices.push(inv);
    }
    if (!inv.orders.includes(l.order)) inv.orders.push(l.order);
    inv.amount += l.amount;
    row.invoiced += l.amount;
  }

  // Most active first: invoiced, then ordered, then what they owe.
  return rows.sort(
    (a, b) =>
      b.invoiced - a.invoiced ||
      b.ordered - a.ordered ||
      (b.outstanding ?? 0) - (a.outstanding ?? 0) ||
      a.name.localeCompare(b.name),
  );
}

/** "2026-11-05" → "05 Nov 2026". Anything else passes through. */
export function shortDate(iso?: string): string {
  if (!iso) return '—';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return iso;
  const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][Number(m[2]) - 1];
  return `${m[3]} ${mon} ${m[1]}`;
}

/** "Test Demo Rep" → "TD". */
export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  return ((parts[0]?.[0] ?? '') + (parts[1]?.[0] ?? '')).toUpperCase() || '?';
}
