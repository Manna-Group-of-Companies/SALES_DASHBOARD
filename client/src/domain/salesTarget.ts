/**
 * Monthly sales targets, and how far each rep is towards theirs.
 *
 * What counts as achieved is decided once, on the server, by the
 * `manna_sales_targets` Server Script (app/server/sales_targets.py): only
 * order lines SAP has invoiced, dated in the target's month. An approved order
 * that has not been invoiced counts for nothing.
 *
 * This module only turns the script's totals into a fraction. That step is
 * pinned by shared/fixtures/sales_target_progress.json; the Dart twin is
 * app/lib/core/sales_target.dart.
 */

export const TARGET_MONTHS = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
] as const;

export type TargetUnit = 'Currency' | 'Tonnes';

/** One order line SAP has invoiced. */
export interface InvoicedLine {
  order: string;
  customerName: string;
  itemName: string;
  invoice: string;
  invoiceDate: string;
  amount: number;
  kg: number;
}

/** A rep's target for the month and what SAP has invoiced against it. */
export interface TargetRow {
  salesPerson: string;
  team: string;
  currency: string;
  targetName: string | null;
  targetAmount: number;
  unit: TargetUnit;
  invoicedAmount: number;
  invoicedKg: number;
  /** What the rep's customers owe, from the SAP credit sync. Not month-bound. */
  outstanding: number;
  /** The part of `outstanding` overdue past the customers' payment terms. */
  overdue: number;
  lines: InvoicedLine[];
  lineCount: number;
}

/** What `manna_sales_targets` returns for one month. */
export interface TargetMonth {
  month: string;
  year: number;
  isGM: boolean;
  /** Reps whose target this login may set: a manager's own team, nobody else. */
  canEdit: string[];
  rows: TargetRow[];
}

const num = (v: unknown): number => {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string => (v == null ? '' : String(v));

export function toInvoicedLine(m: Record<string, unknown>): InvoicedLine {
  return {
    order: str(m.order),
    customerName: str(m.customer_name),
    itemName: str(m.item_name),
    invoice: str(m.invoice),
    invoiceDate: str(m.invoice_date),
    amount: num(m.amount),
    kg: num(m.kg),
  };
}

export function toTargetRow(m: Record<string, unknown>): TargetRow {
  const lines = Array.isArray(m.lines)
    ? (m.lines as Record<string, unknown>[]).map(toInvoicedLine)
    : [];
  return {
    salesPerson: str(m.sales_person),
    team: str(m.team),
    currency: str(m.currency) || 'INR',
    targetName: m.target_name ? str(m.target_name) : null,
    targetAmount: num(m.target_amount),
    // Anything but Tonnes is money, as the doctype's default is.
    unit: m.target_unit === 'Tonnes' ? 'Tonnes' : 'Currency',
    invoicedAmount: num(m.invoiced_amount),
    invoicedKg: num(m.invoiced_kg),
    outstanding: num(m.outstanding),
    overdue: num(m.overdue),
    lines,
    // The fixture states a count without listing lines.
    lineCount: m.line_count != null ? num(m.line_count) : lines.length,
  };
}

export function toTargetMonth(m: Record<string, unknown>): TargetMonth {
  return {
    month: str(m.month),
    year: num(m.year),
    isGM: m.is_gm === 1 || m.is_gm === true,
    canEdit: Array.isArray(m.can_edit) ? m.can_edit.map(str) : [],
    rows: Array.isArray(m.rows) ? (m.rows as Record<string, unknown>[]).map(toTargetRow) : [],
  };
}

export const hasTarget = (r: TargetRow): boolean => r.targetAmount > 0;
export const hasInvoices = (r: TargetRow): boolean => r.lineCount > 0;

/** Achieved in the target's own unit: tonnes, or money. */
export function achieved(r: TargetRow): number {
  return r.unit === 'Tonnes' ? r.invoicedKg / 1000 : r.invoicedAmount;
}

/**
 * Achieved over target, not capped — past target reads past 1. Zero when
 * there is no target. Clamp it for a bar, never for the number.
 */
export function fraction(r: TargetRow): number {
  return hasTarget(r) ? achieved(r) / r.targetAmount : 0;
}

/** Money in the rep's currency, whatever the target's unit. */
export function formatMoney(r: TargetRow, v: number): string {
  const locale = r.currency === 'AED' ? 'en-AE' : 'en-IN';
  return `${r.currency} ${Math.round(v).toLocaleString(locale)}`;
}

/** "INR 1,20,000" / "AED 120,000" or "12.5 t". */
export function formatTarget(r: TargetRow, v: number): string {
  if (r.unit === 'Tonnes') return `${Number.isInteger(v) ? v : v.toFixed(2)} t`;
  const locale = r.currency === 'AED' ? 'en-AE' : 'en-IN';
  return `${r.currency} ${Math.round(v).toLocaleString(locale)}`;
}
