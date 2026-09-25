/**
 * The rep's commitment on an over-limit order, and who may decide one.
 *
 * An order that takes a customer past their credit limit used to reach the GM
 * carrying nothing but a number. The reason the rep thought it worth taking —
 * "cheque for 50,000 on Friday" — lived in a phone call, and the condition the
 * GM attached was the GM's guess at what the customer had offered. Since
 * 24 September 2026 the rep writes it down when raising the order, the sales
 * manager reads it and can only pass the order on, both managers may comment,
 * and the GM's approval turns it into the rep's credit condition.
 *
 * **The GM approves the credit; the sales manager pushes to SAP.** Asked for
 * the same day, second pass: the GM's approval moves the order to
 * `Pending Final Approval` ("Approved by GM") and back to the sales manager,
 * whose Push to SAP is what writes `PO Approved - Ready for SAP`. The GM never
 * holds `approve` below, on any status.
 *
 * **Paired with `app/lib/core/credit_commitment.dart`.** Both are pinned by
 * `shared/fixtures/credit_commitment.json`, which both test suites read. The
 * phone raises most of these orders and the dashboard decides most of them;
 * a rule that held on one and not the other would not be a rule.
 */

import { overCreditLimit, type CustomerRow } from './credit';
import { PO_STATUS } from './orderStatus';

/**
 * The shortest commitment accepted.
 *
 * Low on purpose: the rep is standing at a counter. It exists to stop "ok",
 * not to make anyone write an essay.
 */
export const COMMITMENT_MIN_LENGTH = 10;

/** How far out a condition falls due when the rep named no date. */
export const CONDITION_DEFAULT_DAYS = 15;

export const COMMITMENT_MISSING =
  'Write what the customer has committed to. This order takes them past their credit limit, and the general manager decides it on your word.';
export const COMMITMENT_TOO_SHORT =
  'Say what the customer has committed to, and by when. A word or two is not something anyone can be held to.';
export const CONDITION_REQUIRED =
  "This order came with the rep's commitment, so approving it makes that their condition. Keep the words or change them, but do not leave them empty.";
export const COMMENT_EMPTY = 'Write the comment first.';
export const SALES_MANAGER_CANNOT_APPROVE =
  'This order takes the customer past their credit limit, so only the general manager can approve it. Send it to the GM instead.';
export const GM_DOES_NOT_PUSH =
  'The general manager approves the credit; the sales manager pushes the order to SAP.';

/** Frappe reads an unset text field back as null, '' or the string 'null'. */
function clean(v: string | null | undefined): string {
  const s = (v ?? '').trim();
  return s === 'null' ? '' : s;
}

/** Whether the order carries a commitment at all. */
export function hasCommitment(text: string | null | undefined): boolean {
  return clean(text) !== '';
}

/**
 * Whether the rep must write one before the order may be sent.
 *
 * Exactly when the order will escalate, and by the same test — credit.json's
 * `overCreditLimit`. Anything looser and an order could reach the GM with
 * nothing to weigh; anything tighter and reps are asked for a promise on
 * orders nobody will ever question, and learn to type anything into the box.
 */
export function commitmentRequired(
  customer: CustomerRow,
  orderTotal: number,
  isLead = false,
): boolean {
  if (isLead) return false;
  return overCreditLimit(customer, orderTotal);
}

/** What is wrong with the rep's text, or null when it will do. */
export function commitmentProblem(text: string | null | undefined): string | null {
  const s = clean(text);
  if (!s) return COMMITMENT_MISSING;
  if (s.length < COMMITMENT_MIN_LENGTH) return COMMITMENT_TOO_SHORT;
  return null;
}

export interface OrderActions {
  /** Approve to SAP — the sales manager's push. The GM never has it. */
  approve: boolean;
  /** The GM's approval of the credit, which sends the order back to the sales manager. */
  gmApprove: boolean;
  /** Send to the general manager. */
  escalate: boolean;
  reject: boolean;
  /** Add a comment to the commitment thread. */
  comment: boolean;
}

const NONE: OrderActions = {
  approve: false,
  gmApprove: false,
  escalate: false,
  reject: false,
  comment: false,
};

