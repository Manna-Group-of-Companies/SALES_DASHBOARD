/**
 * Where an order stands, from first approval to the customer's invoice — read
 * only from fields the apps, the SAP order sync and B1if already write.
 *
 *     Manager Approval → GM Approval → SAP Order Creation
 *                         (escalated     → Pick List Generation → Order Processing
 *                          orders only)
 *
 * Each stage is `done`, `current`, `waiting`, `na` (not applicable) or
 * `unknown`. **Nothing is inferred.** A stage is done only when a field says
 * so; a field that is empty, missing on this site, or could not be read gives
 * `unknown` or `waiting`, never `done`. The managers asked for this on
 * 21 Nov 2026: a guessed status is worse than none.
 *
 * WHICH SAP
 *
 * Two SAP companies can hold an ERPNext order, and the order records each in
 * its own field:
 *   - `custom_mt_sales_order` — Manna Treads SAP (`MANNA_TREADS_LIVE`), the
 *     sales order to the end customer. Written by the sync's PASS M on the
 *     "Manna Treads first" route (3 Nov 2026).
 *   - `custom_sap_sales_order` — Hi-Tech SAP (`HITECH_PRETREADS_LIVE`), the
 *     factory's order. Written by PASS A on the older route, and by PASS H
 *     from B1if's order on the Manna Treads first route.
 * An order on the Manna Treads first route has both once B1if has made
 * Hi-Tech's; it is shown with both. Neither field is derived from the other.
 *
 * PICK LISTS
 *
 * A pick list goes against Hi-Tech's sales order, so it can only be made once
 * `custom_sap_sales_order` is set (`pick_list_page.dart`, 10 Nov 2026). Reps
 * make it on the phone. Production's approval is shown but is not a step:
 * since 9 Nov 2026 the sync no longer reads it, and Hi-Tech's store confirms
 * the list in SAP instead (`Get-PkSkipReason` in `Sync-SapOrders.ps1`).
 *
 * DONE MEANS INVOICED
 *
 * Order Processing is done only on an invoice that covers the whole order:
 * `custom_sap_invoice` (written once every line is invoiced),
 * `custom_mt_invoice` (Manna Treads' invoice to the customer), or
 * B1iF's `custom_sap_order_status = Dispatched` (every line invoiced by Manna
 * Treads). Same rule as `sap_order_state.json`: a delivery is not dispatch.
 *
 * Pinned by `shared/fixtures/order_track.json`.
 */
import { PO_STATUS } from './orderStatus';
import { cancelledInSap } from './sapOrderState';

export type StageKey = 'manager' | 'gm' | 'sap' | 'pick' | 'processing';
export type StageState = 'done' | 'current' | 'waiting' | 'na' | 'unknown';
/** Who the next step waits on. `office` is the office and SAP (the sync, B1if, Hi-Tech's store). */
export type Responsible = 'rep' | 'sales_manager' | 'gm' | 'office';
export type Outcome = 'open' | 'complete' | 'cancelled' | 'rejected';

export const STAGE_LABEL: Record<StageKey, string> = {
  manager: 'Manager Approval',
  gm: 'GM Approval',
  sap: 'SAP Order Creation',
  pick: 'Pick List Generation',
  processing: 'Order Processing',
};

export const STATE_LABEL: Record<StageState, string> = {
  done: 'Done',
  current: 'Current',
  waiting: 'Waiting',
  na: 'Not applicable',
  unknown: 'Not known',
};

export const RESPONSIBLE_LABEL: Record<Responsible, string> = {
  rep: 'Rep',
  sales_manager: 'Sales manager',
  gm: 'GM',
  office: 'Office / SAP',
};

/** One Manna Pick List, as `manna_pick_lists` returns it. */
export interface PickFacts {
  name: string;
  /** `Submitted` or `Cancelled`. */
  status?: string | null;
  /** `Pending` or `Approved`. Shown, never a step — see above. */
  approvalStatus?: string | null;
  pickedOn?: string | null;
  sapPickList?: string | null;
  hitechInvoice?: string | null;
  mtGoodsReceipt?: string | null;
  mtDelivery?: string | null;
  sapError?: string | null;
}

