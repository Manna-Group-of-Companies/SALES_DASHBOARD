/**
 * What an order's stored status *means*, and how it is said out loud.
 *
 * Two vocabularies exist and they are not the same. ERPNext stores
 * `custom_po_status` in the language of a purchase order — "PO Approved -
 * Ready for SAP" — and nobody in this business scans a PO or logs into SAP.
 * Every screen shows the rep-facing label; the stored string only ever appears
 * in a tooltip, for someone debugging.
 *
 * The mapping lives here so the order list, the review screen and the
 * production board cannot describe the same order differently.
 */

import type { OrderLine } from './types';

// ------------------------------------------------------- approval status ---

/** The eight values `Sales Order.custom_po_status` accepts. */
export const PO_STATUS = {
  none: 'No PO Yet',
  pending: 'Pending Approval',
  pendingRate: 'Pending Rate Approval',
  poUploaded: 'PO Uploaded - Pending Approval',
  pendingGm: 'Pending GM Approval',
  /**
   * The GM has approved the credit and the order is back with the sales
   * manager, who pushes it to SAP. The Select carried this option unused until
   * 24 Sep 2026, when the GM stopped pushing to SAP themselves — see
   * `shared/fixtures/credit_commitment.json`. Shown as "Approved by GM".
   */
  finalApproval: 'Pending Final Approval',
  approved: 'PO Approved - Ready for SAP',
  rejected: 'Rejected',
} as const;

export type StatusTone = 'ok' | 'warn' | 'danger';

/** The uppercase pill text and its colour, for any stored status. */
export function statusPill(status: string | undefined | null): {
  text: string;
  tone: StatusTone;
} {
  switch ((status ?? '').trim()) {
    case PO_STATUS.approved:
      return { text: 'APPROVED', tone: 'ok' };
    case PO_STATUS.pending:
    case PO_STATUS.poUploaded:
      return { text: 'WAITING FOR MANAGER APPROVAL', tone: 'warn' };
    case PO_STATUS.pendingRate:
      return { text: 'WAITING FOR RATE APPROVAL', tone: 'warn' };
    case PO_STATUS.pendingGm:
      return { text: 'ESCALATED TO GM', tone: 'warn' };
    // Amber, not green: the GM has decided the credit, but the order is not
    // in SAP until the sales manager pushes it, and a green pill reads as done.
    case PO_STATUS.finalApproval:
      return { text: 'APPROVED BY GM', tone: 'warn' };
    case PO_STATUS.rejected:
      return { text: 'REJECTED', tone: 'danger' };
    // `No PO Yet`, empty and null all mean the same thing to a manager: it has
    // not been sent to them. An unrecognised value lands here too, which reads
    // as "needs attention" rather than quietly as approved.
    default:
      return { text: 'NOT SENT FOR APPROVAL', tone: 'warn' };
  }
}

export function isApproved(status: string | undefined | null): boolean {
  return (status ?? '').trim() === PO_STATUS.approved;
}

/** What the lines editor says when escalation, not the clock, shuts it. */
export const EDIT_LOCK = {
  withGm: 'This order is with the general manager. Only they can change it now.',
  gmApproved:
    'The general manager approved this order as it stands, so it can no longer be changed. ' +
    'The sales manager pushes it to SAP, or the general manager rejects it.',
} as const;

/**
 * Whether an order at `status` may be changed by `role` — `rep`,
 * `sales_manager` or `general_manager` — as far as its approval goes.
 *
 * Decided 26 Sep 2026 (`order_locked_after_approval.json`, `by_role`), and
 * paired with `statusAllowsEdit` in `app/lib/core/order_rules.dart`. Rates
 * come from SAP, so what is left to change is quantities, items and the
 * delivery date, and those stop at the decision that settles the order:
 *  - undecided (and Rejected, which the rep is meant to fix): all three;
 *  - escalated to the GM: the GM only — they may trim it before deciding;
 *  - approved by the GM, or approved and pushed to SAP: nobody.
 * Any other role is refused, as `orderActions` refuses it. Nothing else sits on
 * top: the 1 pm delivery-day cutoff was dropped on 11 Oct 2026, so the status
 * alone decides.
 */
export function statusAllowsEdit(
  status: string | undefined | null,
  role: string | undefined | null,
): boolean {
  if (role !== 'rep' && role !== 'sales_manager' && role !== 'general_manager') return false;
  switch ((status ?? '').trim()) {
    case PO_STATUS.approved:
    case PO_STATUS.finalApproval:
      return false;
    case PO_STATUS.pendingGm:
      return role === 'general_manager';
    default:
      return true;
  }
}

/**
 * Why `role` may not change an order at `status` because of where it is in
 * escalation, or null when escalation is not what stops them. Approval to SAP
 * has its own, longer sentence, which names the SAP order.
 */
export function escalationLockReason(
  status: string | undefined | null,
  role: string | undefined | null,
): string | null {
  const s = (status ?? '').trim();
  if (s === PO_STATUS.finalApproval) return EDIT_LOCK.gmApproved;
  if (s === PO_STATUS.pendingGm && !statusAllowsEdit(s, role)) return EDIT_LOCK.withGm;
  return null;
}

