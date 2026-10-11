/**
 * The accountant's screen: finished Hi-Tech orders, and asking for each to be
 * raised again in Manna Treads' SAP to the end customer (26 Sep 2026).
 *
 * Since 8 October 2026 the screen is read-only and uses `listHitechOrders`
 * alone: every order at Hi-Tech with its real customer, and the delivery
 * against it once there is one. The request functions below are kept, unused,
 * for when raising the Manna Treads order is switched back on.
 *
 * Nothing here writes to SAP. The office order sync reads Hi-Tech's delivery
 * notes and invoices onto each Sales Order Item (`custom_hitech_*`), and once
 * the accountant asks, creates the Manna Treads order and writes its number
 * back (`custom_mt_*`). The one write here is `manna_mt_so_request`, a Server
 * Script that re-checks every order, marks it requested and raises the order
 * sync's flag — so a browser console cannot request an order the rule refuses.
 *
 * What is billable is `domain/mannaTreadsReorder.ts`'s decision, not this
 * file's; this only reads the facts into the fixture's shape.
 */

import { getDoc, http, listDocs, listDocsIn, type Filter } from './client';
import type { AcctLineInput, AcctOrderInput } from '@/domain/accountantView';
import { DOCTYPE, SALES_ORDER_FIELD, SALES_ORDER_ITEM_FIELD } from './endpoints';
import {
  assessOrder,
  requestInBatches,
  type MtLineInput,
  type MtOrderInput,
  type MtProgress,
  type MtRequestOutcome,
  type MtRequestResult,
} from '@/domain/mannaTreadsReorder';
import { PO_STATUS } from '@/domain/orderStatus';
import { frappeToday } from '@/domain/serverClock';
import { shiftDays } from '@/domain/hrRules';

export type { MtProgress, MtRequestOutcome, MtRequestResult };

/** Created on the live site 26 Sep 2026; all read-only, allow_on_submit, no_copy. */
const MT_FIELD = {
  requested: 'custom_mt_so_requested',
  requestedBy: 'custom_mt_so_requested_by',
  requestedAt: 'custom_mt_so_requested_at',
  /** Manna Treads' DocNum — what a person quotes. */
  salesOrder: 'custom_mt_sales_order',
  /** Manna Treads' DocEntry, because DocNum is not unique in SAP. */
  salesOrderEntry: 'custom_mt_sales_order_entry',
  syncError: 'custom_mt_sync_error',
  syncedAt: 'custom_mt_synced_at',
} as const;

const HITECH_ITEM_FIELD = {
  deliveredKg: 'custom_hitech_delivered_kg',
  invoicedKg: 'custom_hitech_invoiced_kg',
  /** "DN 4 (18-09-2026)" — human-readable, one per delivery note. */
  deliveryRefs: 'custom_hitech_delivery_refs',
} as const;

/** `Customer.custom_bp_code` — the MANNA_TREADS_LIVE CardCode. */
const BP_CODE = 'custom_bp_code';

/** The only unit Hi-Tech makes for. */
const UNIT = 'Manna Treads';

/**
 * The PASS A gate, exactly. `manna_mt_so_request` and PASS C both refuse any
 * other status, so an order at GM or final approval is never offered here.
 */
const PO_GATE = PO_STATUS.approved;

/**
 * How far back to look, by the day the order was placed. A year, because an
 * order Hi-Tech closes late — or one blocked for months on a customer code —
 * still has to be billed, and a shorter window hides it for good.
 */
const LOOKBACK_DAYS = 365;

/** Item reads in flight at once — one getDoc per order, since child tables cannot be listed here. */
const ITEM_READS = 6;

