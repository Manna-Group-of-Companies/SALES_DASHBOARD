/**
 * Monthly sales targets — read through the `manna_sales_targets` Server
 * Script (app/server/sales_targets.py), which decides whose targets this login
 * sees and counts only what SAP has invoiced. Written straight to the
 * `Sales Target` doctype, where `manna_sales_target_guard` refuses anybody but
 * the rep's own team manager.
 */
import { createDoc, http, listDocs, listDocsIn, toApiError, updateDoc } from './client';
import { toTargetMonth, type TargetMonth, type TargetUnit } from '@/domain/salesTarget';

const SALES_TARGET = 'Sales Target';

export async function getTargetMonth(month: string, year: number): Promise<TargetMonth> {
  const { data } = await http.get<{ message: Record<string, unknown> }>(
    '/api/method/manna_sales_targets',
    { params: { month, year } },
  );
  return toTargetMonth(data.message ?? {});
}

/** A Sales Order a rep placed, for the rep's customer drill-down. */
export interface RepMonthOrder {
  id: string;
  customer: string;
  customerName: string;
  placedOn: string;
  /** Before GST, the same basis as achieved. */
  netTotal: number;
  sapInvoice?: string;
}

/**
 * The orders a rep placed between two dates (inclusive, yyyy-mm-dd). Cancelled
 * (docstatus 2) and rejected orders are left out: neither was ever going to be
 * invoiced.
 */
export async function getRepOrders(rep: string, from: string, to: string): Promise<RepMonthOrder[]> {
  const rows = await listDocs<Record<string, unknown>>('Sales Order', {
    fields: ['name', 'customer', 'customer_name', 'transaction_date', 'net_total', 'custom_sap_invoice'],
    filters: [
      ['custom_sales_person', '=', rep],
      ['transaction_date', 'between', [from, to]],
      ['docstatus', '!=', 2],
      ['custom_po_status', '!=', 'Rejected'],
    ],
    orderBy: 'transaction_date desc',
    limit: 0,
  });
  return rows.map((r) => ({
    id: String(r.name),
    customer: String(r.customer ?? ''),
    customerName: String(r.customer_name ?? r.customer ?? ''),
    placedOn: String(r.transaction_date ?? '').slice(0, 10),
    netTotal: Number(r.net_total) || 0,
    sapInvoice: r.custom_sap_invoice && r.custom_sap_invoice !== 'null' ? String(r.custom_sap_invoice) : undefined,
  }));
}

/**
 * One SAP A/R invoice, with what has been paid against it.
 *
 * Written by the SAP sync into the `SAP Invoice` doctype — being added on the
 * SAP side as of 5 Nov 2026. Until that doctype exists (or while it is empty)
 * the drill-down falls back to the invoiced order lines it already shows.
 * If the sync ends up using other field names, change SAP_INVOICE_FIELD only.
 */
export interface SapInvoice {
  customer: string;
  company: string;
  invoiceNo: string;
  postingDate: string;
  dueDate: string;
  total: number;
  paid: number;
  balance: number;
  /** SAP's DocumentStatus as the sync wrote it: Open / Closed. */
  status: string;
}

export const SAP_INVOICE_DOCTYPE = 'SAP Invoice';
export const SAP_INVOICE_FIELD = {
  customer: 'customer',
  company: 'company',
  invoiceNo: 'invoice_no',
  postingDate: 'posting_date',
  dueDate: 'due_date',
  total: 'total',
  paid: 'paid',
  balance: 'balance',
  status: 'status',
} as const;

/** The SAP invoices of these customers. [] when the doctype is not there yet. */
export async function getSapInvoices(customers: string[]): Promise<SapInvoice[]> {
  const F = SAP_INVOICE_FIELD;
  try {
    const rows = await listDocsIn<Record<string, unknown>>(SAP_INVOICE_DOCTYPE, F.customer, customers, {
      fields: Object.values(F),
      orderBy: `${F.postingDate} desc`,
      limit: 0,
    });
    return rows.map((r) => {
      const total = Number(r[F.total]) || 0;
      const paid = Number(r[F.paid]) || 0;
      return {
        customer: String(r[F.customer] ?? ''),
        company: String(r[F.company] ?? ''),
        invoiceNo: String(r[F.invoiceNo] ?? ''),
        postingDate: String(r[F.postingDate] ?? '').slice(0, 10),
        dueDate: String(r[F.dueDate] ?? '').slice(0, 10),
        total,
        paid,
        balance: r[F.balance] != null ? Number(r[F.balance]) || 0 : total - paid,
        status: String(r[F.status] ?? ''),
      };
    });
  } catch (e) {
    // Not built yet (404/417), or this login cannot read it (403): fall back.
    if (import.meta.env.DEV) console.warn('[manna] SAP Invoice not readable:', toApiError(e).message);
    return [];
  }
}

/** One target per rep per month: update it if there is one, else create it. */
export async function upsertTarget(args: {
  salesPerson: string;
  month: string;
  year: number;
  amount: number;
  unit: TargetUnit;
}): Promise<void> {
  const existing = await listDocs<{ name: string }>(SALES_TARGET, {
    fields: ['name'],
    filters: [
      ['sales_person', '=', args.salesPerson],
      ['month', '=', args.month],
      ['year', '=', args.year],
    ],
    limit: 1,
  });
  const body = { target_amount: args.amount, target_unit: args.unit };
  if (existing[0]) {
    await updateDoc(SALES_TARGET, existing[0].name, body);
  } else {
    await createDoc(SALES_TARGET, {
      ...body,
      sales_person: args.salesPerson,
      month: args.month,
      year: args.year,
    });
  }
}

/** Orders a rep placed in a month, and their value before GST. */
export interface RepMonthTotals {
  orders: number;
  ordered: number;
}

/**
 * Every rep's orders between two dates (inclusive, yyyy-mm-dd), in one read:
 * the same orders `getRepOrders` reads for one rep — cancelled and rejected
 * left out — totalled by `custom_sales_person`.
 */
export async function getMonthOrdersByRep(from: string, to: string): Promise<Map<string, RepMonthTotals>> {
  const rows = await listDocs<Record<string, unknown>>('Sales Order', {
    fields: ['custom_sales_person', 'net_total'],
    filters: [
      ['transaction_date', 'between', [from, to]],
      ['docstatus', '!=', 2],
      ['custom_po_status', '!=', 'Rejected'],
    ],
    limit: 0,
  });
  const by = new Map<string, RepMonthTotals>();
  for (const r of rows) {
    const rep = String(r.custom_sales_person ?? '').trim();
    if (!rep) continue;
    const t = by.get(rep) ?? { orders: 0, ordered: 0 };
    t.orders += 1;
    t.ordered += Number(r.net_total) || 0;
    by.set(rep, t);
  }
  return by;
}
