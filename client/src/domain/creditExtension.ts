/**
 * Temporary credit extension with a payment commitment (16 Nov 2026, the
 * user's strict instruction). A separate workflow: order approval, credit
 * periods and credit conditions are untouched. A rep or manager asks on an
 * order that takes a customer past their SAP credit limit; the manager
 * approves an extra amount within their authority, with a commitment of at
 * most 10 days, and that approval pushes it to SAP; SAP's payments decide
 * Paid or Payment Commitment Overdue, which goes to the GM.
 *
 * Enforced by the manna_credit_extension Server Script
 * (app/server/credit_extension.py); this copy decides the buttons with the
 * server's can_* flags. shared/fixtures/credit_extension.json pins both; the
 * phone's copy is app/lib/core/credit_extension.dart.
 */

export const MANAGER_MAX_DAYS = 10;

export const XT = {
  pendingManager: 'Pending Manager',
  pendingGm: 'Pending GM',
  sending: 'Sending to SAP',
  pushFailed: 'SAP Push Failed',
  active: 'Active',
  paid: 'Paid',
  overdue: 'Payment Commitment Overdue',
  renewed: 'Renewed by GM',
  rejected: 'Rejected',
  rejectedByGm: 'Rejected by GM',
} as const;

export type XtProblem = 'amount' | 'authority' | 'date_past' | 'too_long' | 'reason' | 'remarks';

export const XT_MESSAGES: Record<XtProblem, string> = {
  amount: 'Enter an additional credit amount above zero.',
  authority: 'This amount is past your approval authority. Send it to the GM.',
  date_past: 'The payment commitment date cannot be in the past.',
  too_long: 'A manager may give at most 10 days from today.',
  reason: 'Enter the reason for the extension.',
  remarks: 'Enter your remarks.',
};

export const xtRouteStatus = (missedBefore: number, openExtension: boolean): string =>
  missedBefore > 0 || openExtension ? XT.pendingGm : XT.pendingManager;

const dayNo = (s: string): number | null => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86_400_000 : null;
};

export function xtCheckManager(a: {
  amount: number;
  authority: number;
  approvedOn: string;
  commitment: string;
  reason: string;
  remarks: string;
}): XtProblem | null {
  if (!(a.amount > 0)) return 'amount';
  if (!(a.authority > 0) || a.amount > a.authority) return 'authority';
  const d0 = dayNo(a.approvedOn);
  const c = dayNo(a.commitment);
  if (d0 === null || c === null || c < d0) return 'date_past';
  if (c - d0 > MANAGER_MAX_DAYS) return 'too_long';
  if (!a.reason.trim()) return 'reason';
  if (!a.remarks.trim()) return 'remarks';
  return null;
}

export function xtCheckGm(a: { amount: number; today: string; commitment: string; remarks: string }): XtProblem | null {
  if (!(a.amount > 0)) return 'amount';
  const t = dayNo(a.today);
  const c = dayNo(a.commitment);
  if (t === null || c === null || c < t) return 'date_past';
  if (!a.remarks.trim()) return 'remarks';
  return null;
}

/** The status [action] by [actor] moves an extension to, or null when refused. */
export function xtNextStatus(action: string, status: string, actor: string): string | null {
  switch (action) {
    case 'approve':
      if (status === XT.pendingManager && (actor === 'manager' || actor === 'gm')) return XT.sending;
      if (status === XT.pendingGm && actor === 'gm') return XT.sending;
      if (status === XT.overdue && actor === 'gm') return XT.renewed;
      return null;
    case 'reject':
      if (status === XT.pendingManager && actor === 'manager') return XT.rejected;
      if (([XT.pendingManager, XT.pendingGm, XT.overdue] as string[]).includes(status) && actor === 'gm') return XT.rejectedByGm;
      return null;
    case 'escalate':
      return status === XT.pendingManager && actor === 'manager' ? XT.pendingGm : null;
    case 'retry':
      return status === XT.pushFailed && actor === 'approver' ? XT.sending : null;
  }
  if (actor !== 'sap_job') return null;
  if (action === 'sap_raised' && status === XT.sending) return XT.active;
  if (action === 'sap_failed' && status === XT.sending) return XT.pushFailed;
  if (action === 'sap_paid' && status === XT.active) return XT.paid;
  if (action === 'sap_overdue' && status === XT.active) return XT.overdue;
  return null;
}

const r2 = (v: number) => Math.round(v * 100) / 100;

export function xtPaymentStatus(amount: number, paid: number): { status: string; remaining: number } {
  const a = r2(amount);
  const p = r2(paid);
  if (a > 0 && p >= a) return { status: 'Paid', remaining: 0 };
  if (p > 0) return { status: 'Partially Paid', remaining: r2(a - p) };
  return { status: 'Not Paid', remaining: a };
}

export function xtOutcome(amount: number, paid: number, today: string, commitment: string): 'paid' | 'running' | 'overdue' {
  if (r2(paid) >= r2(amount)) return 'paid';
  return today > commitment ? 'overdue' : 'running';
}