/**
 * What someone who may still change the order is told about when that stops.
 * It is a decision, not a date: the 1 pm delivery-day cutoff was dropped on
 * 11 Oct 2026. Only shown where `statusAllowsEdit` said yes, so an order with
 * the GM is being read by the GM.
 */
export function editOpenNote(status: string | undefined | null): string {
  if ((status ?? '').trim() === PO_STATUS.pendingGm) {
    return 'With you · only you can change it until you approve or reject it';
  }
  return 'Editable until the sales manager approves it or sends it to the GM';
}

/**
 * Whether this order still owes the manager a decision.
 *
 * Anything that is not approved counts, including `Rejected` — a rejected
 * order is one the rep will resubmit, and the handoff's header count is
 * "waiting on you" against the approved state, not against a list of pending
 * strings that would need extending every time a status is added.
 */
export function awaitingManager(status: string | undefined | null): boolean {
  return !isApproved(status);
}

// ------------------------------------------------ lead order status ---

/**
 * The six values `Lead Order.status` accepts — read off the live doctype.
 *
 * Note what is **absent**: there is no `Pending GM Approval`. A lead order
 * therefore cannot be escalated the way a Sales Order can, and writing that
 * string would be rejected by Frappe outright. See `canEscalateLeadOrder`.
 */
export const LEAD_ORDER_STATUS = {
  pending: 'Pending Approval',
  approved: 'Approved',
  rejected: 'Rejected',
  poUploaded: 'PO Uploaded',
  poApproved: 'PO Approved - Ready for SAP',
  converted: 'Converted',
} as const;

export const LEAD_ORDER_STATUS_VALUES: string[] = Object.values(LEAD_ORDER_STATUS);

/**
 * A lead order cannot be escalated to the GM: the Select has no such option.
 * Rather than write a value Frappe will refuse, the screen hides the control
 * and says why.
 */
export function canEscalateLeadOrder(): boolean {
  return LEAD_ORDER_STATUS_VALUES.includes('Pending GM Approval');
}

/** Lead order statuses that read as decided. */
export function leadOrderApproved(status: string | undefined | null): boolean {
  const s = (status ?? '').trim();
  return (
    s === LEAD_ORDER_STATUS.approved ||
    s === LEAD_ORDER_STATUS.poApproved ||
    s === LEAD_ORDER_STATUS.converted
  );
}

// ---------------------------------------------------- production status ---

/**
 * The **only** four values `custom_production_status` accepts.
 *
 * It is a Select. Writing a fine stage name like "Curing" into it is rejected
 * and takes the whole update down with it, including the line stage that was
 * the point of the save.
 */
export const PRODUCTION_STATUS = {
  notStarted: 'Not Started',
  inProduction: 'In Production',
  ready: 'Ready',
  dispatched: 'Dispatched',
} as const;

export type ProductionStatus = (typeof PRODUCTION_STATUS)[keyof typeof PRODUCTION_STATUS];

export const PRODUCTION_STATUS_VALUES: string[] = Object.values(PRODUCTION_STATUS);

/** True only for the exact stored string. */
export function isDispatched(status: string | undefined | null): boolean {
  return (status ?? '').trim() === PRODUCTION_STATUS.dispatched;
}

// ------------------------------------------------------ completion tick ---

export type TickState = 'complete' | 'in_sap' | 'ready' | 'in_production' | 'not_started';

/**
 * The completion tick, **derived and never stored**.
 *
 * There is deliberately no `custom_order_complete` field: a stored flag is one
 * more thing that can disagree with the floor — ticked on an order still being
 * made, or left unticked on one long gone.
 *
 * It names the state rather than just ticking or not. "Ready" and "In
 * Production" are both "not complete", and someone chasing an order needs to
 * know which of the two they are chasing.
 */
export function tickState(productionStatus: string | undefined | null): TickState {
  switch ((productionStatus ?? '').trim()) {
    case PRODUCTION_STATUS.dispatched:
      return 'complete';
    // What `orderProgress` reads once SAP has the order and it is not yet
    // invoiced. Named, not rounded down: an order SAP has taken is not "Not
    // Started" to the manager chasing it.
    case 'Pushed to SAP':
      return 'in_sap';
    case PRODUCTION_STATUS.ready:
      return 'ready';
    case PRODUCTION_STATUS.inProduction:
      return 'in_production';
    default:
      return 'not_started';
  }
}

export const TICK_LABEL: Record<TickState, string> = {
  complete: 'Complete',
  in_sap: 'Pushed to SAP',
  ready: 'Ready',
  in_production: 'In Production',
  not_started: 'Not Started',
};

// ------------------------------------------------------- production line ---

