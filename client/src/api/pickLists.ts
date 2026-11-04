/**
 * Pick lists — which products of an approved order go from Hi-Tech's stock
 * now (3 Nov 2026). Made on the phone; read here through the
 * `manna_pick_lists` Server Script (app/server/pick_lists.py), which scopes
 * them to the caller's team. The quantity rule is in
 * app/lib/core/pick_list.dart and shared/fixtures/pick_list.json.
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
}

export interface PickList {
  name: string;
  salesOrder: string;
  customerName: string;
  salesPerson: string;
  team: string;
  status: string;
  pickedOn: string;
  items: PickListItem[];
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
    customerName: str(m.customer_name) || str(m.customer),
    salesPerson: str(m.sales_person),
    team: str(m.team),
    status: str(m.status) || 'Submitted',
    pickedOn: str(m.picked_on),
    items: items.map((i) => ({
      salesOrderItem: str(i.sales_order_item),
      itemCode: str(i.item_code),
      itemName: str(i.item_name),
      unit: str(i.unit),
      orderedQty: num(i.ordered_qty),
      availableQty: num(i.available_qty),
      pickedQty: num(i.picked_qty),
    })),
  };
}

export async function listPickLists(salesOrder?: string): Promise<PickList[]> {
  const { data } = await http.get<{ message: Record<string, unknown>[] }>('/api/method/manna_pick_lists', {
    params: salesOrder ? { sales_order: salesOrder } : {},
  });
  return (data.message ?? []).map(toPickList);
}
