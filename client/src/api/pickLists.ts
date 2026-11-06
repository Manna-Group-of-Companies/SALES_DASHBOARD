/**
 * Pick lists — which products of an approved order go from Hi-Tech's stock
 * now (3 Nov 2026). Made on the phone; read here through the
 * `manna_pick_lists` Server Script (app/server/pick_lists.py), which scopes
 * them to the caller's team. The quantity rule is in
 * app/lib/core/pick_list.dart and shared/fixtures/pick_list.json.
 *
 * A production manager approves each list (5 Nov 2026) through the
 * `manna_pick_list_approve` Server Script (app/server/pick_list_approve.py),
 * which is what refuses anybody else. For a production manager the read
 * comes back with the customer blank — production never sees who the
 * customer is.
 */
import { http } from './client';

export interface PickListItem {
  salesOrderItem: string;
  itemCode: string;
  itemName: string;
  unit: string;
  orderedQty: number;
  availableQty: number;
  pickedQty: number;
  /** Weighed kilos (5 Nov 2026): what SAP's documents for this list carry. */
  pickedKg: number;
}

export type PickListApproval = 'Pending' | 'Approved';

export interface PickList {
  name: string;
  salesOrder: string;
  /** SAP's sales-order number, once the sync has written it back. */
  sapSalesOrder: string;
  /** The order's company — the unit (`custom_company`). */
  company: string;
  customerName: string;
  salesPerson: string;
  team: string;
  status: string;
  pickedOn: string;
  approvalStatus: PickListApproval;
  approvedByName: string;
  approvedOn: string;
  items: PickListItem[];
  /** SAP's side: the pick list the sync sent, and what B1if made from it. */
  sapPickList: string;
  hitechInvoice: string;
  mtGoodsReceipt: string;
  mtDelivery: string;
  sapError: string;
}

const num = (v: unknown): number => {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string => (v == null ? '' : String(v));

export function toPickList(m: Record<string, unknown>): PickList {
  const items = Array.isArray(m.items) ? (m.items as Record<string, unknown>[]) : [];
  return {
    name: str(m.name),
    salesOrder: str(m.sales_order),
    sapSalesOrder: str(m.sap_sales_order),
    company: str(m.company),
    customerName: str(m.customer_name) || str(m.customer),
    salesPerson: str(m.sales_person),
    team: str(m.team),
    status: str(m.status) || 'Submitted',
    pickedOn: str(m.picked_on),
    // Lists made before approval existed carry no status: they are pending.
    approvalStatus: str(m.approval_status) === 'Approved' ? 'Approved' : 'Pending',
    approvedByName: str(m.approved_by_name) || str(m.approved_by),
    approvedOn: str(m.approved_on),
    items: items.map((i) => ({
      salesOrderItem: str(i.sales_order_item),
      itemCode: str(i.item_code),
      itemName: str(i.item_name),
      unit: str(i.unit),
      orderedQty: num(i.ordered_qty),
      availableQty: num(i.available_qty),
      pickedQty: num(i.picked_qty),
      pickedKg: num(i.picked_kg),
    })),
    sapPickList: str(m.sap_pick_list),
    hitechInvoice: str(m.hitech_invoice),
    mtGoodsReceipt: str(m.mt_goods_receipt),
    mtDelivery: str(m.mt_delivery),
    sapError: str(m.sap_sync_error),
  };
}

export async function listPickLists(salesOrder?: string): Promise<PickList[]> {
  const { data } = await http.get<{ message: Record<string, unknown>[] }>('/api/method/manna_pick_lists', {
    params: salesOrder ? { sales_order: salesOrder } : {},
  });
  return (data.message ?? []).map(toPickList);
}

/** Production approves a pick list. Refused server-side for anyone else. */
export async function approvePickList(name: string): Promise<void> {
  await http.post('/api/method/manna_pick_list_approve', { name });
}
