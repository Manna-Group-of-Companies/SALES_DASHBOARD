/**
 * The printable proforma (1.3).
 *
 * Letterhead constants mirror the Flutter app's `core/constants.dart` so the
 * document the customer receives is the same one they already know. Customer
 * address and GSTIN come from the Excel import — they are required, which is
 * why the importer refuses rows missing either.
 */

import type { ProductCategory } from '@/domain/types';
import type { Customer } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import { rateUnitFor } from '@/domain/productRules';
import { money } from '@/components/common/format';

// --- Hi-Tech Pretreads letterhead. Other units get their own block later. ---
const CO = {
  name: 'HI-TECH PRETREADS',
  address: 'VIII/67-C, PVIP Canal Road Keezhillam\nErnakulam-683541\nKerala, India',
  gst: '32AEJPM5698B1ZF',
  pan: 'AEJPM5698B',
  bank: 'CANARA BANK',
  branch: 'M G Road Ernakulam',
  account: '125002176279',
  ifsc: 'CNRB0014301',
  jurisdiction: 'SUBJECT TO PERUMBAVOOR JURISDICTION',
};

const GST_RATE = 0.18;

export interface ProformaLine {
  itemName: string;
  hsn?: string;
  detail: string;
  quantity: number;
  uom: string;
  rate: number;
  amount: number;
  category: ProductCategory;
  tins?: number;
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
  // Intra-state supply splits into CGST + SGST; inter-state is a single IGST.
  const interState = customer.state.trim().toLowerCase() !== 'kerala';
  const tax = subtotal * GST_RATE;
  const grand = subtotal + tax;

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
            <th style={{ width: 78 }}>HSN</th>
            <th className="right" style={{ width: 90 }}>Qty</th>
            <th className="right" style={{ width: 90 }}>Rate</th>
            <th className="right" style={{ width: 100 }}>Amount</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l, i) => (
            <tr key={`${l.itemName}-${i}`}>
              <td>{i + 1}</td>
              <td>
                <div style={{ fontWeight: 600 }}>{l.itemName}</div>
                <div style={{ fontSize: 10, color: '#666' }}>{l.detail}</div>
              </td>
              <td>{l.hsn ?? '—'}</td>
              <td className="right">
                {/* VS is billed per tin, so show tins with litres as context. */}
                {l.category === 'VS'
                  ? `${l.tins ?? 0} tin${(l.tins ?? 0) === 1 ? '' : 's'} (${l.quantity} L)`
                  : `${l.quantity.toLocaleString('en-IN', { maximumFractionDigits: 3 })} ${l.uom}`}
              </td>
              <td className="right">
                {money(l.rate, 2)}
                <div style={{ fontSize: 9, color: '#666' }}>{rateUnitFor(l.category)}</div>
              </td>
              <td className="right">{money(l.amount, 2)}</td>
            </tr>
          ))}
          {lines.length === 0 && (
            <tr>
              <td colSpan={6} style={{ textAlign: 'center', color: '#999' }}>
                No items
              </td>
            </tr>
          )}
        </tbody>
      </table>

      <div className="proforma__totals">
        <table>
          <tbody>
            <tr>
              <td>Subtotal</td>
              <td className="right">{money(subtotal, 2)}</td>
            </tr>
            {interState ? (
              <tr>
                <td>IGST @ 18%</td>
                <td className="right">{money(tax, 2)}</td>
              </tr>
            ) : (
              <>
                <tr>
                  <td>CGST @ 9%</td>
                  <td className="right">{money(tax / 2, 2)}</td>
                </tr>
                <tr>
                  <td>SGST @ 9%</td>
                  <td className="right">{money(tax / 2, 2)}</td>
                </tr>
              </>
            )}
            <tr style={{ fontWeight: 700, background: '#f1f1f1' }}>
              <td>Grand Total</td>
              <td className="right">{money(grand, 2)}</td>
            </tr>
          </tbody>
        </table>
      </div>

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
