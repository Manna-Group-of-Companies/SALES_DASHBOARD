/**
 * A2 (lead variant) — reviewing a lead order.
 *
 * Same decision as a Sales Order, different consequences, so it is a separate
 * screen rather than a branch inside one.
 *
 * Three things differ and each is load-bearing:
 *
 *   - **"Cannot approve yet" sits above everything**, because a missing GST
 *     number, address or route is the one thing that will stop the approval,
 *     and the manager should meet it before they have read the lines and made
 *     up their mind.
 *   - **No credit verdict, ever.** A lead has no trading history and no limit,
 *     so there is nothing to be within. A green "Within credit limit" against
 *     a party who has never been invoiced is a reassurance nobody earned, and
 *     reads as a check that passed rather than one that was never run. The
 *     order total alone, in neutral grey.
 *   - **Approving converts.** It creates the customer, raises the Sales Order
 *     already approved, and writes back — three writes, no transaction.
 */

import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { LeadOrder, LeadOrderLine } from '@/domain/types';
import { canEscalateLeadOrder, leadOrderApproved } from '@/domain/orderStatus';
import {
  MAX_DISCOUNT_PERCENT,
  discountRefusal,
  discountTotals,
  discountedRate,
} from '@/domain/discount';
import { formatDate } from '@/domain/orderRules';
import { Api, type LeadGaps } from '@/api/client';
import { Alert, Badge, Button, Card, Empty, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

export function LeadOrderPage() {
  const { leadOrderId = '' } = useParams();

  const [order, setOrder] = useState<LeadOrder | null>(null);
  /** The line whose discount is being set, and the figure typed so far. */
  const [discounting, setDiscounting] = useState<{ line: LeadOrderLine; typed: string } | null>(
    null,
  );
  const [gaps, setGaps] = useState<LeadGaps | null>(null);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.sales
      .getLeadOrder(leadOrderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);
        const g = await Api.sales.checkLeadGaps(o.lead).catch(() => null);
        if (live) setGaps(g);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read this lead order.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [leadOrderId, tick]);

  const blocked = gaps ? gaps.gstin || gaps.address || gaps.route : false;
  const decided = order ? leadOrderApproved(order.status) : false;

  const totals = discountTotals(
    (order?.lines ?? []).map((l) => ({
      qty: l.qty,
      rate: l.rate,
      amount: l.amount,
      custom_price_list_rate: l.priceListRate,
      custom_discount_percentage: l.discountPercent,
    })),
  );

  /**
   * Give, change or remove a discount on one lead-order line.
   *
   * Written the moment it is confirmed, exactly as on a customer order and
   * exactly as the phone does it. `isLead` is what picks the two field names;
   * every rule around it is the same.
   */
  const applyDiscount = async () => {
    if (!order || !discounting) return;
    const percent = Number(discounting.typed);
    const refusal = discountRefusal(percent);
    if (refusal) {
      setError(refusal);
      return;
    }
    setBusy('discount');
    setError(null);
    try {
      await Api.sales.setLineDiscount({
        orderId: order.id,
        lineId: discounting.line.id,
        percent,
        isLead: true,
      });
      setDone(percent > 0 ? `Discount of ${percent}% applied.` : 'Discount removed.');
      setDiscounting(null);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the discount.');
    } finally {
      setBusy(null);
    }
  };

  const approve = async () => {
    if (!order) return;
    setBusy('approve');
    setError(null);
    try {
      // The gaps are re-checked live inside this call, against the lead as
      // stored — not against what this page loaded, which may be minutes old.
      const r = await Api.sales.approveLeadOrder({ leadOrderId: order.id });
      setDone(
        `Converted to customer ${r.customer} and raised ${r.salesOrder}, already approved.${
          r.linkageStored
            ? ''
            : ' The link was recorded in the manager remarks — this site has no sales_order field on Lead Order.'
        }`,
      );
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not approve this lead order.');
    } finally {
      setBusy(null);
    }
  };

  const reject = async () => {
    if (!order) return;
    setBusy('reject');
    setError(null);
    try {
      await Api.sales.rejectLeadOrder(order.id);
      setDone('Rejected. Nothing was converted.');
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not reject this lead order.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {order ? order.leadName : 'Loading…'}{' '}
            {order && <Badge tone="accent">LEAD</Badge>}
          </div>
          <div className="page-head__sub">
            {order ? (
              <>
                Raised by {order.rep || 'unassigned'} on {formatDate(order.orderDate)} ·{' '}
                <span className="mono">{order.id}</span>
              </>
            ) : (
              leadOrderId
            )}
          </div>
        </div>
        <div className="cal__nav">
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/orders" className="btn btn--ghost btn--sm">
            ← Team orders
          </Link>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}
      {loading && !error && <Empty icon="◔" title="Reading lead order…" />}

      {!loading && order && (
        <>
          {/* Block 2 — above the money and the lines, deliberately. */}
          {blocked && gaps && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="danger" title="Cannot approve yet">
                <p style={{ margin: '0 0 6px' }}>
                  This lead becomes a customer on approval and is invoiced from there, so it needs:
                </p>
                <ul className="lead__gaps">
                  {gaps.gstin && <li>GST number</li>}
                  {gaps.address && <li>Address</li>}
                  {gaps.route && <li>Sales route</li>}
                </ul>
                <p className="note" style={{ margin: '6px 0 0' }}>
                  Ask the rep to add them on the lead, or edit the lead yourself.
                </p>
              </Alert>
            </div>
          )}

          {/* Block 3 — the total alone. No credit verdict on a lead. */}
          <div className="lead__total">
            <span className="dim">Order total</span>
            <b className="num">{money(order.total, 0)}</b>
            <span className="note">
              A lead has no trading history and no credit limit, so there is nothing to check this
              against.
            </span>
          </div>

          <Card title="Lines" flush>
            {order.lines.length === 0 ? (
              <Empty icon="—" title="This lead order has no lines" />
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="right">Qty</th>
                      <th className="right">Rate</th>
                      <th className="right">Disc %</th>
                      <th className="right">Amount</th>
                    </tr>
                  </thead>
                  <tbody>
                    {order.lines.map((l) => (
                      <tr key={l.id}>
                        <td>
                          <div>{l.itemName}</div>
                          <div className="mono tiny dim">{l.itemCode}</div>
                        </td>
                        <td className="right num">{l.qty}</td>
                        <td className="right num">
                          {l.discountPercent > 0 ? (
                            <>
                              <div className="line__was">{money(l.priceListRate, 2)}</div>
                              <b>{money(l.rate, 2)}</b>
                            </>
                          ) : (
                            money(l.rate, 2)
                          )}
                        </td>
                        <td className="right">
                          {/*
                            Same control and the same rules as a customer order,
                            only the two field names differ — `domain/discount.ts`
                            is the only place that knows which. Once the lead
                            order is decided this states what was given and
                            offers no way in, to everybody including the GM.
                          */}
                          {decided ? (
                            l.discountPercent > 0 ? (
                              <span className="tiny disc__final">{l.discountPercent}% off. Final.</span>
                            ) : (
                              <span className="dim">—</span>
                            )
                          ) : (
                            <button
                              type="button"
                              className="btn btn--ghost btn--sm"
                              disabled={!!busy}
                              onClick={() =>
                                setDiscounting({
                                  line: l,
                                  typed: l.discountPercent > 0 ? String(l.discountPercent) : '',
                                })
                              }
                            >
                              {l.discountPercent > 0 ? `${l.discountPercent}% off · Change` : 'Discount'}
                            </button>
                          )}
                        </td>
                        {/* Falls back to qty x rate: `amount` is a read-only
                            field on a custom child table with no server script
                            behind it, so older rows hold zero. A nil line
                            against rates the rep entered correctly would be a
                            lie. */}
                        <td className="right num">
                          {l.discountPercent > 0 ? (
                            <>
                              <div className="line__was">{money(l.amountBeforeDiscount, 0)}</div>
                              <b className="exp__corrected">{money(l.amount, 0)}</b>
                            </>
                          ) : (
                            money(l.amount, 0)
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          {totals.hasDiscount && (
            <div className="order__totals mt-16">
              <div className="order__total order__total--was">
                <span>Order before discount</span>
                <span>{money(totals.beforeDiscount, 0)}</span>
              </div>
              <div className="order__total order__total--off">
                <span>Discount ({totals.discountPercent}%)</span>
                <span>−{money(totals.discount, 0)}</span>
              </div>
              <div className="order__total">
                <span>Order after discount</span>
                <b>{money(totals.afterDiscount, 0)}</b>
              </div>
            </div>
          )}

          {discounting && (
            (() => {
              const base = discounting.line.priceListRate;
              const typed = Number(discounting.typed);
              const blank = discounting.typed.trim() === '';
              const refusal = blank ? null : discountRefusal(typed);
              return (
                <div className="disc__scrim" role="dialog" aria-modal="true" aria-label="Discount">
                  <Card title="Discount">
                    <p className="note">{discounting.line.itemName}</p>
                    <Input
                      autoFocus
                      numeric
                      type="number"
                      min={0}
                      max={MAX_DISCOUNT_PERCENT}
                      step="0.5"
                      aria-label="Discount percent"
                      placeholder="Discount %"
                      value={discounting.typed}
                      onChange={(e) =>
                        setDiscounting((cur) => (cur ? { ...cur, typed: e.target.value } : cur))
                      }
                      onKeyDown={(e) => e.key === 'Escape' && setDiscounting(null)}
                    />
                    <p className="note">
                      {money(base, 2)} → <b>{money(discountedRate(base, blank ? 0 : typed), 2)}</b>{' '}
                      per unit
                    </p>
                    {refusal && <Alert tone="warn">{refusal}</Alert>}
                    <div className="line__edit-bar">
                      <Button variant="ghost" onClick={() => setDiscounting(null)}>
                        Cancel
                      </Button>
                      <Button
                        onClick={applyDiscount}
                        disabled={!!refusal || busy === 'discount'}
                        loading={busy === 'discount'}
                      >
                        {blank || typed === 0 ? 'Remove discount' : 'Apply'}
                      </Button>
                    </div>
                  </Card>
                </div>
              );
            })()
          )}

          <p className="note" style={{ marginTop: 10 }}>
            A lead order carries no roll or belt breakdown and no stock bookings, so the Sales Order
            this raises always reads as new production.
          </p>

          {decided ? (
            <div className="mt-16">
              <Alert tone="ok" title={`✓ ${order.status}`}>
                {order.approvalRemarks || 'Nothing further to decide.'}
              </Alert>
            </div>
          ) : (
            <Card title="Decision" className="mt-16">
              <p className="note" style={{ marginBottom: 10 }}>
                Approving converts the lead to a customer, raises a Sales Order against it already
                approved, and fixes every rate permanently.
              </p>
              <div className="lv__actions" style={{ justifyContent: 'flex-start', gap: 8 }}>
                <Button
                  onClick={approve}
                  loading={busy === 'approve'}
                  disabled={!!busy || blocked}
                  title={
                    blocked
                      ? 'The lead is missing details it needs as a customer'
                      : 'Convert and raise the Sales Order'
                  }
                >
                  Approve &amp; convert
                </Button>
                <Button variant="ghost" onClick={reject} disabled={!!busy}>
                  Reject
                </Button>
              </div>
              {/*
               * No "Send to GM": `Lead Order.status` is a Select whose options
               * are Pending Approval / Approved / Rejected / PO Uploaded /
               * PO Approved - Ready for SAP / Converted. There is no
               * `Pending GM Approval`, and writing one is refused by Frappe.
               */}
              {!canEscalateLeadOrder() && (
                <p className="note" style={{ marginTop: 10 }}>
                  A lead order cannot be escalated to the GM: its status field has no such option on
                  this site. Escalation would have to be added to the `Lead Order.status` Select
                  first.
                </p>
              )}
            </Card>
          )}
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Lead order not found" />}
    </div>
  );
}
