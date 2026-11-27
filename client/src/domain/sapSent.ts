/**
 * The line every Sales Order shows about SAP, in a list and when opened:
 * whether SAP has it, who approved it, and SAP's order numbers. Asked for by
 * the user on 26 Nov 2026.
 *
 * "Sent to SAP" means SAP has written its number back. Approve & Push only
 * asks the order sync to send the order; until a number comes back the order
 * reads "Waiting for SAP". A push that never landed must not look like one
 * that did.
 *
 * Pinned by `shared/fixtures/sap_sent.json`; the Dart twin is
 * `app/lib/core/sap_sent.dart`.
 */
import { PO_STATUS } from './orderStatus';

export interface SapSentInput {
  poStatus?: string | null;
  gmApprovedBy?: string | null;
  /** Manna Treads SAP's DocNum (`custom_mt_sales_order`). */
  mtSalesOrder?: string | null;
  /** Hi-Tech SAP's DocNum (`custom_sap_sales_order`). */
  sapSalesOrder?: string | null;
  /** B1iF's order status (`custom_sap_order_status`). */
  sapOrderStatus?: string | null;
  /** Hi-Tech's document state (`custom_sap_sales_order_status`), e.g. bost_Open. */
  sapSalesOrderStatus?: string | null;
}

export type SapSentLabel = 'Sent to SAP' | 'Waiting for SAP' | '';
export type ApprovedByLabel = 'GM Approved' | 'Manager Approved' | '';

export interface SapSent {
  sent: boolean;
  label: SapSentLabel;
  approvedBy: ApprovedByLabel;
  /** "Manna Treads SO 591 · Hi-Tech SO 599", or '' when SAP has neither. */
  numbers: string;
  /** Where the order is in SAP - "In SAP", "Partially Dispatched", "Open"... - or ''. */
  status: string;
}

/** Hi-Tech's document states in words. Anything else SAP says is shown as said. */
const DOC_STATE: Record<string, string> = {
  bost_open: 'Open',
  bost_close: 'Closed',
  bost_cancelled: 'Cancelled',
};

/**
 * Where the order is in SAP (the user, 26 Nov 2026). Cancelled first, from
 * either field: it is the terminal fact. Then B1iF's word for the whole order;
 * before B1iF has reported, Hi-Tech's document state; with neither, an order
 * SAP has is In SAP. Fixture: `status` in sap_sent.json.
 */
function sapStatusOf(o: SapSentInput, sent: boolean): string {
  const b1if = clean(o.sapOrderStatus);
  const doc = clean(o.sapSalesOrderStatus);
  const docWord = DOC_STATE[doc.toLowerCase()] ?? doc;
  if (b1if === 'Cancelled' || docWord === 'Cancelled') return 'Cancelled';
  if (b1if) return b1if;
  if (doc) return docWord;
  return sent ? 'In SAP' : '';
}

/** Statuses still waiting on an approver, read as Manager Approved once SAP has the order. */
const WAITING_IN_SAP: string[] = [PO_STATUS.pending, PO_STATUS.poUploaded, PO_STATUS.pendingRate, PO_STATUS.pendingGm];

const clean = (v: string | null | undefined): string => {
  const s = (v ?? '').trim();
  return s === 'null' || s === 'undefined' ? '' : s;
};

export function sapSent(o: SapSentInput): SapSent {
  const po = clean(o.poStatus);
  const mt = clean(o.mtSalesOrder);
  const ht = clean(o.sapSalesOrder);
  const sent = !!(mt || ht);
  const numbers = [mt && `Manna Treads SO ${mt}`, ht && `Hi-Tech SO ${ht}`].filter(Boolean).join(' · ');

  // The GM's stamp survives the manager's push, so a GM-approved order stays
  // GM Approved whoever pressed the push. An order SAP already has while
  // ERPNext still waits for the manager or the GM reads Manager Approved (the
  // user, 27 Nov 2026): it reached SAP, so the manager's approval is taken as
  // given. Pending Final Approval already reads GM Approved on its stage pill.
  let approvedBy: ApprovedByLabel = '';
  if (po === PO_STATUS.approved) approvedBy = clean(o.gmApprovedBy) ? 'GM Approved' : 'Manager Approved';
  else if (sent && WAITING_IN_SAP.includes(po)) approvedBy = 'Manager Approved';

  const label: SapSentLabel = sent ? 'Sent to SAP' : po === PO_STATUS.approved ? 'Waiting for SAP' : '';
  return { sent, label, approvedBy, numbers, status: sapStatusOf(o, sent) };
}

/**
 * Both companies' SAP numbers, '' when SAP has neither: "Manna Treads SO 591 ·
 * Hi-Tech SO 599". Every screen that showed Hi-Tech's number alone shows this
 * instead (the user, 26 Nov 2026: both numbers, everywhere). Display only -
 * what may be picked still asks for Hi-Tech's order in particular.
 */
export function sapNumbersOf(o: { mtSalesOrder?: string | null; sapSalesOrder?: string | null }): string {
  return sapSent(o).numbers;
}

// ------------------------------------------------------------------ news ---

/**
 * Which orders reached SAP since this device last looked. For the sales
 * managers and the GM only (the user, 26 Nov 2026); reps are not told.
 *
 * There is no server push, so this is a diff, like `stageWatch`: `seen` is
 * the orders this device has already shown as in SAP. `null` - never looked -
 * reports nothing and takes the baseline, so a first sign-in is not a flood of
 * last month's orders. `seen` only grows, so an order that leaves the window
 * read and comes back is not news twice. Fixture: `news` in sap_sent.json.
 */
export function sapSentNews<T extends SapSentInput & { id: string }>(
  seen: string[] | null,
  orders: T[],
): { news: T[]; seen: string[] } {
  const sent = orders.filter((o) => sapSent(o).sent);
  const known = new Set(seen ?? []);
  const news = seen === null ? [] : sent.filter((o) => !known.has(o.id));
  const next = [...(seen ?? [])];
  for (const o of sent) if (!known.has(o.id)) next.push(o.id);
  return { news, seen: next };
}

/** "Sent to SAP · Manna Treads SO 591 · GM Approved", for one news line. */
export function sapSentHeadline(o: SapSentInput): string {
  const s = sapSent(o);
  return [s.label, s.numbers, s.approvedBy].filter(Boolean).join(' · ');
}
