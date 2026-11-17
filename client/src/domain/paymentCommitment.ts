/**
 * The 10-day payment commitment ladder on an order (17 Nov 2026).
 *
 * An order whose customer is overdue more than 30 days past their payment
 * terms, or which takes them past their credit limit, needs a credit decision.
 * The Manager approves it only with a payment commitment of at most 10 days
 * (over the limit only within their authority). A customer who missed a
 * commitment goes to the GM, bypassing the Manager, until what was overdue is
 * cleared; the GM may give another 10 days or reject. Everything is recorded in
 * ERPNext (Manna Payment Commitment); SAP gets only approved orders.
 *
 * **Paired with `app/lib/core/payment_commitment.dart`**; both read
 * `shared/fixtures/payment_commitment.json`, and the manna_payment_commitment
 * Server Scripts enforce it. Errors fall toward the GM: an unreadable figure
 * never lets an order skip a decision it needs.
 */
import { agingOf, OVERDUE_TOLERANCE, overdueDaysOf, overduePastTerms, type CustomerRow } from './credit';

export const PC_MAX_DAYS = 10;
/** Overdue past terms by MORE than this many days needs a commitment. */
export const PC_OVERDUE_DAYS = 30;

export const PC = {
  running: 'Running',
  unchecked: 'Unchecked',
  kept: 'Kept',
  missed: 'Missed',
  cancelled: 'Cancelled',
} as const;

/** What the Manager and GM dashboards call an order. */
export const ORDER_STAGE = {
  manager: 'Pending Manager Approval',
  gm: 'Sent to GM',
  gmApproved: 'GM Approved',
  rejected: 'Rejected',
  paymentPending: 'Payment Pending',
  pushed: 'SAP Pushed',
  approved: 'Approved',
} as const;

const round2 = (v: number) => Math.round(v * 100) / 100;

export interface PcNeeds {
  /** Overdue past terms, and the oldest more than 30 days late. */
  overdue30: boolean;
  overLimit: boolean;
  /** Outstanding + this order beyond the limit; 0 when within it. */
  excess: number;
  needs: boolean;
}

export function pcNeeds(customer: CustomerRow, orderTotal: number): PcNeeds {
  const a = agingOf(customer);
  const overdue30 = overduePastTerms(customer) > OVERDUE_TOLERANCE && overdueDaysOf(customer) > PC_OVERDUE_DAYS;
  const overLimit = a.creditLimit > 0 && a.total + orderTotal > a.creditLimit;
  const excess = overLimit ? round2(a.total + orderTotal - a.creditLimit) : 0;
  return { overdue30, overLimit, excess, needs: overdue30 || overLimit };
}

export type PcRoute = 'manager' | 'manager_commitment' | 'gm';

/** Where an order waiting for approval goes. */
export function pcRoute(a: {
  needs: boolean;
  overLimit: boolean;
  excess: number;
  authority: number;
  gmLock: boolean;
  capReached: boolean;
}): PcRoute {
  if (a.gmLock) return 'gm';
  if (!a.needs) return 'manager';
  if (a.overLimit && !(a.authority > 0 && a.excess <= a.authority)) return 'gm';
  if (a.capReached) return 'gm';
  return 'manager_commitment';
}

/** A missed commitment not yet cleared sends the customer's orders to the GM. */
export function pcGmLock(commitments: { status: string; cleared_on?: string | null }[]): boolean {
  return commitments.some((c) => c.status === PC.missed && !String(c.cleared_on ?? '').trim());
}

const dayNo = (s: string): number | null => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s ?? '');
  return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86_400_000 : null;
};

export type PcProblem = 'date_past' | 'too_long' | 'remarks';

export const PC_MESSAGES: Record<PcProblem, string> = {
  date_past: 'Choose a payment commitment date from today on.',
  too_long: 'A payment commitment may be at most 10 days.',
  remarks: 'Enter your remarks.',
};

/** Manager or GM: a date within 10 calendar days of the approval, and remarks. */
export function pcCheckApproval(a: { approvedOn: string; commitment: string; remarks: string }): PcProblem | null {
  const d0 = dayNo(a.approvedOn);
  const c = dayNo(a.commitment);
  if (d0 === null || c === null || c < d0) return 'date_past';
  if (c - d0 > PC_MAX_DAYS) return 'too_long';
  if (!a.remarks.trim()) return 'remarks';
  return null;
}

export type PcTrack = 'kept' | 'running' | 'missed' | 'missed_cleared' | 'unchecked' | 'none';

/**
 * What the latest synced SAP figures say about a commitment. Kept when nothing
 * is overdue on figures synced after the approval, by the end of the
 * commitment day; missed only on figures synced after that day - never on
 * stale ones ('unchecked'). Paid after the day: missed, but cleared.
 */
export function pcTrack(a: {
  status: string;
  approvedOn: string;
  commitment: string;
  today: string;
  overdueNow: number;
  syncedAt: string;
}): PcTrack {
  if (a.status !== PC.running && a.status !== PC.unchecked) return 'none';
  const synced = (a.syncedAt ?? '').slice(0, 19);
  const fresh = synced !== '' && synced > (a.approvedOn ?? '').slice(0, 19);
  const syncedDay = synced.slice(0, 10);
  const commitment = (a.commitment ?? '').slice(0, 10);
  const clear = a.overdueNow <= OVERDUE_TOLERANCE;
  if (fresh && clear && syncedDay <= commitment) return 'kept';
  if (a.today.slice(0, 10) <= commitment) return 'running';
  if (fresh && syncedDay > commitment) return clear ? 'missed_cleared' : 'missed';
  return 'unchecked';
}

/** The stage an order shows on the Manager's and GM's lists. */
export function pcOrderStage(a: { poStatus: string; pushed: boolean; commitment: string }): string {
  switch ((a.poStatus ?? '').trim()) {
    case 'Rejected':
      return ORDER_STAGE.rejected;
    case 'Pending GM Approval':
      return ORDER_STAGE.gm;
    case 'Pending Final Approval':
      return ORDER_STAGE.gmApproved;
    case 'PO Approved - Ready for SAP':
      if (a.commitment === PC.running || a.commitment === PC.unchecked) return ORDER_STAGE.paymentPending;
      return a.pushed ? ORDER_STAGE.pushed : ORDER_STAGE.approved;
    default:
      return ORDER_STAGE.manager;
  }
}