export interface MtOrderRow {
  /** ERPNext Sales Order name. */
  name: string;
  customer: string;
  customerName: string;
  transactionDate: string;
  poStatus: string;
  /** Hi-Tech's DocNum. */
  hitechOrder: string;
  /** Hi-Tech's status, verbatim. */
  hitechStatus: string;
  /** Manna Treads CardCode; blank when the customer has none. */
  mtCode: string;
  requested: boolean;
  requestedBy: string | null;
  requestedAt: string | null;
  mtSalesOrder: string;
  mtSalesOrderEntry: string;
  mtError: string;
  mtSyncedAt: string | null;
  /** Every delivery note named on any line, once each. */
  deliveryRefs: string[];
  /** Item code to item name, for the lines table. */
  itemNames: Record<string, string>;
  /**
   * False when the items were not read: a cancelled order has nothing to bill,
   * and a created one is shown by its Manna Treads number, not its lines.
   */
  linesRead: boolean;
  /** The rule's input, exactly as the fixture shapes it. */
  input: MtOrderInput;
}

export interface MtOrderList {
  orders: MtOrderRow[];
  /**
   * Orders whose items could not be read. Left off `orders` rather than shown
   * with no lines, which the rule would read as nothing delivered.
   */
  unreadable: { name: string; message: string }[];
}

const str = (v: unknown): string => {
  const t = v == null ? '' : String(v).trim();
  return t === 'null' ? '' : t;
};
const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};
const flag = (v: unknown): boolean => v === 1 || v === true || v === '1';

/** Run `fn` over `items`, `limit` at a time, keeping the input order. */
async function pool<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

/** The refs field is free text; split it however the sync separated it. */
function splitRefs(v: unknown): string[] {
  return str(v)
    .split(/[\n;,]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

export async function listMannaTreadsOrders(): Promise<MtOrderList> {
  const since = shiftDays(frappeToday(), -LOOKBACK_DAYS);
  const heads = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
    fields: [
      'name',
      SALES_ORDER_FIELD.customer,
      SALES_ORDER_FIELD.customerName,
      SALES_ORDER_FIELD.placedOn,
      SALES_ORDER_FIELD.unit,
      SALES_ORDER_FIELD.poStatus,
      SALES_ORDER_FIELD.sapSalesOrder,
      SALES_ORDER_FIELD.sapSalesOrderStatus,
      ...Object.values(MT_FIELD),
    ],
    filters: [
      [SALES_ORDER_FIELD.unit, '=', UNIT],
      [SALES_ORDER_FIELD.poStatus, '=', PO_GATE],
      [SALES_ORDER_FIELD.sapSalesOrder, 'is', 'set'],
      [SALES_ORDER_FIELD.placedOn, '>=', since],
      // A document cancelled in ERPNext is not an order at all.
      ['docstatus', '!=', 2],
    ],
    orderBy: 'transaction_date desc, name desc',
    limit: 0,
  });

  const customers = [...new Set(heads.map((h) => str(h[SALES_ORDER_FIELD.customer])).filter(Boolean))];
  // Chunked: a long `name in (...)` is refused by Frappe Cloud before Frappe sees it.
  const codeRows = await listDocsIn<Record<string, unknown>>(DOCTYPE.customer, 'name', customers, {
    fields: ['name', BP_CODE],
  });
  const codeOf = new Map(codeRows.map((r) => [str(r.name), str(r[BP_CODE])]));

  const rows: MtOrderRow[] = heads.map((h) => {
    const customer = str(h[SALES_ORDER_FIELD.customer]);
    const mtSalesOrder = str(h[MT_FIELD.salesOrder]);
    const mtSalesOrderEntry = str(h[MT_FIELD.salesOrderEntry]);
    return {
      name: str(h.name),
      customer,
      customerName: str(h[SALES_ORDER_FIELD.customerName]) || customer,
      transactionDate: str(h[SALES_ORDER_FIELD.placedOn]),
      poStatus: str(h[SALES_ORDER_FIELD.poStatus]),
      hitechOrder: str(h[SALES_ORDER_FIELD.sapSalesOrder]),
      hitechStatus: str(h[SALES_ORDER_FIELD.sapSalesOrderStatus]),
      mtCode: codeOf.get(customer) ?? '',
      requested: flag(h[MT_FIELD.requested]),
      requestedBy: str(h[MT_FIELD.requestedBy]) || null,
      requestedAt: str(h[MT_FIELD.requestedAt]) || null,
      mtSalesOrder,
      mtSalesOrderEntry,
      mtError: str(h[MT_FIELD.syncError]),
      mtSyncedAt: str(h[MT_FIELD.syncedAt]) || null,
      deliveryRefs: [],
      itemNames: {},
      linesRead: false,
      input: {
        sap_sales_order: str(h[SALES_ORDER_FIELD.sapSalesOrder]),
        sap_status: str(h[SALES_ORDER_FIELD.sapSalesOrderStatus]),
        customer_mt_code: codeOf.get(customer) ?? '',
        // Either number means SAP has the order; DocEntry alone still counts.
        mt_sales_order: mtSalesOrder || mtSalesOrderEntry,
        mt_requested: flag(h[MT_FIELD.requested]),
        mt_error: str(h[MT_FIELD.syncError]),
        lines: [],
      },
    };
  });

  /*
   * Items only where they can change the answer. The header alone settles an
   * order never sent (none are listed), one Hi-Tech cancelled, and one already
   * created in Manna Treads — whose amount is SAP's to state, not a figure
   * worked out here. The rule's precedence is asked rather than restated.
   */
  const needLines = rows.filter((r) => {
    const s = assessOrder(r.input).state;
    return s !== 'not_in_sap' && s !== 'cancelled' && s !== 'created';
  });

  const unreadable: MtOrderList['unreadable'] = [];
  await pool(needLines, ITEM_READS, async (r) => {
    try {
      const doc = await getDoc<{ items?: Record<string, unknown>[] }>(DOCTYPE.salesOrder, r.name);
      const items = doc.items ?? [];
      const lines: MtLineInput[] = items.map((it) => ({
        item: str(it.item_code),
        // ORDERED kilos. `qty` is rolls on this site despite the Kg uom.
        ordered_kg: num(it[SALES_ORDER_ITEM_FIELD.totalWeight]),
        amount: num(it.amount),
        rate_per_kg: num(it[SALES_ORDER_ITEM_FIELD.ratePerKg]),
        delivered_kg: num(it[HITECH_ITEM_FIELD.deliveredKg]),
        invoiced_kg: num(it[HITECH_ITEM_FIELD.invoicedKg]),
      }));
      const names: Record<string, string> = {};
      for (const it of items) {
        const code = str(it.item_code);
        if (code && !names[code]) names[code] = str(it.item_name) || code;
      }
      r.input = { ...r.input, lines };
      r.itemNames = names;
      r.deliveryRefs = [...new Set(items.flatMap((it) => splitRefs(it[HITECH_ITEM_FIELD.deliveryRefs])))];
      r.linesRead = true;
    } catch (e) {
      unreadable.push({ name: r.name, message: e instanceof Error ? e.message : 'Could not be read.' });
    }
  });

  const lost = new Set(unreadable.map((u) => u.name));
  return { orders: rows.filter((r) => !lost.has(r.name)), unreadable };
}

