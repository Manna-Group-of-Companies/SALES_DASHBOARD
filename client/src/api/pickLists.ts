/**
 * Pick lists: which products of an approved order go from Hi-Tech's stock
 * now. Made by reps on the phone; read here through
 * app/server/pick_lists.py.
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
  sapSalesOrder: string;
  /** The unit (company) the order belongs to. */
  company: string;
  /** Blank for a production manager. */
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
    // Older lists carry no approval status: they are pending.
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
