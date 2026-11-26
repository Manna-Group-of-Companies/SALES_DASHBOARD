/**
 * The orders a sales manager or the GM is told about when they reach SAP
 * (the user, 26 Nov 2026). Read-only; the news itself is `sapSentNews`.
 */
import { listDocs, type Filter } from './client';
import { DOCTYPE, SALES_ORDER_FIELD } from './endpoints';
import { serverNow } from '@/domain/serverClock';

export interface SentCandidate {
  id: string;
  customerName: string;
  rep: string;
  poStatus: string;
  gmApprovedBy: string;
  mtSalesOrder: string;
  sapSalesOrder: string;
}

/** Days back an order's last change is read. The sync's write-back changes it. */
const WINDOW_DAYS = 7;

const s = (v: unknown) => (v == null ? '' : String(v));

/**
 * Orders changed in the last week: the team's for a manager (`reps`), every
 * one for the GM (`reps` undefined). An empty team reads nothing - never
 * everyone - which is how the order list fails closed too.
 */
export async function listSentCandidates(reps?: string[]): Promise<SentCandidate[]> {
  if (reps && reps.length === 0) return [];
  const since = new Date(serverNow().getTime() - WINDOW_DAYS * 86_400_000);
  const day = since.toISOString().slice(0, 10);
  const filters: Filter[] = [
    ['modified', '>=', `${day} 00:00:00`],
    ['docstatus', '<', 2],
  ];
  if (reps) filters.push([SALES_ORDER_FIELD.rep, 'in', reps]);
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
    fields: [
      'name',
      SALES_ORDER_FIELD.customerName,
      SALES_ORDER_FIELD.rep,
      SALES_ORDER_FIELD.poStatus,
      SALES_ORDER_FIELD.gmApprovedBy,
      SALES_ORDER_FIELD.mtSalesOrder,
      SALES_ORDER_FIELD.sapSalesOrder,
    ],
    filters,
    orderBy: 'modified desc',
    limit: 500,
  });
  return rows.map((r) => ({
    id: s(r.name),
    customerName: s(r[SALES_ORDER_FIELD.customerName]),
    rep: s(r[SALES_ORDER_FIELD.rep]),
    poStatus: s(r[SALES_ORDER_FIELD.poStatus]),
    gmApprovedBy: s(r[SALES_ORDER_FIELD.gmApprovedBy]),
    mtSalesOrder: s(r[SALES_ORDER_FIELD.mtSalesOrder]),
    sapSalesOrder: s(r[SALES_ORDER_FIELD.sapSalesOrder]),
  }));
}
