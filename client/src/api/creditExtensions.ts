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
  /** Escalated by the morning watchdog before SAP's payments were counted. */
  overdueUnchecked: boolean;
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
    overdueUnchecked: flag(m.overdue_unchecked),
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
  /** The manager's extensions for this customer in the window, against the cap. */
  managerCap: { count: number; days: number; used: number };
  payments: { doc_num: string; date: string; amount: number }[];
  log: { action: string; role: string; by: string; at: string; remarks: string; amount: number; commitment_date: string }[];
  sapLog: { at: string; operation: string; ok: number; request: string; response: string }[];
  invoices: { invoice_no: string; posting_date: string; due_date: string; total: number; paid: number; balance: number; status: string }[];
  history: ExtensionHistory;
}

export async function listCreditExtensions(filter: { salesOrder?: string } = {}): Promise<CreditExtension[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, {
    action: 'list',
    ...(filter.salesOrder ? { sales_order: filter.salesOrder } : {}),
  });
  return (rows ?? []).map(toCreditExtension);
}

export interface ExtensionSettings {
  canEdit: boolean;
  defaultAuthority: number;
  capCount: number;
  capDays: number;
  maxDays: number;
  managers: { user: string; name: string; team: string; authority: number }[];
  /** Managers with a figure of their own; the rest have the default. */
  authorities: { manager: string; maxAmount: number }[];
  myAuthority: number | null;
}

function toSettings(m: Record<string, unknown>): ExtensionSettings {
  return {
    canEdit: flag(m.can_edit),
    defaultAuthority: n(m.manager_max_amount),
    capCount: n(m.manager_cap_count),
    capDays: n(m.manager_cap_days),
    maxDays: n(m.max_days) || 10,
    managers: ((m.managers ?? []) as Record<string, unknown>[]).map((r) => ({
      user: s(r.user),
      name: s(r.name) || s(r.user),
      team: s(r.team),
      authority: n(r.authority),
    })),
    authorities: ((m.authorities ?? []) as Record<string, unknown>[]).map((r) => ({ manager: s(r.manager), maxAmount: n(r.max_amount) })),
    myAuthority: m.my_authority == null ? null : n(m.my_authority),
  };
}

export async function getExtensionSettings(): Promise<ExtensionSettings> {
  return toSettings(await callMethod<Record<string, unknown>>(METHOD, { action: 'settings' }));
}

/** The GM only; the server refuses anyone else. Every change is in the settings' version history. */
export async function saveExtensionSettings(v: {
  defaultAuthority: number;
  capCount: number;
  capDays: number;
  authorities: { manager: string; maxAmount: number }[];
}): Promise<ExtensionSettings> {
  return toSettings(
    await callMethod<Record<string, unknown>>(METHOD, {
      action: 'settings',
      save: 1,
      manager_max_amount: v.defaultAuthority,
      manager_cap_count: v.capCount,
      manager_cap_days: v.capDays,
      authorities: JSON.stringify(v.authorities.map((a) => ({ manager: a.manager, max_amount: a.maxAmount }))),
    }),
  );
}

export interface ExtensionAlert {
  name: string;
  subject: string;
  extension: string;
  read: boolean;
  at: string;
}

/** This login's notifications about extensions (Frappe's Notification Log). */
export async function listExtensionAlerts(): Promise<ExtensionAlert[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'alerts' });
  return (rows ?? []).map((r) => ({ name: s(r.name), subject: s(r.subject), extension: s(r.extension), read: flag(r.read), at: s(r.at) }));
}

export async function markExtensionAlertsSeen(): Promise<void> {
  await callMethod(METHOD, { action: 'seen' });
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
    managerCap: {
      count: n((m.manager_cap as Record<string, unknown> | undefined)?.count),
      days: n((m.manager_cap as Record<string, unknown> | undefined)?.days),
      used: n((m.manager_cap as Record<string, unknown> | undefined)?.used),
    },
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
