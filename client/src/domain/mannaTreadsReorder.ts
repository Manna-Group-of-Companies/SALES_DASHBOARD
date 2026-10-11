/**
 * Stage two: re-raising a finished Hi-Tech order as a Manna Treads Sales Order
 * to the real end customer (decided by the user, 26 September 2026).
 *
 * Hi-Tech Pretreads makes and delivers every app order and bills Manna Treads
 * as inter-company customer 10118. Manna Treads then has to bill the end
 * customer — for what Hi-Tech actually DELIVERED, which is not always what was
 * ordered. The accountant approves each finished order on the dashboard; the
 * office order sync creates the Manna Treads order in SAP.
 *
 * **Paired with the PowerShell in `sap-order-sync/Sync-SapOrders.ps1`.** Both
 * are pinned by `shared/fixtures/manna_treads_reorder.json`, whose `rules`
 * block is the spec, and both test suites read it. The sync is what writes
 * SAP; this decides what the accountant is shown and offered, so the two must
 * bill the same kilos at the same price or he approves one invoice and SAP
 * raises another.
 *
 * The shapes are the fixture's own, snake_case and all, so the fixture feeds
 * straight in.
 */

/** Manna Treads keys prices net of GST under tax code CG+SG@18. */
export const GST_PERCENT = 18;

/** SAP's own enum values, compared case-blind as `cancelledInSap` does. */
const SAP_CLOSED = 'bost_close';
const SAP_CANCELLED = 'bost_cancelled';

export interface MtLineInput {
  item: string;
  /** `custom_total_weight` — what was ORDERED. Never `qty`, which is rolls. */
  ordered_kg: number;
  /** The approved line amount in ERPNext, GST-inclusive. */
  amount: number;
  rate_per_kg: number;
  /** Kilos on Hi-Tech delivery notes with CancelStatus csNo. */
  delivered_kg: number;
  /** Kilos on Hi-Tech A/R invoice lines drawn straight from the sales order. */
  invoiced_kg: number;
}

export interface MtOrderInput {
  /** Hi-Tech's DocNum. Blank means the order never reached SAP. */
  sap_sales_order: string;
  /** Hi-Tech's status, verbatim: bost_Open / bost_Close / bost_Cancelled. */
  sap_status: string;
  /** `Customer.custom_bp_code` — the MANNA_TREADS_LIVE CardCode. */
  customer_mt_code: string;
  /** The Manna Treads order, once the sync has created it. */
  mt_sales_order: string;
  mt_requested: boolean;
  mt_error: string;
  lines: MtLineInput[];
}

export type MtState =
  | 'not_in_sap'
  | 'created'
  | 'cancelled'
  | 'at_hitech'
  | 'nothing_delivered'
  | 'failed'
  | 'queued'
  | 'blocked'
  | 'ready';

/** What the kilos were read from. See `delivery_wins` in the fixture. */
export type MtBasis = 'delivered' | 'invoiced';

export interface MtBillableLine {
  item: string;
  kg: number;
  /** Per kilo, GST-inclusive — what the manager approved. */
  rate: number;
  amount: number;
  /** What goes on the SAP line as UnitPrice; SAP adds the tax back. */
  unit_price_net: number;
}

export interface MtAssessment {
  state: MtState;
  basis: MtBasis;
  /** Only lines with kilos to bill. Worked out whatever the state. */
  lines: MtBillableLine[];
  total: number;
}

/**
 * Round half away from zero, after taking the binary noise off.
 *
 * 55.555 × 199 is 11055.444999999998 as a double, and a plain Math.round would
 * bill a paisa short of what the same sum does on paper. Fifteen significant
 * figures is below any quantity or price here and above the noise.
 */
export function roundTo(n: number, dp: number): number {
  if (!Number.isFinite(n)) return 0;
  const exact = Number(n.toPrecision(15));
  const abs = Math.abs(exact);
  const text = String(abs);
  const scaled = text.includes('e')
    ? Math.round(abs * 10 ** dp) / 10 ** dp
    : Number(`${Math.round(Number(`${text}e${dp}`))}e-${dp}`);
  return exact < 0 ? -scaled : scaled;
}

const clean = (v: unknown) => String(v ?? '').trim();

/**
 * The approved price per kilo: amount / ordered kilos, so a legacy line whose
 * amount sits below its list rate keeps the price it was approved at. The list
 * rate on the line only when nothing was ordered by weight.
 */
export function approvedRate(line: Pick<MtLineInput, 'ordered_kg' | 'amount' | 'rate_per_kg'>): number {
  const ordered = Number(line.ordered_kg) || 0;
  if (ordered > 0) return roundTo((Number(line.amount) || 0) / ordered, 2);
  return roundTo(Number(line.rate_per_kg) || 0, 2);
}

