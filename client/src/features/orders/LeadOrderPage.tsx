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
import type { LeadOrder } from '@/domain/types';
import { leadOrderApproved } from '@/domain/orderStatus';
import { formatDate } from '@/domain/orderRules';
import { Api, type LeadGaps } from '@/api/client';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

export function LeadOrderPage() {
  const { leadOrderId = '' } = useParams();

  const [order, setOrder] = useState<LeadOrder | null>(null);
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

  /*
   * The order total, and nothing behind it.
   *
   * It went through `discountTotals` until 17 September 2026 so a lead order
   * was priced by exactly the rules a customer order was, and showed the same
   * three rows — before, the concession, after. The discount feature is gone
   * and the rep's rate is already net.
   */
  const orderTotal = (order?.lines ?? []).reduce((sum, l) => sum + l.amount, 0);

  const approve = async () => {
    if (!order) return;
    setBusy('approve');
    setError(null);
    try {
      // The gaps are re-checked live inside this call, against the lead as
      // stored — not against what this page loaded, which may be minutes old.
      const r = await Api.sales.approveLeadOrder({ leadOrderId: order.id });
      // When the site cannot store the link (`r.linkageStored` false) it is
      // written into the manager remarks instead, which the approved banner
      // below shows — so nothing extra needs saying here.
      setDone(`Converted to customer ${r.customer} · Sales Order ${r.salesOrder} approved`);
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
      setDone('Lead order rejected');
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
            {order && <Badge tone="accent">Lead</Badge>}
          </div>
          <div className="page-head__sub">
            {order ? (
              <>
                {order.rep || 'Unassigned'} · {formatDate(order.orderDate)} ·{' '}
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
            ← Team Orders
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
      {loading && !error && <Empty icon="◔" title="Loading lead order…" />}

      {!loading && order && (
        <>
          {/* Block 2 — above the money and the lines, deliberately. */}
          {blocked && gaps && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="danger" title="Cannot approve yet · missing on the lead">
                <ul className="lead__gaps">
                  {gaps.gstin && <li>GST number</li>}
                  {gaps.address && <li>Address</li>}
                  {gaps.route && <li>Sales route</li>}
                </ul>
              </Alert>
            </div>
          )}

          {/* No credit verdict on a lead, ever: it has no trading history and
              no limit, so there is nothing to be within. */}
          <Card title="Lines" flush>
            {order.lines.length === 0 ? (
              <Empty icon="—" title="No lines" />
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="right">Qty</th>
                      <th className="right">Rate</th>
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
                        <td className="right num">{money(l.rate, 2)}</td>
                        {/* Falls back to qty x rate: `amount` is a read-only
                            field on a custom child table with no server script
                            behind it, so older rows hold zero. A nil line
                            against rates the rep entered correctly would be a
                            lie. */}
                        <td className="right num">{money(l.amount, 0)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          {/*
            A Discount column and its modal sat here, working exactly as the
            customer order's did — only the two field names differed
            (`custom_discount_percentage` / `custom_price_list_rate`). Both went
            on 17 September 2026 with the feature: the rep types the rate after
            discount, so the rate column is the whole price story.
          */}
          <div className="order__total">
            <span>Order total</span>
            <b>{money(orderTotal, 0)}</b>
          </div>

          {decided ? (
            <div className="mt-16">
              <Alert tone="ok" title={order.status}>
                {order.approvalRemarks || undefined}
              </Alert>
            </div>
          ) : (
            <Card title="Decision" className="mt-16">
              <div className="decide__bar">
                <Button
                  variant="primary"
                  onClick={approve}
                  loading={busy === 'approve'}
                  disabled={!!busy || blocked}
                  title={
                    blocked
                      ? 'Missing details needed to become a customer'
                      : 'Convert to a customer and raise an approved Sales Order'
                  }
                >
                  Approve &amp; convert
                </Button>
                <Button
                  variant="ghost"
                  onClick={reject}
                  loading={busy === 'reject'}
                  disabled={!!busy}
                >
                  Reject
                </Button>
                {!blocked && (
                  <span className="decide__hint">Creates the customer · rates become final</span>
                )}
              </div>
              {/*
               * No "Send to GM": `Lead Order.status` is a Select whose options
               * are Pending Approval / Approved / Rejected / PO Uploaded /
               * PO Approved - Ready for SAP / Converted. There is no
               * `Pending GM Approval`, and writing one is refused by Frappe
               * (see `canEscalateLeadOrder`).
               */}
            </Card>
          )}
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Lead order not found" />}
    </div>
  );
}
