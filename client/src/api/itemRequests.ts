/**
 * Item requests (10 Nov 2026): a rep asks on the phone for a product that is
 * not in the catalogue; the accountant answers here with the item code made in
 * SAP, or a reason. Read and written through the manna_item_request Server
 * Script (app/server/item_request.py), which decides who may do what.
 *
 * The rep's manager approves first (12 Nov 2026): 'Pending Manager', then
 * 'Pending' with the accountant. shared/fixtures/item_request_flow.json pins
 * the stage names and when the accountant may answer; the phone's copy is
 * app/lib/core/item_request.dart.
 */
import { callMethod } from './client';

export type ItemRequestStatus = 'Pending Manager' | 'Pending' | 'Done' | 'Rejected';

export const WITH_MANAGER: ItemRequestStatus = 'Pending Manager';
export const WITH_ACCOUNTANT: ItemRequestStatus = 'Pending';

/**
 * What a request's stage is called. Anything not known reads as still with the
 * manager: it offers nobody an answer, the safe way for an unknown status to fall.
 */
export function itemRequestLabel(status: string): string {
  switch (status) {
    case WITH_ACCOUNTANT:
      return 'With accountant';
    case 'Done':
      return 'Done';
    case 'Rejected':
      return 'Rejected';
    default:
      return 'With manager';
  }
}

/** Whether the accountant may answer it: only once the manager has approved. */
export const accountantAnswers = (status: string) => status === WITH_ACCOUNTANT;

export interface ItemRequest {
  name: string;
  status: ItemRequestStatus;
  productLine: string;
  itemType: string;
  pattern: string;
  size: string;
  customerName: string;
  quantity: number;
  unit: string;
  note: string;
  photo: string;
  salesPerson: string;
  requestedOn: string;
  itemCode: string;
  reply: string;
  decidedOn: string;
  managerNote: string;
  approvedOn: string;
  /** The server's word that this login may approve it now. */
  canApprove: boolean;
}

const s = (v: unknown) => (v == null || v === 'null' ? '' : String(v).trim());

function toItemRequest(m: Record<string, unknown>): ItemRequest {
  const st = s(m.status);
  return {
    name: s(m.name),
    status: st === 'Done' || st === 'Rejected' || st === WITH_ACCOUNTANT ? st : WITH_MANAGER,
    productLine: s(m.product_line),
    itemType: s(m.item_type),
    pattern: s(m.pattern),
    size: s(m.size),
    customerName: s(m.customer_name) || s(m.customer),
    quantity: Number(m.quantity) || 0,
    unit: s(m.unit),
    note: s(m.note),
    photo: s(m.photo),
    salesPerson: s(m.sales_person),
    requestedOn: s(m.requested_on),
    itemCode: s(m.item_code),
    reply: s(m.reply),
    decidedOn: s(m.decided_on),
    managerNote: s(m.manager_note),
    approvedOn: s(m.approved_on),
    canApprove: s(m.can_approve) === '1' || m.can_approve === true,
  };
}

export async function listItemRequests(): Promise<ItemRequest[]> {
  const rows = await callMethod<Record<string, unknown>[]>('/api/method/manna_item_request', { action: 'list' });
  return (rows ?? []).map(toItemRequest);
}

/** The manager's decision: on to the accountant, or rejected with a reason the rep sees. */
export async function approveItemRequest(name: string, approve: boolean, note: string): Promise<void> {
  await callMethod('/api/method/manna_item_request', {
    action: 'approve',
    name,
    decision: approve ? 'Approve' : 'Reject',
    note,
  });
}

export async function decideItemRequest(
  name: string,
  status: 'Done' | 'Rejected',
  itemCode: string,
  reply: string,
): Promise<void> {
  await callMethod('/api/method/manna_item_request', { action: 'decide', name, status, item_code: itemCode, reply });
}