// ------------------------------------------- the accountant's view (8 Oct 2026) ---

/** One order at Hi-Tech, as the accountant's screen reads it. */
export interface HitechOrderRow {
  /** ERPNext Sales Order name. */
  name: string;
  customer: string;
  customerName: string;
  /** Manna Treads CardCode; blank when the customer has none. */
  mtCode: string;
  rep: string;
  unit: string;
  transactionDate: string;
  /** Hi-Tech's DocNum. */
  sapSalesOrder: string;
  /** Hi-Tech's status, verbatim. */
  sapStatus: string;
  /** Hi-Tech's A/R invoice, once every line is invoiced. */
  sapInvoice: string;
  input: AcctOrderInput;
}

export interface HitechOrderList {
  orders: HitechOrderRow[];
  unreadable: { name: string; message: string }[];
}

const HEAD_FIELDS = [
  'name',
  SALES_ORDER_FIELD.customer,
  SALES_ORDER_FIELD.customerName,
  SALES_ORDER_FIELD.placedOn,
  SALES_ORDER_FIELD.unit,
  SALES_ORDER_FIELD.rep,
  SALES_ORDER_FIELD.sapSalesOrder,
  SALES_ORDER_FIELD.sapSalesOrderStatus,
  SALES_ORDER_FIELD.sapInvoice,
];

