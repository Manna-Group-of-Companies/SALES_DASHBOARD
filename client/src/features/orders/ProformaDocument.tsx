/**
 * The printable proforma (1.3).
 *
 * Letterhead constants mirror the Flutter app's `core/constants.dart` so the
 * document the customer receives is the same one they already know. Customer
 * address and GSTIN come from the Excel import — they are required, which is
 * why the importer refuses rows missing either.
 */

import { proformaCells } from '@/domain/proforma';
import type { ProductCategory } from '@/domain/types';
import type { Customer } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import { money } from '@/components/common/format';

// --- Hi-Tech Pretreads letterhead. Other units get their own block later. ---
const CO = {
  name: 'MANNA TREADS',
  address: 'VIII/67-C, PVIP Canal Road Keezhillam\nErnakulam-683541\nKerala, India',
  gst: '32AEJPM5698B1ZF',
  pan: 'AEJPM5698B',
  bank: 'CANARA BANK',
  branch: 'M G Road Ernakulam',
  account: '125002176279',
  ifsc: 'CNRB0014301',
  jurisdiction: 'SUBJECT TO PERUMBAVOOR JURISDICTION',
};

/*
 * No GST constant any more. The rate a rep quotes already includes tax, so a
 * breakup on a proforma would either restate the same money or invite somebody
 * to add it a second time. Tax is settled on the invoice, not on a quote.
 */

export interface ProformaLine {
  itemName: string;
  quantity: number;
  uom: string;
  rate: number;
  amount: number;
  category: ProductCategory;
  /** Packing counts. Columns now, not a sentence under the name. */
  rolls?: number;
  belts?: number;
  tins?: number;
  /** Total weight in kg, or litres for solution. */
  weight?: number;
  /** Per-kilogram rate, when the line was quoted that way. */
  ratePerKg?: number;
}