/**
 * What `role` may do to an order at `poStatus`.
 *
 * The sales manager never approves an over-limit order to SAP until the GM
 * has approved its credit — before that the only ways forward are Send to GM
 * or Reject, and while it is with the GM they no longer decide it at all,
 * though they may still add what they know. Once the GM has approved, their
 * one move is Push to SAP: refusing what the GM approved is the GM's call.
 *
 * The GM approves the credit on anything not yet decided — including an order
 * they trimmed back inside the limit, since it was escalated to them — and
 * never pushes to SAP. Until the sales manager pushes, the GM may still
 * withdraw their approval by rejecting.
 *
 * An unrecognised role is refused everything. The screen asks this, and so
 * does `Api.sales.decideOrder`, because this site has no Server Script behind
 * either.
 */
export function orderActions(
  role: string | undefined,
  poStatus: string | undefined | null,
  overLimit: boolean,
): OrderActions {
  const s = (poStatus ?? '').trim();
  if (s === PO_STATUS.approved) return NONE;

  const isGm = role === 'general_manager';
  const isSm = role === 'sales_manager';
  if (!isGm && !isSm) return NONE;

  const gmApproved = s === PO_STATUS.finalApproval;

  /*
   * A rejected order may be decided again but not rejected twice. The phone
   * has no Undo — deciding it again is its only way back — and the dashboard
   * draws Undo instead of these buttons, which is a screen choice rather than
   * a rule. Over the limit, it still only goes to the GM.
   */
  const reject = s !== PO_STATUS.rejected;

  if (isGm) {
    return { ...NONE, gmApprove: !gmApproved, reject, comment: true };
  }

  if (gmApproved) return { ...NONE, approve: true, comment: true };
  if (s === PO_STATUS.pendingGm) return { ...NONE, comment: true };
  return { ...NONE, approve: !overLimit, escalate: overLimit, reject, comment: true };
}

/** Whether approving this order must create the rep's credit condition. */
export function conditionRequiredOnApproval(commitment: string | null | undefined): boolean {
  return hasCommitment(commitment);
}

/**
 * What is wrong with the GM's condition text at approval, or null.
 *
 * With a commitment on the order the condition is required — the rep promised
 * it and the customer was told it, so the GM may reword it but not drop it.
 * Without one, the old rule stands and the condition is optional.
 */
export function approvalConditionProblem(
  commitment: string | null | undefined,
  condition: string | null | undefined,
): string | null {
  if (!conditionRequiredOnApproval(commitment)) return null;
  return clean(condition) ? null : CONDITION_REQUIRED;
}

function isoLocal(d: Date): string {
  // Built from the local date, never `toISOString()`: at IST midnight that is
  // still the previous day in UTC, and the condition would fall due a day early.
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

/**
 * The due date the GM starts from.
 *
 * The rep's date is what the customer promised, so it leads. No date, or one
 * already gone by — which would make the condition overdue the moment it was
 * made — falls back to fifteen days, which is what the GM has always been
 * offered.
 */
export function defaultConditionDue(
  commitmentDue: string | null | undefined,
  today: Date,
): string {
  const t = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const raw = clean(commitmentDue).slice(0, 10);
  if (raw) {
    const d = new Date(`${raw}T00:00:00`);
    if (!Number.isNaN(d.getTime()) && d.getTime() >= t.getTime()) return raw;
  }
  const f = new Date(t);
  f.setDate(f.getDate() + CONDITION_DEFAULT_DAYS);
  return isoLocal(f);
}

// ------------------------------------------------------------- follow-up ---

/**
 * The name a comment is filed under, or null for a role that writes none.
 *
 * `Manna Credit Comment.author_role` is a Select of exactly these three. The
 * rep's is new on 25 Sep 2026: their answer to a condition is kept on the
 * order as well as on the condition, so every answer survives a later one.
 */
export function commentAuthorRole(role: string | undefined): string | null {
  switch (role) {
    case 'rep':
      return 'Sales Rep';
    case 'sales_manager':
      return 'Sales Manager';
    case 'general_manager':
      return 'General Manager';
    default:
      return null;
  }
}

/**
 * Whether `role` may add a follow-up note to an order they approved.
 *
 * The GM alone, at any stage — the sales manager's comments close at the
 * push, and the rep's voice is the answer on the condition.
 */
export function mayAddFollowUpNote(role: string | undefined): boolean {
  return role === 'general_manager';
}