/**
 * The production line under an order row, or null when there should be none.
 *
 * Returns null before approval: production has never seen the order, so any
 * sentence about its progress would be invented.
 *
 * A finished order is said plainly — "Order complete — dispatched". Everything
 * short of finished keeps its stage name, because "not complete" is nothing to
 * chase with, and "Production: Dispatched" buries the one fact that ends the
 * chase.
 */
export function productionLine(order: {
  poStatus?: string | null;
  productionStatus?: string | null;
  productionFinishDate?: string | null;
}): { text: string; done: boolean } | null {
  if (!isApproved(order.poStatus)) return null;
  if (isDispatched(order.productionStatus)) {
    return { text: 'Order complete — dispatched', done: true };
  }
  const stage = (order.productionStatus ?? '').trim() || 'Not started';
  const est = order.productionFinishDate ? ` · est. finish ${order.productionFinishDate}` : '';
  return { text: `Production: ${stage}${est}`, done: false };
}

// --------------------------------------------------------------- link-ish ---

/**
 * Whether a Frappe Link actually holds something.
 *
 * An unset Link reads back as `null` on one path and `''` on another, and the
 * literal string `'null'` arrives from naive interpolation somewhere upstream.
 * All three mean "not set" and all three must be checked, everywhere.
 */
export function isSet(v: string | null | undefined): boolean {
  const s = (v ?? '').trim();
  return s !== '' && s !== 'null' && s !== 'undefined';
}

/** Lines that have been approved at least once, for the "priced & locked" count. */
export function lockedLines(lines: OrderLine[]): OrderLine[] {
  return lines.filter((l) => l.rateApproved);
}

// ----------------------------------------------------------- escalation ---

/**
 * Whether approving this order sends it to the GM instead of finalising it.
 *
 * The trigger is the **customer's** credit limit, not the rep's outstanding
 * balance. The rep trigger asked a different question — how much a salesperson
 * was carrying, rather than how much this party can owe — and was dormant in
 * any case.
 *
 * A **lead never escalates**: no limit and no trading history means the GM
 * would be deciding on nothing.
 */
export function escalates(input: {
  outstanding?: number;
  creditLimit?: number;
  orderTotal: number;
  isLead?: boolean;
}): boolean {
  if (input.isLead) return false;
  const limit = input.creditLimit ?? 0;
  if (limit <= 0) return false;
  return (input.outstanding ?? 0) + input.orderTotal > limit;
}

/** The credit picture the GM queue is built around. */
export interface CreditPicture {
  outstanding: number;
  orderTotal: number;
  projected: number;
  creditLimit: number;
  over: number;
}

export function creditPicture(input: {
  outstanding?: number;
  creditLimit?: number;
  orderTotal: number;
}): CreditPicture {
  const outstanding = input.outstanding ?? 0;
  const creditLimit = input.creditLimit ?? 0;
  const projected = outstanding + input.orderTotal;
  return {
    outstanding,
    orderTotal: input.orderTotal,
    projected,
    creditLimit,
    over: Math.max(0, projected - creditLimit),
  };
}

// ------------------------------------------------------- GM exemptions ---

/**
 * The GM is exempt from two rules everyone else is bound by: ownership and
 * the rate lock. (The third, the 1 pm delivery-day cutoff, was dropped for
 * everyone on 11 Oct 2026.)
 *
 * Both exist because the GM is who those rules escalate *to*. An
 * escalation arriving with no power to change anything is a rubber stamp.
 *
 * A sales manager must **not** inherit any of them — they are the one whose
 * approval set the lock in the first place.
 */
export function isGeneralManager(role: string | undefined): boolean {
  return role === 'general_manager';
}

/** Only the rep or their manager may edit — the GM may edit anyone's. */
export function boundByOwnership(role: string | undefined): boolean {
  return !isGeneralManager(role);
}

/** A rate locked by approval stays locked — except for the GM. */
export function rateEditable(role: string | undefined, rateApproved: boolean): boolean {
  if (!rateApproved) return true;
  return isGeneralManager(role);
}

/**
 * Whether an order has been signed off, asking the right field for its type.
 *
 * A lead order has no `custom_po_status` — approving one sets `status` to
 * `Approved` and converts the lead — so `isApproved` alone reads every lead
 * order as still open. Anything that must not happen after sign-off has to
 * use this instead, or it silently permits on leads what it forbids on
 * customer orders.
 *
 * **No GM exemption, deliberately.** This is not `rateEditable`. The phone
 * refuses a discount change on a signed-off order to everybody, the GM
 * included (`orderSignedOff` in `app/lib/core/order_rules.dart`), and a rule
 * that lets a signed price move from a desk but not from a counter is worse
 * than either rule on its own. Settled 13 Aug 2026 in favour of the phone; the
 * cases are in `shared/fixtures/discount.json`.
 */
export function orderSignedOff(
  order: { poStatus?: string; status?: string; ratesApproved?: boolean },
  isLead = false,
): boolean {
  if (order.ratesApproved) return true;
  if (!isLead) return isApproved(order.poStatus);
  const s = (order.status ?? '').trim();
  return s === LEAD_ORDER_STATUS.approved || s === PO_STATUS.approved;
}