/** Everything the track reads. All of it the order's own fields. */
export interface OrderTrackInput {
  poStatus?: string | null;
  gmApprovedBy?: string | null;
  gmApprovedOn?: string | null;
  /** Manna Treads SAP's DocNum. */
  mtSalesOrder?: string | null;
  mtSyncError?: string | null;
  mtInvoice?: string | null;
  /** Hi-Tech SAP's DocNum. */
  sapSalesOrder?: string | null;
  sapSalesOrderStatus?: string | null;
  /** B1iF's order status: In SAP, Partially Picked, Picked, Partially Dispatched, Dispatched, Cancelled. */
  sapOrderStatus?: string | null;
  sapInvoice?: string | null;
  sapSyncError?: string | null;
  /** The order's pick lists; `null` when they could not be read. */
  pickLists: PickFacts[] | null;
  /** `transaction_date` and `delivery_date`, for when its pick list may be made. */
  placedOn?: string | null;
  deliveryDate?: string | null;
  /** Today on the server's clock, `yyyy-mm-dd`. Without it the window is not applied. */
  today?: string | null;
  /** `Manna App Settings.pick_lists_since`; '' or absent = every order. */
  pickListsSince?: string | null;
}

export interface TrackStage {
  key: StageKey;
  label: string;
  state: StageState;
  note: string;
}

export interface OrderTrack {
  stages: TrackStage[];
  /** DocNums, '' when that SAP does not have the order. */
  sap: { mannaTreads: string; hitech: string };
  /** "Manna Treads SAP SO 588 · Hi-Tech SAP SO 551", or "Not in SAP yet". */
  sapLine: string;
  /** What the order's pick lists say, in one line. */
  pickList: string;
  action: { text: string; who: Responsible | null };
  outcome: Outcome;
  /**
   * SAP has the order but it was never approved: the order sync sent it
   * early (it did on 18 and 23 Nov 2026, from an old copy on the SAP server).
   * The user's rule: nothing reaches SAP before the manager - and the GM,
   * when escalated - approves. Shown as a warning wherever the track is.
   */
  sentBeforeApproval: boolean;
}

const clean = (v: string | null | undefined): string => {
  const s = (v ?? '').trim();
  return s === 'null' || s === 'undefined' ? '' : s;
};

const BEFORE_MANAGER: string[] = [PO_STATUS.pending, PO_STATUS.poUploaded, PO_STATUS.pendingRate];
const NOT_SENT: string[] = [PO_STATUS.none, ''];
const PAST_MANAGER: string[] = [PO_STATUS.pendingGm, PO_STATUS.finalApproval, PO_STATUS.approved];
const KNOWN: string[] = [...BEFORE_MANAGER, ...NOT_SENT, ...PAST_MANAGER, PO_STATUS.rejected];

/** Pick-list status values B1iF writes before an order is fully invoiced. */
const PICKING = ['Partially Picked', 'Picked', 'Partially Dispatched'];

/** `2026-11-19 22:06:36` → `19-11-2026`. Anything else as it came. */
function day(s: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : s;
}

/** How far one submitted list has gone, from its own fields. */
function listProgress(l: PickFacts): string {
  if (clean(l.mtDelivery)) return `Delivered · Manna Treads DN ${clean(l.mtDelivery)}`;
  if (clean(l.mtGoodsReceipt)) return `Manna Treads goods receipt ${clean(l.mtGoodsReceipt)}`;
  if (clean(l.hitechInvoice)) return `Hi-Tech invoice ${clean(l.hitechInvoice)}`;
  if (clean(l.sapError)) return `SAP refused it: ${clean(l.sapError)}`;
  if (clean(l.sapPickList)) return `In SAP · SAP pick list ${clean(l.sapPickList)}`;
  return clean(l.approvalStatus) === 'Approved' ? 'Made · approved by production' : 'Made · not yet in SAP';
}

// ------------------------------------------------- the pick-list window ---

/** Days before delivery a pick list opens. `kPickOpensDaysBefore` on the phone. */
export const PICK_OPENS_DAYS_BEFORE = 2;

/** The first `yyyy-mm-dd` in `v`, or ''. */
const ymd = (v: string | null | undefined): string => /^\d{4}-\d{2}-\d{2}/.exec((v ?? '').trim())?.[0] ?? '';

/**
 * The day an order delivering on `deliveryDate` may first be picked, or null
 * when it has no delivery date (and is not held back). The phone's
 * `pickOpensOn`; the server refuses an earlier list (`manna_pick_list_submit`).
 */
export function pickOpensOn(deliveryDate: string | null | undefined): string | null {
  const d = ymd(deliveryDate);
  if (!d) return null;
  const [y, m, dd] = d.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, dd - PICK_OPENS_DAYS_BEFORE));
  return t.toISOString().slice(0, 10);
}

