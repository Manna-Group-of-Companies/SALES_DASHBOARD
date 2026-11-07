import type { PickList } from '@/api/pickLists';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** `2026-11-05 14:02:29` → `05 Nov 2026`. */
export function day(s: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : s;
}

const qty = (v: number) => (Number.isInteger(v) ? String(v) : v.toFixed(2));

/** `1 roll`, `3 rolls`, `50 Kg`. */
export const amount = (v: number, unit: string) => `${qty(v)} ${v === 1 && unit === 'rolls' ? 'roll' : unit}`.trim();

/** SAP has made the delivery for it: its products are picked. */
export const isPicked = (l: PickList) => l.status === 'Submitted' && !!l.mtDelivery.trim();

/** Matches a search box against a list's order, rep, customer and products. */
export function matches(l: PickList, q: string): boolean {
  if (!q) return true;
  return [l.sapSalesOrder, l.salesPerson, l.customerName, ...l.items.map((i) => i.itemName)]
    .join(' ')
    .toLowerCase()
    .includes(q.trim().toLowerCase());
}
