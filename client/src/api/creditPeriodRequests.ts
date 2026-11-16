/**
 * Credit-period requests (16 Nov 2026), through the manna_credit_period_request
 * Server Script (app/server/credit_period_request.py), which decides who may
 * do what. The rule is client/src/domain/creditPeriodRequest.ts.
 */
import { callMethod } from './client';
import { cprBand, cprLabel, cprNextStatus, type CprStatus, type SapPaymentTerm } from '@/domain/creditPeriodRequest';

export interface CreditPeriodRequest {
  name: string;
  status: string;
  label: CprStatus;
  customer: string;
  customerName: string;
  bpCode: string;
  currentTerm: string;
  currentDays: number;
  requestedTerm: string;
  requestedDays: number;
  reason: string;
  salesPerson: string;
  team: string;
  requestedOn: string;
  escalatedOn: string;
  managerNote: string;
  decidedBy: string;
  decidedOn: string;
  approverRole: string;
  decisionNote: string;
  pushRequestedOn: string;
  sapPushedOn: string;
  sapPreviousTerm: string;
  sapCompany: string;
  sapError: string;
  /** What this login is to the request, as the server sees it. */
  actor: string;
  needsGm: boolean;
  canApprove: boolean;
  canReject: boolean;
  canEscalate: boolean;
  canPush: boolean;
}

const s = (v: unknown) => (v == null || v === 'null' ? '' : String(v).trim());
const n = (v: unknown) => Number(v) || 0;
const flag = (v: unknown) => s(v) === '1' || v === true;

export function toCreditPeriodRequest(m: Record<string, unknown>): CreditPeriodRequest {
  const status = s(m.status);
  const days = n(m.requested_days);
  const actor = s(m.actor);
  // The server's word AND the rule's: a stale row never offers what the server would refuse.
  const may = (server: unknown, action: string) => flag(server) && cprNextStatus(action, status, days, actor) !== null;
  return {
    name: s(m.name),
    status,
    label: cprLabel(status),
    customer: s(m.customer),
    customerName: s(m.customer_name) || s(m.customer),
    bpCode: s(m.bp_code),
    currentTerm: s(m.current_term),
    currentDays: n(m.current_term_days),
    requestedTerm: s(m.requested_term),
    requestedDays: days,
    reason: s(m.reason),
    salesPerson: s(m.sales_person),
    team: s(m.team),
    requestedOn: s(m.requested_on),
    escalatedOn: s(m.escalated_on),
    managerNote: s(m.manager_note),
    decidedBy: s(m.decided_by),
    decidedOn: s(m.decided_on),
    approverRole: s(m.approver_role),
    decisionNote: s(m.decision_note),
    pushRequestedOn: s(m.push_requested_on),
    sapPushedOn: s(m.sap_pushed_on),
    sapPreviousTerm: s(m.sap_previous_term),
    sapCompany: s(m.sap_company),
    sapError: s(m.sap_error),
    actor,
    needsGm: cprBand(days) === 'gm',
    canApprove: may(m.can_approve, 'approve'),
    canReject: may(m.can_reject, 'reject'),
    canEscalate: may(m.can_escalate, 'escalate'),
    canPush: may(m.can_push, 'push'),
  };
}

const METHOD = '/api/method/manna_credit_period_request';

export async function listCreditPeriodRequests(customer?: string): Promise<CreditPeriodRequest[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'list', ...(customer ? { customer } : {}) });
  return (rows ?? []).map(toCreditPeriodRequest);
}

export async function listSapPaymentTerms(): Promise<SapPaymentTerm[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'terms' });
  return (rows ?? []).map((t) => ({ code: s(t.code) === '' ? -1 : n(t.code), name: s(t.name), days: n(t.days) }));
}

/** A manager's or the GM's step. The server refuses anything the rule does not allow. */
export async function actOnCreditPeriodRequest(
  name: string,
  action: 'approve' | 'reject' | 'escalate' | 'push',
  note = '',
): Promise<void> {
  if (action === 'approve' || action === 'reject') {
    await callMethod(METHOD, { action: 'decide', name, decision: action === 'approve' ? 'Approve' : 'Reject', note });
  } else {
    await callMethod(METHOD, { action, name, note });
  }
}
