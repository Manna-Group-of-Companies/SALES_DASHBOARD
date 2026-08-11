/**
 * Who decides what, on leave and on attendance regularizations.
 *
 * The two flows are deliberately different, and conflating them is the mistake
 * this module exists to prevent:
 *
 * **Leave — two independent approvals.** The team manager and HR each decide
 * for themselves, in any order. Neither is a precondition for the other, and
 * the leave is granted only once both have said yes. A single rejection ends
 * it regardless of what the other party thought.
 *
 * **Regularization — one approval, routed by who asked.** An ordinary rep's
 * correction is entirely their manager's business; HR neither sees a decision
 * to make nor makes one. Only a *manager's own* regularization comes to HR,
 * because a manager cannot approve themselves.
 *
 * Pure module: no React, no Redux, no Axios.
 */

import type { AttendanceRegularization, FieldLeaveRequest, Role } from './types';

// ----------------------------------------------------------------- leave ---

/** Where a leave request has got to, as a single readable state. */
export type LeaveStage =
  | 'rejected'
  /** Both parties have approved — the rep actually has the day off. */
  | 'granted'
  /** Manager said yes, HR has not decided. */
  | 'awaiting_hr'
  /** HR said yes, the manager has not decided. */
  | 'awaiting_manager'
  /** Neither has decided. */
  | 'awaiting_both';

/**
 * Has the manager approved — including outside this dashboard?
 *
 * `manager_approved` is new. The field-sales app and the Desk UI approve by
 * setting `status` and `decided_by` and know nothing about it, so a manager
 * who approves in their own app leaves the flag at 0. Reading the flag alone
 * therefore reports "waiting on manager" for leave that was approved days ago.
 *
 * Under the older single-approver model, `status: "Approved"` meant *the
 * designated approver* had signed off — and `approver_type` says which one
 * that was. So a legacy approval maps to exactly one of the two flags, never
 * to both: an externally approved request still needs HR's own signature
 * before it counts as granted.
 *
 * This can be retired once the field-sales app writes the flag itself.
 */
export function managerHasApproved(l: FieldLeaveRequest): boolean {
  if (l.managerApproved) return true;
  return l.status === 'Approved' && l.approverType === 'Sales Manager';
}

/** The HR side of the same compatibility rule. */
export function hrHasApproved(l: FieldLeaveRequest): boolean {
  if (l.hrApproved) return true;
  return l.status === 'Approved' && l.approverType === 'HR';
}

/**
 * Which approvals a request actually requires.
 *
 * A manager cannot approve their own leave, so theirs needs HR alone — there
 * is no second signature to wait for, and holding it open for one would leave
 * every manager's leave permanently ungranted. Everyone else needs both.
 */
export function requiredApprovals(l: FieldLeaveRequest): { manager: boolean; hr: boolean } {
  if (l.requesterIsManager) return { manager: false, hr: true };
  return { manager: true, hr: true };
}

/**
 * Is the leave actually granted?
 *
 * Reads the flags against what this particular request requires, never
 * `status` alone: a record can carry `status: "Approved"` from before this
 * became a two-party decision, and treating that as granted would let a
 * half-approved day through.
 */
export function isGranted(l: FieldLeaveRequest): boolean {
  if (l.status === 'Rejected') return false;
  const need = requiredApprovals(l);
  return (
    (!need.manager || managerHasApproved(l)) && (!need.hr || hrHasApproved(l))
  );
}

export function leaveStage(l: FieldLeaveRequest): LeaveStage {
  if (l.status === 'Rejected') return 'rejected';
  if (isGranted(l)) return 'granted';
  const need = requiredApprovals(l);
  const wantManager = need.manager && !managerHasApproved(l);
  const wantHr = need.hr && !hrHasApproved(l);
  if (wantManager && wantHr) return 'awaiting_both';
  if (wantHr) return 'awaiting_hr';
  return 'awaiting_manager';
}

export const LEAVE_STAGE_LABEL: Record<LeaveStage, string> = {
  rejected: 'Rejected',
  granted: 'Granted',
  awaiting_hr: 'Waiting on HR',
  awaiting_manager: 'Waiting on manager',
  awaiting_both: 'Waiting on both',
};

/** Does this role still owe a decision on this request? */
export function leaveNeedsDecisionFrom(l: FieldLeaveRequest, role: Role): boolean {
  if (l.status === 'Rejected' || isGranted(l)) return false;
  const need = requiredApprovals(l);
  if (role === 'hr') return need.hr && !hrHasApproved(l);
  if (role === 'sales_manager') return need.manager && !managerHasApproved(l);
  return false;
}

/** Has this role already signed off, so the decision can be taken back? */
export function leaveCanRevoke(l: FieldLeaveRequest, role: Role): boolean {
  if (role === 'hr') return hrHasApproved(l) || l.status === 'Rejected';
  if (role === 'sales_manager') return managerHasApproved(l) || l.status === 'Rejected';
  return false;
}

/** Everything still short of a decision from this role. */
export function leaveQueueFor(leave: FieldLeaveRequest[], role: Role): FieldLeaveRequest[] {
  return leave
    .filter((l) => leaveNeedsDecisionFrom(l, role))
    .sort((a, b) => a.date.localeCompare(b.date));
}

// -------------------------------------------------- regularizations (AR) ---

/**
 * Who owns the decision on a regularization.
 *
 * Routed entirely by `requesterIsManager`: a manager cannot approve their own
 * correction, so theirs goes to HR. Everyone else's stays with their manager.
 */
export function arApprover(ar: AttendanceRegularization): Role {
  return ar.requesterIsManager ? 'hr' : 'sales_manager';
}

/**
 * May this role decide this regularization?
 *
 * HR sees every AR — they run payroll and need the whole picture — but they
 * may only *act* on a manager's own. An ordinary rep's correction is shown to
 * HR read-only, with no buttons, because it is not theirs to approve.
 */
export function canDecideAr(ar: AttendanceRegularization, role: Role): boolean {
  if (ar.status !== 'Pending Approval') return false;
  return arApprover(ar) === role;
}

/** Pending ARs this role is actually responsible for. */
export function arQueueFor(
  ars: AttendanceRegularization[],
  role: Role,
): AttendanceRegularization[] {
  return ars
    .filter((a) => canDecideAr(a, role))
    .sort((a, b) => b.date.localeCompare(a.date));
}

/**
 * Approved, but the attendance log was never rewritten.
 *
 * The decision was made and the hours never moved — the rep is short time
 * somebody already granted them. This is HR's work regardless of who approved
 * it, because HR is who reconciles the log.
 */
export function unappliedArs(ars: AttendanceRegularization[]): AttendanceRegularization[] {
  return ars
    .filter((a) => a.status === 'Approved' && a.completionStatus !== 'Completed')
    .sort((a, b) => b.date.localeCompare(a.date));
}

/** An already-decided regularization can be taken back to pending. */
export function arCanRevoke(ar: AttendanceRegularization, role: Role): boolean {
  if (ar.status === 'Pending Approval') return false;
  return arApprover(ar) === role;
}
