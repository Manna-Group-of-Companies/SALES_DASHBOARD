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

/** The seven values `Sales Order.custom_po_status` accepts. */
export const PO_STATUS = {
  none: 'No PO Yet',
  pending: 'Pending Approval',
  pendingRate: 'Pending Rate Approval',
  poUploaded: 'PO Uploaded - Pending Approval',
  pendingGm: 'Pending GM Approval',
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

export type TickState = 'complete' | 'ready' | 'in_production' | 'not_started';

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
 * The GM is exempt from three rules everyone else is bound by.
 *
 * All three exist because the GM is who those rules escalate *to*. An
 * escalation arriving with no power to change anything is a rubber stamp.
 *
 * A sales manager must **not** inherit any of them — they are the one whose
 * approval set the lock in the first place.
 */
export function isGeneralManager(role: string | undefined): boolean {
  return role === 'general_manager';
}

/** The 13:00 deadline binds everyone except the GM. */
export function boundByCutoff(role: string | undefined): boolean {
  return !isGeneralManager(role);
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