/** Whether it may be picked on `today`: from `pickOpensOn` onwards, late orders included. */
export function pickIsOpen(deliveryDate: string | null | undefined, today: string): boolean {
  const opens = pickOpensOn(deliveryDate);
  return opens === null || ymd(today) >= opens;
}

/** Whether an order placed on `orderDate` gets a pick list at all. The phone's `pickListIncludes`. */
export function pickListIncludes(orderDate: string | null | undefined, since: string | null | undefined): boolean {
  const s = ymd(since);
  if (!s) return true;
  const d = ymd(orderDate);
  return d !== '' && d >= s;
}

const isSubmitted = (l: PickFacts) => (clean(l.status) || 'Submitted') === 'Submitted';

export function orderTrack(o: OrderTrackInput): OrderTrack {
  const po = clean(o.poStatus);
  const mt = clean(o.mtSalesOrder);
  const ht = clean(o.sapSalesOrder);
  const inSap = !!(mt || ht);
  const b1ifStatus = clean(o.sapOrderStatus);
  const cancelled =
    cancelledInSap({ salesOrderStatus: o.sapSalesOrderStatus }) || b1ifStatus === 'Cancelled';
  const invoiceBits = [
    clean(o.sapInvoice) && `Invoice ${clean(o.sapInvoice)}`,
    clean(o.mtInvoice) && `Manna Treads invoice ${clean(o.mtInvoice)}`,
  ].filter(Boolean) as string[];
  const invoiced = invoiceBits.length > 0 || b1ifStatus === 'Dispatched';
  const gmBy = clean(o.gmApprovedBy);
  const gmOn = clean(o.gmApprovedOn);
  const gmNote = `Approved by ${gmBy || 'the GM'}${gmOn ? ` · ${day(gmOn)}` : ''}`;
  const lists = o.pickLists;
  const submitted = lists ? lists.filter(isSubmitted) : [];
  const hasList = submitted.length > 0;
  const sapError = clean(o.sapSyncError) || clean(o.mtSyncError);
  // Hi-Tech picks orders older than pick_lists_since by hand; a list opens
  // two days before delivery. Both only where the field is known.
  const tooOld = !pickListIncludes(o.placedOn, o.pickListsSince);
  const opensOn = pickOpensOn(o.deliveryDate);
  const notOpenYet = !!ymd(o.today) && opensOn !== null && !pickIsOpen(o.deliveryDate, clean(o.today));

  const sapLine =
    [mt && `Manna Treads SAP SO ${mt}`, ht && `Hi-Tech SAP SO ${ht}`].filter(Boolean).join(' · ') ||
    'Not in SAP yet';

  // SAP already has an order ERPNext still shows as waiting for approval
  // (the order sync sent it early, 18 and 23 Nov 2026). The user's call,
  // 24 Nov 2026: such an order shows its approval steps as passed - SAP is
  // past them, as the GM queue already treats it (19 Nov) - with the red
  // warning and ERPNext's own status kept in the note. Not a rejected one.
  const sentBeforeApproval = inSap && po !== PO_STATUS.approved && !cancelled;
  const early =
    sentBeforeApproval && (BEFORE_MANAGER.includes(po) || NOT_SENT.includes(po) || po === PO_STATUS.pendingGm);
  const erpSays = `ERPNext still says ${po || 'not sent for approval'}`;

  // --- Manager -----------------------------------------------------------
  let manager: [StageState, string];
  if (early && po !== PO_STATUS.pendingGm) {
    manager = ['done', `Passed in SAP · ${erpSays}`];
  } else if (PAST_MANAGER.includes(po)) {
    manager = ['done', po === PO_STATUS.pendingGm || gmBy || po === PO_STATUS.finalApproval ? 'Sent to the GM' : 'Approved'];
  } else if (po === PO_STATUS.rejected) {
    manager = ['current', 'Rejected'];
  } else if (BEFORE_MANAGER.includes(po)) {
    manager = ['current', po === PO_STATUS.pendingRate ? 'Waiting for rate approval' : 'Waiting for the manager'];
  } else if (NOT_SENT.includes(po)) {
    manager = ['current', 'Not sent for approval'];
  } else {
    manager = ['unknown', `Status "${po}" not known`];
  }

  // --- GM ----------------------------------------------------------------
  let gm: [StageState, string];
  if (early && po === PO_STATUS.pendingGm) gm = ['done', `Passed in SAP · ${erpSays}`];
  else if (po === PO_STATUS.pendingGm) gm = ['current', 'Waiting for the GM'];
  else if (po === PO_STATUS.finalApproval || gmBy) gm = ['done', gmNote];
  else if (po === PO_STATUS.rejected || !KNOWN.includes(po)) gm = ['unknown', 'Not known'];
  else if (po === PO_STATUS.approved) gm = ['na', 'No GM approval on record'];
  else gm = ['na', 'Not escalated'];

  // --- SAP order creation ------------------------------------------------
  let sap: [StageState, string];
  if (inSap) {
    sap = ['done', cancelled ? `${sapLine} · Cancelled in SAP` : sentBeforeApproval ? `${sapLine} · sent before approval` : sapLine];
  }
  else if (po === PO_STATUS.approved) sap = ['current', sapError ? 'The SAP sync failed' : 'Waiting for the order sync'];
  else if (!KNOWN.includes(po)) sap = ['unknown', 'Not known'];
  else sap = ['waiting', 'After approval'];

  // --- Pick list ---------------------------------------------------------
  let pickList: string;
  if (lists === null) pickList = 'Not known';
  else if (hasList) pickList = submitted.map((l) => `${l.name} · ${listProgress(l)}`).join('; ');
  else if (lists.length) pickList = `No pick list (${lists.length} cancelled)`;
  else pickList = 'No pick list';

  let pick: [StageState, string];
  if (hasList) pick = ['done', submitted.length === 1 ? submitted[0].name : `${submitted.length} pick lists`];
  else if (cancelled) pick = ['na', 'Order cancelled in SAP'];
  // A pick list needs an approved order (manna_pick_list_submit refuses
  // anything else), even one SAP was sent early.
  else if (po !== PO_STATUS.approved && !invoiced) pick = ['waiting', early ? 'After approval in ERPNext' : 'After approval'];
  else if (lists === null) pick = ['unknown', 'Pick lists could not be read'];
  else if (invoiced) pick = ['na', 'Invoiced without a pick list'];
  // Hi-Tech picks an older-route order by hand in SAP; B1iF still reports it.
  else if (PICKING.includes(b1ifStatus)) pick = ['na', 'Picked in SAP without a pick list'];
  else if (ht && tooOld) pick = ['na', `Only orders from ${day(ymd(o.pickListsSince))} get one`];
  else if (ht && notOpenYet) pick = ['waiting', `Opens on ${day(opensOn!)}`];
  else if (ht) pick = ['current', 'Not made yet'];
  else if (mt) pick = ['waiting', "Needs Hi-Tech's sales order first"];
  else pick = ['waiting', 'After SAP'];

  // --- Order processing --------------------------------------------------
  let processing: [StageState, string];
  if (invoiced) processing = ['done', invoiceBits.join(' · ') || 'Dispatched (SAP)'];
  else if (cancelled) processing = ['na', 'Order cancelled in SAP'];
  else if (hasList || PICKING.includes(b1ifStatus)) {
    processing = ['current', b1ifStatus && b1ifStatus !== 'In SAP' ? `SAP: ${b1ifStatus}` : 'Picking'];
  } else processing = ['waiting', 'After the pick list'];

  // --- Outcome and the next step -----------------------------------------
  let outcome: Outcome = 'open';
  let action: OrderTrack['action'];
  // The oldest submitted list not yet delivered is the one the next step is about.
  const open = [...submitted].reverse().find((l) => !clean(l.mtDelivery));
  if (invoiced) {
    outcome = 'complete';
    action = { who: null, text: 'None — the order is invoiced' };
  } else if (cancelled) {
    outcome = 'cancelled';
    action = { who: null, text: 'None — cancelled in SAP' };
  } else if (po === PO_STATUS.rejected) {
    outcome = 'rejected';
    action = inSap
      ? { who: 'office', text: `Rejected, but ${sapLine} is still open — cancel it in SAP` }
      : { who: 'rep', text: 'Rejected — change the order and send it again' };
  } else if (!KNOWN.includes(po)) {
    action = { who: null, text: 'Not known' };
  } else if (early && !ht) {
    const err = clean(o.mtSyncError);
    action = err
      ? { who: 'office', text: `Hi-Tech's sales order not made: ${err}` }
      : { who: 'office', text: "Waiting for Hi-Tech's sales order (B1if)" };
  } else if (early) {
    // manna_pick_list_submit refuses a list until ERPNext says approved.
    action = {
      who: po === PO_STATUS.pendingGm ? 'gm' : 'sales_manager',
      text: 'Approve it in ERPNext too — the pick list needs that approval',
    };
  } else if (NOT_SENT.includes(po)) {
    action = { who: 'rep', text: 'Send it for approval' };
  } else if (po === PO_STATUS.pendingRate) {
    action = { who: 'sales_manager', text: 'Approve the rates' };
  } else if (BEFORE_MANAGER.includes(po)) {
    action = { who: 'sales_manager', text: 'Approve, reject or send to the GM' };
  } else if (po === PO_STATUS.pendingGm) {
    action = { who: 'gm', text: 'Approve or reject' };
  } else if (po === PO_STATUS.finalApproval) {
    action = { who: 'sales_manager', text: 'Push to SAP (the GM may also push it)' };
  } else if (!inSap) {
    action = sapError
      ? { who: 'office', text: `Fix the SAP sync: ${sapError}` }
      : { who: 'office', text: 'Waiting for the order sync to create it in SAP' };
  } else if (!ht) {
    const err = clean(o.mtSyncError);
    action = err
      ? { who: 'office', text: `Hi-Tech's sales order not made: ${err}` }
      : { who: 'office', text: "Waiting for Hi-Tech's sales order (B1if)" };
  } else if (lists === null) {
    action = { who: null, text: 'Not known — pick lists could not be read' };
  } else if (!hasList && PICKING.includes(b1ifStatus)) {
    action = { who: 'office', text: `SAP: ${b1ifStatus} — waiting for delivery and the invoice` };
  } else if (!hasList && tooOld) {
    action = { who: 'office', text: "Older than pick lists — Hi-Tech picks it in SAP" };
  } else if (!hasList && notOpenYet) {
    action = { who: 'rep', text: `Make the pick list from ${day(opensOn!)} (two days before delivery)` };
  } else if (!hasList) {
    action = { who: 'rep', text: 'Make the pick list' };
  } else if (open && clean(open.sapError)) {
    action = { who: 'office', text: `Pick list ${open.name}: ${clean(open.sapError)}` };
  } else if (open && !clean(open.sapPickList)) {
    action = { who: 'office', text: `Waiting for SAP to take pick list ${open.name}` };
  } else if (open && !clean(open.hitechInvoice)) {
    action = { who: 'office', text: `Hi-Tech's store to confirm SAP pick list ${clean(open.sapPickList)}` };
  } else if (open) {
    action = { who: 'office', text: `Waiting for Manna Treads' delivery for ${open.name}` };
  } else {
    action = { who: 'office', text: 'Delivered — waiting for the customer invoice' };
  }

  const stage = (key: StageKey, [state, note]: [StageState, string]): TrackStage => ({
    key,
    label: STAGE_LABEL[key],
    state,
    note,
  });

  return {
    stages: [
      stage('manager', manager),
      stage('gm', gm),
      stage('sap', sap),
      stage('pick', pick),
      stage('processing', processing),
    ],
    sap: { mannaTreads: mt, hitech: ht },
    sapLine,
    pickList,
    action,
    outcome,
    sentBeforeApproval,
  };
}

/** "Rep (Amjad Pr)", "Sales manager", or '' when nothing waits on anyone. */
export function responsibleText(who: Responsible | null, repName?: string): string {
  if (!who) return '';
  if (who === 'rep' && clean(repName)) return `Rep (${clean(repName)})`;
  return RESPONSIBLE_LABEL[who];
}

/**
 * The orders' pick lists, from one read of `manna_pick_lists`, or `null` for
 * an order whose lists may not be in it.
 *
 * The endpoint returns the newest `limit` lists. When it returned fewer, the
 * read is complete and an order with none really has none. When it returned
 * `limit`, an order not in it may have older ones, so it is `null` — not
 * known — rather than "no pick list".
 */
export function pickListsByOrder<T extends { salesOrder: string }>(
  lists: T[] | null,
  orderIds: string[],
  limit = 200,
): Record<string, T[] | null> {
  const out: Record<string, T[] | null> = {};
  const complete = lists !== null && lists.length < limit;
  for (const id of orderIds) {
    const mine = lists ? lists.filter((l) => l.salesOrder === id) : [];
    out[id] = mine.length ? mine : complete ? [] : null;
  }
  return out;
}
