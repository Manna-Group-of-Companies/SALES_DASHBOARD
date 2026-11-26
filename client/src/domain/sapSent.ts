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
}

export type SapSentLabel = 'Sent to SAP' | 'Waiting for SAP' | '';
export type ApprovedByLabel = 'GM Approved' | 'Manager Approved' | '';

export interface SapSent {
  sent: boolean;
  label: SapSentLabel;
  approvedBy: ApprovedByLabel;
  /** "Manna Treads SO 591 · Hi-Tech SO 599", or '' when SAP has neither. */
  numbers: string;
}

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
  // GM Approved whoever pressed the push. No other status claims an approver:
  // an order the sync sent early was approved by nobody, and Pending Final
  // Approval already reads GM Approved on its stage pill.
  let approvedBy: ApprovedByLabel = '';
  if (po === PO_STATUS.approved) approvedBy = clean(o.gmApprovedBy) ? 'GM Approved' : 'Manager Approved';

  const label: SapSentLabel = sent ? 'Sent to SAP' : po === PO_STATUS.approved ? 'Waiting for SAP' : '';
  return { sent, label, approvedBy, numbers };
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
