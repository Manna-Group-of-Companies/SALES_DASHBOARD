/**
 * Credit-period requests (16 Nov 2026, the user): a customer asks, through
 * their rep, for a different credit period - the SAP payment term on their
 * Manna Treads account. Up to 30 days the rep's manager approves it and pushes
 * it to SAP; 31 to 40 days the manager may only escalate it (or reject it) and
 * the GM approves and pushes it. Over 40 days is never asked for.
 *
 * Enforced by the manna_credit_period_request Server Script
 * (app/server/credit_period_request.py), which hands each row can_* flags.
 * The dashboard offers a button only when the server says so AND this copy of
 * the rule agrees. shared/fixtures/credit_period_request.json pins both; the
 * phone's copy is app/lib/core/credit_period_request.dart.
 */

export const MANAGER_MAX_DAYS = 30;
export const GM_MAX_DAYS = 40;

export type CprStatus = 'With Manager' | 'With GM' | 'Approved' | 'Sending to SAP' | 'In SAP' | 'Rejected';
export const CPR_STATUSES: CprStatus[] = ['With Manager', 'With GM', 'Approved', 'Sending to SAP', 'In SAP', 'Rejected'];
export const CPR_OPEN: CprStatus[] = ['With Manager', 'With GM', 'Approved', 'Sending to SAP'];

export type CprAction = 'approve' | 'reject' | 'escalate' | 'push' | 'sap_done' | 'sap_failed';
export type CprBand = 'manager' | 'gm' | 'refused';

/** What a status is called. Unknown reads as with the manager; every action refuses it. */
export function cprLabel(status: string): CprStatus {
  return (CPR_STATUSES as string[]).includes(status) ? (status as CprStatus) : 'With Manager';
}

/** Who decides [days]: the manager, the GM, or nobody (over 40, or negative). */
export function cprBand(days: number): CprBand {
  if (days < 0 || days > GM_MAX_DAYS) return 'refused';
  return days > MANAGER_MAX_DAYS ? 'gm' : 'manager';
}

/**
 * The status [action] by [actor] moves a request to, or null when refused.
 * actor: rep | manager (the rep's team manager) | other_manager | gm | sap_sync.
 */
export function cprNextStatus(action: string, status: string, days: number, actor: string): CprStatus | null {
  const band = cprBand(days);
  if (band === 'refused') return null;
  const gmBand = band === 'gm';
  switch (action) {
    case 'approve':
    case 'reject': {
      const to: CprStatus = action === 'approve' ? 'Approved' : 'Rejected';
      if (status === 'With Manager') {
        if (actor === 'gm') return to;
        if (actor === 'manager' && (action === 'reject' || !gmBand)) return to;
      }
      if (status === 'With GM' && actor === 'gm') return to;
      return null;
    }
    case 'escalate':
      return status === 'With Manager' && actor === 'manager' && gmBand ? 'With GM' : null;
    case 'push':
      return status === 'Approved' && (actor === 'gm' || (actor === 'manager' && !gmBand)) ? 'Sending to SAP' : null;
    case 'sap_done':
    case 'sap_failed':
      if (status === 'Sending to SAP' && actor === 'sap_sync') return action === 'sap_done' ? 'In SAP' : 'Approved';
      return null;
    default:
      return null;
  }
}

/** A new request's status, or null when [days] may not be asked for. */
export const cprSubmitStatus = (days: number): CprStatus | null => (cprBand(days) === 'refused' ? null : 'With Manager');

export interface SapPaymentTerm {
  code: number;
  name: string;
  days: number;
}

/**
 * The terms a rep may ask for: 40 days or fewer, never '- Cash Basic -'
 * (code -1, SAP's 'no term'), never the one the customer is on. Shortest first.
 */
export function cprOfferedTerms(terms: SapPaymentTerm[], currentCode: number | null): SapPaymentTerm[] {
  return terms
    .filter((t) => t.code !== -1 && t.days >= 0 && t.days <= GM_MAX_DAYS && t.code !== currentCode)
    .sort((a, b) => a.days - b.days || a.name.localeCompare(b.name));
}