/** GST-inclusive rate to the UnitPrice Manna Treads keys: 220 → 186.440678. */
export function netOfGst(rate: number): number {
  return roundTo(rate / (1 + GST_PERCENT / 100), 6);
}

/**
 * What Manna Treads bills for this order, and on what basis.
 *
 * Delivery wins: one delivered kilo anywhere puts the whole order on delivered
 * kilos, because Hi-Tech's invoice for a delivered order is drawn from the
 * delivery and counting both would bill the same kilos twice.
 */
export function billableLines(lines: MtLineInput[]): { basis: MtBasis; lines: MtBillableLine[]; total: number } {
  const basis: MtBasis = lines.some((l) => roundTo(Number(l.delivered_kg) || 0, 3) > 0)
    ? 'delivered'
    : 'invoiced';
  const out: MtBillableLine[] = [];
  for (const l of lines) {
    const kg = roundTo(Number(basis === 'delivered' ? l.delivered_kg : l.invoiced_kg) || 0, 3);
    if (kg <= 0) continue;
    const rate = approvedRate(l);
    out.push({
      item: clean(l.item),
      kg,
      rate,
      amount: roundTo(kg * rate, 2),
      unit_price_net: netOfGst(rate),
    });
  }
  const total = roundTo(out.reduce((s, l) => s + l.amount, 0), 2);
  return { basis, lines: out, total };
}

/**
 * The kilos billable so far, on the order's own basis — delivered, or invoiced
 * straight from the sales order when nothing was delivered. Never the two
 * added, for the reason `billableLines` gives.
 */
export function billableKg(a: Pick<MtAssessment, 'lines'>): number {
  return roundTo(a.lines.reduce((s, l) => s + l.kg, 0), 3);
}

/**
 * Where an order stands, in the fixture's precedence — the first that holds.
 *
 * `created` sits second on purpose: a Manna Treads order is a fact in SAP, so
 * nothing Hi-Tech does afterwards may offer it for creation a second time.
 * `failed` and `queued` come before `blocked` because once asked for, the
 * sync's answer is what the accountant needs to see.
 */
export function assessOrder(order: MtOrderInput): MtAssessment {
  const billed = billableLines(order.lines ?? []);
  const status = clean(order.sap_status).toLowerCase();
  const requested = Boolean(order.mt_requested);
  const error = clean(order.mt_error);

  let state: MtState;
  if (!clean(order.sap_sales_order)) state = 'not_in_sap';
  else if (clean(order.mt_sales_order)) state = 'created';
  else if (status === SAP_CANCELLED) state = 'cancelled';
  // Open, or a status the sync has not written yet: it may still be delivered further.
  else if (status !== SAP_CLOSED) state = 'at_hitech';
  else if (billed.lines.length === 0) state = 'nothing_delivered';
  else if (requested && error) state = 'failed';
  else if (requested) state = 'queued';
  else if (!clean(order.customer_mt_code)) state = 'blocked';
  else state = 'ready';

  return { state, ...billed };
}

/** Can the accountant ask for this one — first time, or again after a failure? */
export function mayRequest(state: MtState): boolean {
  return state === 'ready' || state === 'failed';
}

// ------------------------------------------------------------ the view ---

/** The accountant's five filters. `not_in_sap` is not his, and has none. */
export type MtView = 'ready' | 'sent' | 'created' | 'at_hitech' | 'not_billable';

export const MT_VIEWS: MtView[] = ['ready', 'sent', 'created', 'at_hitech', 'not_billable'];

export const MT_VIEW_LABEL: Record<MtView, string> = {
  ready: 'Ready',
  // Sent to the office sync, not to SAP: a queued order has not reached SAP
  // yet, and a refused one usually never did.
  sent: 'Sent',
  created: 'Created',
  at_hitech: 'At Hi-Tech',
  not_billable: 'Not billable',
};

export function viewOf(state: MtState): MtView | null {
  switch (state) {
    case 'ready':
      return 'ready';
    case 'queued':
    case 'failed':
      return 'sent';
    case 'created':
      return 'created';
    case 'at_hitech':
      return 'at_hitech';
    case 'blocked':
    case 'nothing_delivered':
    case 'cancelled':
      return 'not_billable';
    case 'not_in_sap':
      return null;
  }
}

/** Why an order is not billable, in the accountant's words. */
export function notBillableReason(state: MtState): string | null {
  switch (state) {
    case 'blocked':
      return 'Customer has no Manna Treads customer code';
    // What is recorded, not what happened: the office sync may never have
    // measured the order, and that is not the same as Hi-Tech shipping nothing.
    case 'nothing_delivered':
      return 'No delivered or invoiced kilos are recorded for it';
    case 'cancelled':
      return 'Cancelled at Hi-Tech';
    default:
      return null;
  }
}