/** Line fields, read through the parent's list in one request ("`tabSales Order Item`.x"). */
const LINE_FIELDS = [
  'item_code',
  'item_name',
  'qty',
  SALES_ORDER_ITEM_FIELD.rolls,
  SALES_ORDER_ITEM_FIELD.totalWeight,
  'amount',
  SALES_ORDER_ITEM_FIELD.ratePerKg,
  HITECH_ITEM_FIELD.deliveredKg,
  HITECH_ITEM_FIELD.invoicedKg,
  HITECH_ITEM_FIELD.deliveryRefs,
];
const CHILD = '`tabSales Order Item`';

function lineOf(it: Record<string, unknown>): AcctLineInput {
  return {
    item: str(it.item_code),
    item_name: str(it.item_name),
    // `custom_rolls` where the phone filled it; `qty` is rolls on this site too.
    rolls: num(it[SALES_ORDER_ITEM_FIELD.rolls]) || num(it.qty),
    ordered_kg: num(it[SALES_ORDER_ITEM_FIELD.totalWeight]),
    amount: num(it.amount),
    rate_per_kg: num(it[SALES_ORDER_ITEM_FIELD.ratePerKg]),
    delivered_kg: num(it[HITECH_ITEM_FIELD.deliveredKg]),
    invoiced_kg: num(it[HITECH_ITEM_FIELD.invoicedKg]),
  };
}

/**
 * Every order Hi-Tech has a sales order for, placed in the last `days` days,
 * with its lines and what Hi-Tech delivered against each.
 *
 * Every unit's orders: the sync sends all of them to Hi-Tech on the same
 * inter-company customer, so the real customer is only known here.
 *
 * The lines come in the same request as the orders — Frappe joins the child
 * table when its fields are named — so a year of orders is one read, not one
 * per order. Should the site refuse that, each order is read on its own.
 */
export async function listHitechOrders(days: number): Promise<HitechOrderList> {
  const since = shiftDays(frappeToday(), -days);
  const filters: Filter[] = [
    [SALES_ORDER_FIELD.sapSalesOrder, 'is', 'set'],
    [SALES_ORDER_FIELD.placedOn, '>=', since],
    // A document cancelled in ERPNext is not an order at all.
    ['docstatus', '!=', 2],
  ];

  const byOrder = new Map<string, { head: Record<string, unknown>; lines: { idx: number; it: Record<string, unknown> }[] }>();
  const unreadable: HitechOrderList['unreadable'] = [];

  let joined: Record<string, unknown>[] | null = null;
  try {
    joined = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
      fields: [...HEAD_FIELDS, `${CHILD}.idx as line_idx`, ...LINE_FIELDS.map((f) => `${CHILD}.${f}`)],
      filters,
      orderBy: '`tabSales Order`.transaction_date desc, `tabSales Order`.name desc',
      limit: 0,
    });
    // `listDocs` answers a refused field list with fields=["*"]: parent rows
    // and no lines, which would read as nothing delivered anywhere.
    if (joined.some((r) => !('item_code' in r))) joined = null;
  } catch {
    joined = null;
  }

  if (joined) {
    for (const r of joined) {
      const name = str(r.name);
      const o = byOrder.get(name) ?? { head: r, lines: [] };
      if (str(r.item_code)) o.lines.push({ idx: num(r.line_idx), it: r });
      byOrder.set(name, o);
    }
  } else {
    const heads = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
      fields: HEAD_FIELDS,
      filters,
      orderBy: 'transaction_date desc, name desc',
      limit: 0,
    });
    await pool(heads, ITEM_READS, async (h) => {
      const name = str(h.name);
      try {
        const doc = await getDoc<{ items?: Record<string, unknown>[] }>(DOCTYPE.salesOrder, name);
        byOrder.set(name, { head: h, lines: (doc.items ?? []).map((it, i) => ({ idx: num(it.idx) || i + 1, it })) });
      } catch (e) {
        unreadable.push({ name, message: e instanceof Error ? e.message : 'Could not be read.' });
      }
    });
  }

  const customers = [...new Set([...byOrder.values()].map((o) => str(o.head[SALES_ORDER_FIELD.customer])).filter(Boolean))];
  // The Manna Treads code is a convenience on this screen; without it the orders still show.
  const codeRows = await listDocsIn<Record<string, unknown>>(DOCTYPE.customer, 'name', customers, {
    fields: ['name', BP_CODE],
  }).catch(() => [] as Record<string, unknown>[]);
  const codeOf = new Map(codeRows.map((r) => [str(r.name), str(r[BP_CODE])]));

  const orders: HitechOrderRow[] = [...byOrder.entries()].map(([name, { head: h, lines }]) => {
    const sorted = [...lines].sort((a, b) => a.idx - b.idx).map((l) => l.it);
    const customer = str(h[SALES_ORDER_FIELD.customer]);
    return {
      name,
      customer,
      customerName: str(h[SALES_ORDER_FIELD.customerName]) || customer,
      mtCode: codeOf.get(customer) ?? '',
      rep: str(h[SALES_ORDER_FIELD.rep]),
      unit: str(h[SALES_ORDER_FIELD.unit]),
      transactionDate: str(h[SALES_ORDER_FIELD.placedOn]),
      sapSalesOrder: str(h[SALES_ORDER_FIELD.sapSalesOrder]),
      sapStatus: str(h[SALES_ORDER_FIELD.sapSalesOrderStatus]),
      sapInvoice: str(h[SALES_ORDER_FIELD.sapInvoice]),
      input: {
        sap_sales_order: str(h[SALES_ORDER_FIELD.sapSalesOrder]),
        sap_status: str(h[SALES_ORDER_FIELD.sapSalesOrderStatus]),
        lines: sorted.map(lineOf),
        delivery_refs: sorted.flatMap((it) => splitRefs(it[HITECH_ITEM_FIELD.deliveryRefs])),
      },
    };
  });
  orders.sort(
    (a, b) => b.transactionDate.localeCompare(a.transactionDate) || b.name.localeCompare(a.name),
  );
  return { orders, unreadable };
}

