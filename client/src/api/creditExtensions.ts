/**
 * Temporary credit extensions (16 Nov 2026), through the manna_credit_extension
 * Server Script (app/server/credit_extension.py), which decides who may do
 * what. The rule is client/src/domain/creditExtension.ts.
 */
import { callMethod } from './client';
import { xtNextStatus } from '@/domain/creditExtension';

const METHOD = '/api/method/manna_credit_extension';
const s = (v: unknown) => (v == null || v === 'null' ? '' : String(v).trim());
const n = (v: unknown) => Number(v) || 0;
const flag = (v: unknown) => s(v) === '1' || v === true;

export interface CreditExtension {
  name: string;
  status: string;
  customer: string;
  customerName: string;
  bpCode: string;
  salesOrder: string;
  salesPerson: string;
  requestedOn: string;
  requestReason: string;
  creditLimit: number;
  outstanding: number;
  overdue: number;
  orderAmount: number;
  excess: number;
  amount: number;
  commitmentDate: string;
  reason: string;
  remarks: string;
  approvedOn: string;
  approverRole: string;
  rejectionRemarks: string;
  escalationReason: string;
  sapReference: string;
  sapError: string;
  originalLimit: number;
  raisedLimit: number;
  paid: number;
  remaining: number;
  paymentStatus: string;
  restoreStatus: string;
  restoreReference: string;
  missed: boolean;
  actor: string;
  canApprove: boolean;
  canReject: boolean;
  canEscalate: boolean;
  canRetry: boolean;
}

export function toCreditExtension(m: Record<string, unknown>): CreditExtension {
  const status = s(m.status);
  const actor = s(m.actor);
  // The server's word AND the rule's.
  const may = (server: unknown, action: string, who = actor) => flag(server) && xtNextStatus(action, status, who) !== null;
  return {
    name: s(m.name),
    status,
    customer: s(m.customer),
    customerName: s(m.customer_name) || s(m.customer),
    bpCode: s(m.bp_code),
    salesOrder: s(m.sales_order),
    salesPerson: s(m.sales_person),
    requestedOn: s(m.requested_on),
    requestReason: s(m.request_reason),
    creditLimit: n(m.credit_limit_at_request),
    outstanding: n(m.outstanding_at_request),
    overdue: n(m.overdue_at_request),
    orderAmount: n(m.order_amount),
    excess: n(m.excess_amount),
    amount: n(m.amount),
    commitmentDate: s(m.commitment_date),
    reason: s(m.reason),
    remarks: s(m.remarks),
    approvedOn: s(m.approved_on),
    approverRole: s(m.approver_role),
    rejectionRemarks: s(m.rejection_remarks),
    escalationReason: s(m.escalation_reason),
    sapReference: s(m.sap_reference),
    sapError: s(m.sap_error),
    originalLimit: n(m.original_limit),
    raisedLimit: n(m.raised_limit),
    paid: n(m.paid_amount),
    remaining: n(m.remaining_amount),
    paymentStatus: s(m.payment_status) || 'Not Paid',
    restoreStatus: s(m.restore_status),
    restoreReference: s(m.restore_reference),
    missed: flag(m.missed),
    actor,
    canApprove: may(m.can_approve, 'approve'),
    canReject: may(m.can_reject, 'reject'),
    canEscalate: may(m.can_escalate, 'escalate'),
    canRetry: may(m.can_retry, 'retry', 'approver'),
  };
}

export interface EligibleOrder {
  salesOrder: string;
  customerName: string;
  bpCode: string;
  salesPerson: string;
  orderAmount: number;
  creditLimit: number;
  outstanding: number;
  overdue: number;
  excess: number;
  hasRequest: boolean;
}

export interface ExtensionHistory {
  total_extensions: number;
  manager_approved: number;
  gm_approved: number;
  gm_rejections: number;
  total_additional_credit: number;
  total_paid_against_commitments: number;
  missed_commitments: number;
  gm_escalations: number;
  total_extension_days: number;
  current_status: string;
  extensions: Record<string, unknown>[];
  payments: Record<string, unknown>[];
}

export interface ExtensionDetail {
  extension: CreditExtension;
  customer: { credit_limit: number; outstanding: number; overdue: number; payment_terms: string };
  managerAuthority: number;
  payments: { doc_num: string; date: string; amount: number }[];
  log: { action: string; role: string; by: string; at: string; remarks: string; amount: number; commitment_date: string }[];
  sapLog: { at: string; operation: string; ok: number; request: string; response: string }[];
  invoices: { invoice_no: string; posting_date: string; due_date: string; total: number; paid: number; balance: number; status: string }[];
  history: ExtensionHistory;
}

export async function listCreditExtensions(): Promise<CreditExtension[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'list' });
  return (rows ?? []).map(toCreditExtension);
}

export async function listEligibleOrders(): Promise<EligibleOrder[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'eligible' });
  return (rows ?? []).map((m) => ({
    salesOrder: s(m.sales_order),
    customerName: s(m.customer_name) || s(m.customer),
    bpCode: s(m.bp_code),
    salesPerson: s(m.sales_person),
    orderAmount: n(m.order_amount),
    creditLimit: n(m.credit_limit),
    outstanding: n(m.outstanding),
    overdue: n(m.overdue),
    excess: n(m.excess),
    hasRequest: flag(m.has_request),
  }));
}

export async function getCreditExtension(name: string): Promise<ExtensionDetail> {
  const m = await callMethod<Record<string, unknown>>(METHOD, { action: 'detail', name });
  const c = (m.customer ?? {}) as Record<string, unknown>;
  return {
    extension: toCreditExtension((m.extension ?? {}) as Record<string, unknown>),
    customer: { credit_limit: n(c.credit_limit), outstanding: n(c.outstanding), overdue: n(c.overdue), payment_terms: s(c.payment_terms) },
    managerAuthority: n(m.manager_authority),
    payments: (m.payments ?? []) as ExtensionDetail['payments'],
    log: (m.log ?? []) as ExtensionDetail['log'],
    sapLog: (m.sap_log ?? []) as ExtensionDetail['sapLog'],
    invoices: (m.invoices ?? []) as ExtensionDetail['invoices'],
    history: (m.history ?? {}) as ExtensionHistory,
  };
}

export async function requestCreditExtension(salesOrder: string, reason: string): Promise<void> {
  await callMethod(METHOD, { action: 'submit', sales_order: salesOrder, reason });
}

export async function actOnCreditExtension(
  name: string,
  action: 'approve' | 'reject' | 'escalate' | 'retry',
  fields: { amount?: number; commitment_date?: string; reason?: string; remarks?: string } = {},
): Promise<void> {
  await callMethod(METHOD, { action, name, ...fields });
}
