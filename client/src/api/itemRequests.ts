/**
 * Item requests (10 Nov 2026): a rep asks on the phone for a product that is
 * not in the catalogue; the accountant answers here with the item code made in
 * SAP, or a reason. Read and written through the manna_item_request Server
 * Script (app/server/item_request.py), which decides who may do what.
 */
import { callMethod } from './client';

export type ItemRequestStatus = 'Pending' | 'Done' | 'Rejected';

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
}

const s = (v: unknown) => (v == null || v === 'null' ? '' : String(v).trim());

function toItemRequest(m: Record<string, unknown>): ItemRequest {
  const st = s(m.status);
  return {
    name: s(m.name),
    status: st === 'Done' || st === 'Rejected' ? st : 'Pending',
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
  };
}

export async function listItemRequests(): Promise<ItemRequest[]> {
  const rows = await callMethod<Record<string, unknown>[]>('/api/method/manna_item_request', { action: 'list' });
  return (rows ?? []).map(toItemRequest);
}

export async function decideItemRequest(
  name: string,
  status: 'Done' | 'Rejected',
  itemCode: string,
  reply: string,
): Promise<void> {
  await callMethod('/api/method/manna_item_request', { action: 'decide', name, status, item_code: itemCode, reply });
}
