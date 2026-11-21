/**
 * The 10-day payment commitment ladder (17 Nov 2026), through the
 * manna_payment_commitment Server Script (app/server/payment_commitment.py),
 * which decides; manna_payment_commitment_order is its backstop on every
 * Sales Order save. The rule is client/src/domain/paymentCommitment.ts.
 */
import { callMethod } from './client';
import type { PcRoute } from '@/domain/paymentCommitment';

const METHOD = '/api/method/manna_payment_commitment';
const s = (v: unknown) => (v == null || v === 'null' ? '' : String(v).trim());
const n = (v: unknown) => Number(v) || 0;

export interface OrderRoute {
  salesOrder: string;
  customer: string;
  needs: { overdue30: boolean; overLimit: boolean; excess: number; needs: boolean };
  route: PcRoute;
  gmLock: boolean;
  /** The order's team manager's approval authority. */
  authority: number;
  cap: { count: number; days: number; used: number; reached: boolean };
  maxDays: number;
  /** The order's latest commitment, if any (Pending until the approval saves). */
  commitment: { name: string; status: string; commitmentDate: string; remarks: string; approverRole: string } | null;
}

export async function getOrderRoute(salesOrder: string): Promise<OrderRoute> {
  const m = await callMethod<Record<string, unknown>>(METHOD, { action: 'route', sales_order: salesOrder });
  const nd = (m.needs ?? {}) as Record<string, unknown>;
  const cap = (m.cap ?? {}) as Record<string, unknown>;
  const c = m.commitment as Record<string, unknown> | null;
  return {
    salesOrder: s(m.sales_order),
    customer: s(m.customer),
    needs: { overdue30: !!nd.overdue30, overLimit: !!nd.over_limit, excess: n(nd.excess), needs: !!nd.needs },
    route: (s(m.route) || 'gm') as PcRoute,
    gmLock: !!m.gm_lock,
    authority: n(m.authority),
    cap: { count: n(cap.count), days: n(cap.days), used: n(cap.used), reached: !!cap.reached },
    maxDays: n(m.max_days) || 10,
    commitment: c
      ? {
          name: s(c.name),
          status: s(c.status),
          commitmentDate: s(c.commitment_date),
          remarks: s(c.remarks),
          approverRole: s(c.approver_role),
        }
      : null,
  };
}

/**
 * Entered just before the approval itself; it becomes Running when the
 * order's approval saves (the backstop), so a failed approval leaves nothing
 * active behind.
 */
export async function giveCommitment(salesOrder: string, commitmentDate: string, remarks: string): Promise<string> {
  const m = await callMethod<Record<string, unknown>>(METHOD, {
    action: 'approve',
    sales_order: salesOrder,
    commitment_date: commitmentDate,
    remarks,
  });
  return s(m?.name);
}

export interface CommitmentRow {
  name: string;
  status: string;
  customer: string;
  customerName: string;
  salesOrder: string;
  orderDate: string;
  orderAmount: number;
  reason: string;
  approverRole: string;
  approvedBy: string;
  approvedOn: string;
  days: number;
  commitmentDate: string;
  remarks: string;
  outstandingAt: number;
  overdueAt: number;
  overdueDaysAt: number;
  keptOn: string;
  missedOn: string;
  clearedOn: string;
  salesPerson: string;
}

const toRow = (r: Record<string, unknown>): CommitmentRow => ({
  name: s(r.name),
  status: s(r.status),
  customer: s(r.customer),
  customerName: s(r.customer_name) || s(r.customer),
  salesOrder: s(r.sales_order),
  orderDate: s(r.order_date),
  orderAmount: n(r.order_amount),
  reason: s(r.reason),
  approverRole: s(r.approver_role),
  approvedBy: s(r.approved_by),
  approvedOn: s(r.approved_on),
  days: n(r.days),
  commitmentDate: s(r.commitment_date),
  remarks: s(r.remarks),
  outstandingAt: n(r.outstanding_at),
  overdueAt: n(r.overdue_at),
  overdueDaysAt: n(r.overdue_days_at),
  keptOn: s(r.kept_on),
  missedOn: s(r.missed_on),
  clearedOn: s(r.cleared_on),
  salesPerson: s(r.sales_person),
});

export async function listCommitments(): Promise<CommitmentRow[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'list' });
  return (rows ?? []).map(toRow);
}

export interface CommitmentHistory {
  customer: string;
  given: number;
  totalDays: number;
  byManager: number;
  byGm: number;
  kept: number;
  missed: number;
  running: number;
  gmLock: boolean;
  outstandingNow: number;
  overdueNow: number;
  overdueDaysNow: number;
  rows: CommitmentRow[];
}

export async function getCommitmentHistory(customer: string): Promise<CommitmentHistory> {
  const m = await callMethod<Record<string, unknown>>(METHOD, { action: 'history', customer });
  return {
    customer: s(m.customer),
    given: n(m.commitments_given),
    totalDays: n(m.total_days),
    byManager: n(m.by_manager),
    byGm: n(m.by_gm),
    kept: n(m.kept),
    missed: n(m.missed),
    running: n(m.running),
    gmLock: !!m.gm_lock,
    outstandingNow: n(m.outstanding_now),
    overdueNow: n(m.overdue_now),
    overdueDaysNow: n(m.overdue_days_now),
    rows: ((m.rows ?? []) as Record<string, unknown>[]).map(toRow),
  };
}

/** Each order's live commitment status, and which customers are with the GM. */
export async function getOrdersCommitments(
  orderNames: string[],
  customers: string[],
): Promise<{
  orders: Record<string, { status: string; commitmentDate: string; approverRole: string }>;
  gmLocked: Set<string>;
  /** Orders SAP has (Hi-Tech's or Manna Treads' order number). */
  pushed: Set<string>;
}> {
  if (orderNames.length === 0 && customers.length === 0) return { orders: {}, gmLocked: new Set(), pushed: new Set() };
  const m = await callMethod<Record<string, unknown>>(METHOD, {
    action: 'orders',
    names: JSON.stringify(orderNames),
    customers: JSON.stringify(customers),
  });
  const out: Record<string, { status: string; commitmentDate: string; approverRole: string }> = {};
  for (const [k, v] of Object.entries((m.orders ?? {}) as Record<string, Record<string, unknown>>)) {
    out[k] = { status: s(v.status), commitmentDate: s(v.commitment_date), approverRole: s(v.approver_role) };
  }
  return {
    orders: out,
    gmLocked: new Set(Object.keys((m.gm_locked ?? {}) as Record<string, unknown>)),
    pushed: new Set(((m.pushed ?? []) as unknown[]).map(s)),
  };
}

export interface LadderAlert {
  name: string;
  subject: string;
  /** Manna Payment Commitment, Sales Order (sent to the GM) or Manna Credit Extension. */
  doctype: string;
  docname: string;
  read: boolean;
  at: string;
}

/** This login's notifications about commitments and orders sent to the GM. */
export async function listLadderAlerts(): Promise<LadderAlert[]> {
  const rows = await callMethod<Record<string, unknown>[]>(METHOD, { action: 'alerts' });
  return (rows ?? []).map((r) => ({
    name: s(r.name),
    subject: s(r.subject),
    doctype: s(r.doctype),
    docname: s(r.docname),
    read: s(r.read) === '1',
    at: s(r.at),
  }));
}

export async function markLadderAlertsSeen(): Promise<void> {
  await callMethod(METHOD, { action: 'seen' });
}