/** One call to the Server Script, at most `MT_REQUEST_MAX` orders; its answer as sent. */
async function requestBatch(names: string[]): Promise<MtRequestOutcome> {
  const { data } = await http.post<{ message: Record<string, unknown> }>(
    '/api/method/manna_mt_so_request',
    new URLSearchParams({ orders: JSON.stringify(names) }),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } },
  );
  const m = data.message ?? {};
  const raw = Array.isArray(m.results) ? (m.results as Record<string, unknown>[]) : [];
  return {
    results: raw.map((r) => ({ order: str(r.order), ok: flag(r.ok), message: str(r.message) })),
    flagRaised: flag(m.flag_raised),
  };
}

/**
 * Ask for these orders to be created in Manna Treads.
 *
 * The Server Script decides, order by order, and says why it refused one. It
 * throws for more than 50 at once, so a long selection goes in batches, one
 * after another; one batch failing does not stop the rest. Never throws: every
 * order comes back sent or not sent, with the reason.
 */
export function requestMannaTreadsOrders(names: string[]): Promise<MtRequestOutcome> {
  return requestInBatches(names, requestBatch);
}

/**
 * Where the office sync has got to with these orders — the Manna Treads
 * fields alone, so following a request is one small read, not a reload.
 */
export async function readMannaTreadsProgress(names: string[]): Promise<MtProgress[]> {
  const rows = await listDocsIn<Record<string, unknown>>(DOCTYPE.salesOrder, 'name', names, {
    fields: ['name', MT_FIELD.salesOrder, MT_FIELD.salesOrderEntry, MT_FIELD.requested, MT_FIELD.syncError],
  });
  return rows.map((r) => ({
    order: str(r.name),
    mt_sales_order: str(r[MT_FIELD.salesOrder]) || str(r[MT_FIELD.salesOrderEntry]),
    mt_requested: flag(r[MT_FIELD.requested]),
    mt_error: str(r[MT_FIELD.syncError]),
  }));
}