// -------------------------------------------------------- by customer ---

export interface CustomerGroup<T> {
  /** ERPNext Customer name — the key, since two customers may share a display name. */
  customer: string;
  customerName: string;
  mtCode: string;
  orders: T[];
  total: number;
}

/**
 * The accountant works customer by customer, because each Manna Treads order
 * is one customer's invoice. Groups sort by name; orders keep the order they
 * came in.
 */
export function groupByCustomer<
  T extends { customer: string; customerName: string; mtCode: string; total: number },
>(orders: T[]): CustomerGroup<T>[] {
  const byKey = new Map<string, CustomerGroup<T>>();
  for (const o of orders) {
    const key = clean(o.customer);
    let g = byKey.get(key);
    if (!g) {
      g = {
        customer: key,
        customerName: clean(o.customerName) || key,
        mtCode: clean(o.mtCode),
        orders: [],
        total: 0,
      };
      byKey.set(key, g);
    }
    g.orders.push(o);
    g.total = roundTo(g.total + (Number(o.total) || 0), 2);
  }
  return [...byKey.values()].sort(
    (a, b) => a.customerName.localeCompare(b.customerName) || a.customer.localeCompare(b.customer),
  );
}

// ---------------------------------------------------- asking for them ---

/**
 * `manna_mt_so_request` refuses more than this many at once — it throws before
 * marking any, so an over-long request is not half done, it is not done.
 */
export const MT_REQUEST_MAX = 50;

export interface MtRequestResult {
  order: string;
  ok: boolean;
  message: string;
}

export interface MtRequestOutcome {
  results: MtRequestResult[];
  flagRaised: boolean;
}

/** `items` in runs of at most `size`, in order, each item once. */
export function batchesOf<T>(items: T[], size: number): T[][] {
  const unique = [...new Set(items)];
  const step = Math.max(1, Math.floor(size) || 1);
  const out: T[][] = [];
  for (let i = 0; i < unique.length; i += step) out.push(unique.slice(i, i + step));
  return out;
}

/**
 * Ask for `names` in batches the script accepts, one batch after another.
 *
 * The answer is per order, in the order asked. A batch that fails outright
 * marks each of its orders not sent, with the error, and the next batch still
 * goes; an order a batch's answer does not mention is reported unanswered,
 * never as done.
 */
export async function requestInBatches(
  names: string[],
  send: (batch: string[]) => Promise<MtRequestOutcome>,
  size = MT_REQUEST_MAX,
): Promise<MtRequestOutcome> {
  const results: MtRequestResult[] = [];
  let flagRaised = false;
  for (const batch of batchesOf(names, size)) {
    try {
      const answer = await send(batch);
      const byName = new Map(answer.results.map((r) => [clean(r.order), r]));
      for (const n of batch) {
        const r = byName.get(n);
        results.push(
          r
            ? { order: n, ok: r.ok === true, message: clean(r.message) }
            : { order: n, ok: false, message: 'The server did not answer for this order.' },
        );
      }
      if (answer.flagRaised) flagRaised = true;
    } catch (e: unknown) {
      const message = (e instanceof Error && clean(e.message)) || 'Could not send the request.';
      for (const n of batch) results.push({ order: n, ok: false, message });
    }
  }
  return { results, flagRaised };
}

/** One line for the whole send: "3 sent to the office sync", "2 sent, 1 refused". */
export function requestSummary({ results, flagRaised }: MtRequestOutcome): {
  text: string;
  tone: 'success' | 'warning' | 'critical';
} {
  const sent = results.filter((r) => r.ok).length;
  const refused = results.length - sent;
  const unasked = sent > 0 && !flagRaised;
  let text =
    refused === 0
      ? `${sent} sent to the office sync`
      : sent === 0
        ? `None sent, ${refused} refused`
        : `${sent} sent, ${refused} refused`;
  // Recorded either way; without the flag they wait for the next sync asked for.
  if (unasked) text += '. The office sync was not asked to run: press Sync with SAP';
  const tone = sent === 0 ? 'critical' : refused > 0 || unasked ? 'warning' : 'success';
  return { text, tone };
}

/** An order's Manna Treads fields, as the office sync leaves them. */
export interface MtProgress {
  order: string;
  mt_sales_order: string;
  mt_requested: boolean;
  mt_error: string;
}

/**
 * Has the office sync answered for an order since it was asked for?
 *
 * The request clears the error and sets the flag, so any of these is news:
 * a Manna Treads order (created), an error (failed), or the flag gone.
 */
export function syncAnswered(p: MtProgress): boolean {
  return Boolean(clean(p.mt_sales_order)) || Boolean(clean(p.mt_error)) || !p.mt_requested;
}
