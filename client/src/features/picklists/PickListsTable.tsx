/** Pick lists as a plain table: one row per list, its products one per line. */
import type { PickList } from '@/api/pickLists';
import { Badge } from '@/components/ui';
import { amount, day, isPicked } from './format';

export function PickListsTable({ lists }: { lists: PickList[] }) {
  return (
    <div className="scroll-x">
      <table className="table pl-table">
        <thead>
          <tr>
            <th>Date</th>
            <th>Order No.</th>
            <th>Customer</th>
            <th>Rep</th>
            <th>Products</th>
            <th className="right">Qty</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {lists.map((l) => (
            <tr key={l.name}>
              <td className="nowrap">{day(l.pickedOn)}</td>
              <td className="nowrap">{l.sapSalesOrder || <span className="dim">Not in SAP yet</span>}</td>
              <td>{l.customerName || '—'}</td>
              <td className="nowrap">{l.salesPerson || '—'}</td>
              <td>
                {l.items.map((i) => (
                  <div key={i.salesOrderItem} className="pl-line" title={i.itemName}>
                    {i.itemName}
                  </div>
                ))}
              </td>
              <td className="right nowrap">
                {l.items.map((i) => (
                  <div key={i.salesOrderItem} className="pl-line">
                    <b>{amount(i.pickedQty, i.unit)}</b>
                  </div>
                ))}
              </td>
              <td>{isPicked(l) ? <Badge tone="ok">Picked</Badge> : <Badge tone="warn">On pick list</Badge>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