export function ProformaDocument({
  customer,
  lines,
  deliveryDate,
  proformaNo,
  orderNo,
}: {
  customer: Customer;
  lines: ProformaLine[];
  deliveryDate: string;
  proformaNo: string;
  orderNo?: string;
}) {
  const subtotal = lines.reduce((s, l) => s + l.amount, 0);

  return (
    <div className="proforma">
      <div className="proforma__head">
        <div>
          <h2>{CO.name}</h2>
          <div style={{ whiteSpace: 'pre-line', marginTop: 4 }}>{CO.address}</div>
          <div style={{ marginTop: 4 }}>
            <strong>GSTIN:</strong> {CO.gst} &nbsp; <strong>PAN:</strong> {CO.pan}
          </div>
        </div>
        <div className="right">
          <div style={{ fontSize: 15, fontWeight: 700, letterSpacing: '0.04em' }}>PROFORMA INVOICE</div>
          <div style={{ marginTop: 6 }}>
            <strong>No:</strong> {proformaNo}
          </div>
          {orderNo && (
            <div>
              <strong>Order:</strong> {orderNo}
            </div>
          )}
          <div>
            <strong>Date:</strong> {formatDate(new Date().toISOString().slice(0, 10))}
          </div>
          <div>
            <strong>Delivery:</strong> {deliveryDate ? formatDate(deliveryDate) : '—'}
          </div>
        </div>
      </div>

      <div className="proforma__parties">
        <div>
          <div className="proforma__label">Bill to</div>
          <div style={{ fontWeight: 700, marginTop: 3 }}>{customer.name}</div>
          <div style={{ whiteSpace: 'pre-line' }}>{customer.address || '—'}</div>
          <div style={{ marginTop: 3 }}>
            <strong>GSTIN:</strong> {customer.gstin || '—'}
          </div>
          {customer.state && (
            <div>
              <strong>State:</strong> {customer.state}
            </div>
          )}
        </div>
        <div>
          <div className="proforma__label">Ship to</div>
          <div style={{ fontWeight: 700, marginTop: 3 }}>{customer.destination}</div>
          {customer.phone && <div style={{ marginTop: 3 }}>Ph: {customer.phone}</div>}
        </div>
      </div>

      <table>
        <thead>
          <tr>
            <th style={{ width: 28 }}>#</th>
            <th>Description</th>
            <th className="right" style={{ width: 52 }}>Rolls</th>
            <th className="right" style={{ width: 52 }}>Belts</th>
            <th className="right" style={{ width: 52 }}>Cans</th>
            <th className="right" style={{ width: 86 }}>Qty</th>
            <th className="right" style={{ width: 86 }}>MRP</th>
            <th className="right" style={{ width: 100 }}>Amount</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l, i) => {
            /*
              Every figure comes out of `domain/proforma.ts`, which the phone's
              PDF renderer also uses. A column that differed between the two
              would be a customer sent two versions of the same quote.
            */
            const c = proformaCells({
              custom_product_category: l.category,
              custom_rolls: l.rolls,
              custom_loose_belts: l.belts,
              custom_total_weight: l.weight,
              custom_rate_per_kg: l.ratePerKg,
              qty: l.category === 'VS' ? (l.tins ?? l.quantity) : l.quantity,
              /*
                Solution is billed by the can, and callers disagree about what
                `rate` means on it — per litre in one place, per tin in another.
                Deriving it from the amount is the only way the printed row is
                guaranteed to multiply out, which is the property a customer
                checks it by.
              */
              rate:
                l.category === 'VS' && l.tins
                  ? Math.round((l.amount / l.tins) * 100) / 100
                  : l.rate,
              amount: l.amount,
            });
            return (
              <tr key={`${l.itemName}-${i}`}>
                <td>{i + 1}</td>
                {/* The item name alone. The packing breakdown used to be a
                    second line here; it is a set of quantities, and now has
                    columns of its own. */}
                <td style={{ fontWeight: 600 }}>{l.itemName}</td>
                <td className="right">{c.rolls}</td>
                <td className="right">{c.belts}</td>
                <td className="right">{c.cans}</td>
                <td className="right">{c.qty}</td>
                <td className="right">
                  {money(c.mrp, 2)}
                  {/* The unit sits under the figure so the row can be checked:
                      tread rubber and gum multiply out on Qty, solution on
                      Cans. */}
                  {c.mrpUnit && (
                    <div style={{ fontSize: 9, color: '#666' }}>{c.mrpUnit}</div>
                  )}
                </td>
                <td className="right">{money(c.amount, 2)}</td>
              </tr>
            );
          })}
          {lines.length === 0 && (
            <tr>
              <td colSpan={8} style={{ textAlign: 'center', color: '#999' }}>
                No items
              </td>
            </tr>
          )}
          {/* The total belongs to the table it totals. A customer reading down
              the Amount column should find the sum at the bottom of it, not in
              a separate box further down the page.

              No tax rows: the rate a rep quotes already includes GST, so a
              breakup here would either restate the same money or invite
              somebody to add it twice. Tax is settled on the invoice. */}
          {lines.length > 0 && (
            <tr style={{ fontWeight: 700, background: '#f1f1f1' }}>
              <td />
              <td>Total</td>
              <td colSpan={5} />
              <td className="right">{money(subtotal, 2)}</td>
            </tr>
          )}
        </tbody>
      </table>

      <div className="proforma__foot">
        <div>
          <div className="proforma__label">Bank details</div>
          <div>
            {CO.bank}, {CO.branch}
          </div>
          <div>
            A/C {CO.account} · IFSC {CO.ifsc}
          </div>
          <div style={{ marginTop: 6 }}>{CO.jurisdiction}</div>
        </div>
        <div className="right">
          <div style={{ marginTop: 28 }}>For {CO.name}</div>
          <div style={{ marginTop: 22, borderTop: '1px solid #999', paddingTop: 3 }}>
            Authorised Signatory
          </div>
        </div>
      </div>
    </div>
  );
}
