/**
 * The Sales Manager's review (2.1 – 2.3). Three decisions in one place:
 *
 *  1. Final rate per line. This is the last moment it can ever be changed (2.2),
 *     so the button says so and the confirm step spells it out.
 *  2. Minimum stock vs. new production, per line (2.3) — how an important
 *     customer gets served faster than everyone else.
 *  3. Whether the customer's credit can carry the order at all (2.1), with the
 *     outstanding balance and headroom on screen rather than in another tab.
 *
 * The aged-stock panel is right here in the review, so a swap onto old stock is
 * a decision the manager can make while approving rather than a separate errand.
 */

import { useMemo, useState } from 'react';
import type { FulfilmentSource, Order } from '@/domain/types';
import { effectiveDeliveryDate, formatDate } from '@/domain/orderRules';
import { computeLine, rateUnitFor, round2 } from '@/domain/productRules';
import { availableQty } from '@/domain/aging';
import { checkCredit } from '@/api/client';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  selectCustomers,
  selectMinStockByCode,
  selectMinStockItems,
  selectProducts,
  selectUser,
} from '@/store/selectors';
import { approveOrder, rejectOrder } from '@/store/slices/ordersSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import {
  Alert,
  Badge,
  Button,
  Card,
  Field,
  Input,
  Meter,
  Modal,
  Segmented,
  Textarea,
} from '@/components/ui';
import { money } from '@/components/common/format';
import { AgingPanel } from '@/features/stock/AgingPanel';
import { describeEntry } from '@/features/orders/OrderDetailPage';

export function ApprovalReviewModal({ order, onClose }: { order: Order; onClose: () => void }) {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const customers = useAppSelector(selectCustomers);
  const products = useAppSelector(selectProducts);
  const minStockByCode = useAppSelector(selectMinStockByCode);
  const minStockItems = useAppSelector(selectMinStockItems);
  const saving = useAppSelector((s) => s.orders.saving);

  const customer = customers.find((c) => c.id === order.customerId);
  const productByCode = useMemo(() => new Map(products.map((p) => [p.code, p])), [products]);

  // Seed the final rate with the rep's quote — the common case is confirming it.
  const [rates, setRates] = useState<Record<string, number>>(() =>
    Object.fromEntries(order.items.map((i) => [i.id, i.finalRate ?? i.quotedRate])),
  );
  const [sources, setSources] = useState<Record<string, FulfilmentSource>>(() =>
    Object.fromEntries(
      order.items.map((i) => {
        // Default to minimum stock only where the shelf can actually cover the
        // line. `onHand`, not `availableQty` — the quantity this very order is
        // holding is part of `reserved` and must not count against itself.
        const stock = minStockByCode.get(i.itemCode);
        const canServe = Boolean(stock && stock.onHand >= i.quantity);
        return [i.id, i.source ?? (canServe ? 'min_stock' : 'new_production')];
      }),
    ),
  );
  const [confirming, setConfirming] = useState(false);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState('');

  const total = useMemo(
    () =>
      round2(
        order.items.reduce((sum, item) => {
          const rate = rates[item.id] ?? item.quotedRate;
          return sum + (item.category === 'VS' ? (item.tins ?? 0) * rate : item.quantity * rate);
        }, 0),
      ),
    [order.items, rates],
  );

  const quotedTotal = useMemo(
    () =>
      round2(
        order.items.reduce(
          (sum, item) =>
            sum +
            (item.category === 'VS'
              ? (item.tins ?? 0) * item.quotedRate
              : item.quantity * item.quotedRate),
          0,
        ),
      ),
    [order.items],
  );

  const credit = customer ? checkCredit(customer, total) : null;
  const delta = total - quotedTotal;

  const approve = async () => {
    if (!user) return;
    const result = await dispatch(approveOrder({ orderId: order.id, user, finalRates: rates, sources }));
    if (approveOrder.fulfilled.match(result)) {
      dispatch(pushToast(`${order.orderNo} approved — rates are now locked.`, 'success'));
      onClose();
    }
  };

  const reject = async () => {
    if (!user || !reason.trim()) return;
    const result = await dispatch(
      rejectOrder({ orderId: order.id, reason: reason.trim(), user }),
    );
    if (rejectOrder.fulfilled.match(result)) {
      dispatch(pushToast(`${order.orderNo} rejected.`, 'warning'));
      onClose();
    }
  };

  if (confirming) {
    return (
      <Modal
        title="Confirm approval"
        onClose={() => setConfirming(false)}
        footer={
          <>
            <Button onClick={() => setConfirming(false)}>Back</Button>
            <Button variant="primary" loading={saving} onClick={() => void approve()}>
              Approve &amp; lock rates
            </Button>
          </>
        }
      >
        <Alert tone="warn" title="Rates lock permanently">
          Approving {order.orderNo} fixes every rate on it. Nobody — you, the rep, or production —
          can change a rate afterwards. Items and quantities stay editable until 1:00 PM on{' '}
          {formatDate(effectiveDeliveryDate(order))}.
        </Alert>

        <div className="stack gap-2" style={{ marginTop: 14 }}>
          {order.items.map((item) => (
            <div key={item.id} className="row gap-2 small">
              <span className="grow">{item.itemName}</span>
              <Badge tone={sources[item.id] === 'min_stock' ? 'ok' : 'accent'}>
                {sources[item.id] === 'min_stock' ? 'Min stock' : 'New production'}
              </Badge>
              <span className="num strong" style={{ minWidth: 90, textAlign: 'right' }}>
                {money(rates[item.id] ?? item.quotedRate, 2)} {rateUnitFor(item.category)}
              </span>
            </div>
          ))}
          <div className="row gap-2" style={{ borderTop: '1px solid var(--border)', paddingTop: 8 }}>
            <span className="grow strong">Order value</span>
            <span className="num strong" style={{ fontSize: 16 }}>
              {money(total, 2)}
            </span>
          </div>
        </div>

        {credit?.breaches && (
          <div style={{ marginTop: 14 }}>
            <Alert tone="danger" title="Credit limit exceeded">
              {customer!.name} is {money(Math.abs(credit.headroom - total))} beyond their limit with
              this order. Approving anyway is your call.
            </Alert>
          </div>
        )}
      </Modal>
    );
  }

  if (rejecting) {
    return (
      <Modal
        title={`Reject ${order.orderNo}`}
        onClose={() => setRejecting(false)}
        footer={
          <>
            <Button onClick={() => setRejecting(false)}>Back</Button>
            <Button
              variant="danger"
              loading={saving}
              disabled={!reason.trim()}
              onClick={() => void reject()}
            >
              Reject order
            </Button>
          </>
        }
      >
        <Field label="Reason" hint="The rep sees this, so be specific.">
          <Textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. customer is over their credit limit — collect against the outstanding first"
          />
        </Field>
      </Modal>
    );
  }

  return (
    <Modal
      title={`Review ${order.orderNo}`}
      width="xwide"
      onClose={onClose}
      footer={
        <>
          <div className="grow row gap-3">
            <span className="muted small">Final value</span>
            <strong className="num" style={{ fontSize: 16 }}>
              {money(total, 2)}
            </strong>
            {delta !== 0 && (
              <Badge tone={delta < 0 ? 'warn' : 'ok'}>
                {delta > 0 ? '+' : ''}
                {money(delta, 2)} vs quoted
              </Badge>
            )}
          </div>
          <Button variant="danger" onClick={() => setRejecting(true)}>
            Reject
          </Button>
          <Button variant="primary" onClick={() => setConfirming(true)}>
            Approve…
          </Button>
        </>
      }
    >
      <div className="cols cols--sidebar">
        <div className="stack gap-4">
          {/* ------------------------------------------ credit check --- */}
          {customer && credit && (
            <Card title="Customer standing">
              <div className="row gap-4 wrap">
                <Metric label="Outstanding" value={money(credit.outstanding)} />
                <Metric label="Credit limit" value={money(credit.limit)} />
                <Metric
                  label="Headroom"
                  value={money(credit.headroom)}
                  tone={credit.headroom < 0 ? 'danger' : undefined}
                />
                <Metric label="This order" value={money(total)} />
              </div>
              <div style={{ marginTop: 10 }}>
                <Meter
                  value={credit.utilisation}
                  tone={credit.breaches ? 'danger' : credit.utilisation > 0.8 ? 'warn' : 'ok'}
                  label="Credit utilisation"
                />
              </div>
              {credit.breaches && (
                <div style={{ marginTop: 10 }}>
                  <Alert tone="danger" title="Order exceeds available credit">
                    Headroom is {money(credit.headroom)} but this order is {money(total)}. Consider
                    trimming items or collecting first.
                  </Alert>
                </div>
              )}
            </Card>
          )}

          {/* ------------------------------- rates + fulfilment source --- */}
          <Card title="Lines — set the final rate and where stock comes from" flush>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th>Entered</th>
                    <th className="right">Quantity</th>
                    <th className="right">Rep quoted</th>
                    <th style={{ width: 130 }}>Final rate</th>
                    <th style={{ width: 190 }}>Fulfil from</th>
                    <th className="right">Amount</th>
                  </tr>
                </thead>
                <tbody>
                  {order.items.map((item) => {
                    const stock = minStockByCode.get(item.itemCode);
                    // Free to *this* order: on hand, less holds other orders
                    // have placed. Its own hold is already part of `reserved`.
                    const free = stock ? Math.max(0, availableQty(stock) + item.quantity) : 0;
                    const canServeFromStock = Boolean(stock && stock.onHand >= item.quantity);
                    const rate = rates[item.id] ?? item.quotedRate;
                    const product = productByCode.get(item.itemCode);
                    const amount = product
                      ? computeLine(product, {
                          rolls: item.rolls,
                          looseBelts: item.looseBelts,
                          kg: item.kg,
                          tins: item.tins,
                          tinSize: item.tinSize,
                          rate,
                        }).amount
                      : item.quantity * rate;

                    return (
                      <tr key={item.id}>
                        <td>
                          <div className="strong small">{item.itemName}</div>
                          <div className="tiny dim mono">{item.itemCode}</div>
                        </td>
                        <td className="small muted">{describeEntry(item)}</td>
                        <td className="right num">
                          {item.quantity.toLocaleString('en-IN', { maximumFractionDigits: 3 })}{' '}
                          {item.uom}
                        </td>
                        <td className="right num dim">{money(item.quotedRate, 2)}</td>
                        <td>
                          <Input
                            numeric
                            compact
                            type="number"
                            min={0}
                            step="0.01"
                            value={rate}
                            onChange={(e) =>
                              setRates((r) => ({ ...r, [item.id]: Number(e.target.value) || 0 }))
                            }
                          />
                          <div className="tiny dim right">{rateUnitFor(item.category)}</div>
                        </td>
                        <td>
                          {/* 2.3 — the prioritisation lever. */}
                          <Segmented
                            ariaLabel={`Fulfilment source for ${item.itemName}`}
                            value={sources[item.id]}
                            onChange={(v) => setSources((s) => ({ ...s, [item.id]: v }))}
                            options={[
                              { value: 'min_stock', label: 'Min stock' },
                              { value: 'new_production', label: 'Produce' },
                            ]}
                          />
                          {sources[item.id] === 'min_stock' && !canServeFromStock && (
                            <div className="tiny" style={{ color: 'var(--danger)', marginTop: 3 }}>
                              {stock
                                ? `Only ${round(free)} ${item.uom} on hand`
                                : 'Not a minimum-stock item'}
                            </div>
                          )}
                        </td>
                        <td className="right num strong">{money(amount, 2)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </Card>
        </div>

        <div className="stack gap-4">
          <Card title="Order">
            <div className="stack gap-2 small">
              <Row label="Customer" value={order.customerName} />
              <Row label="Destination" value={order.destination} />
              <Row label="Rep" value={order.repName} />
              <Row label="Delivery" value={formatDate(effectiveDeliveryDate(order))} />
              <Row
                label="Proforma"
                value={order.proformaGenerated ? (order.proformaNo ?? 'Generated') : 'Not generated'}
              />
              {order.notes && <Row label="Rep notes" value={order.notes} />}
            </div>
          </Card>

          {/* 2.1 — aged stock highlighted inside the review itself. */}
          <Card title="Aged stock available">
            <AgingPanel
              items={minStockItems}
              title="Swap a line onto these to clear old inventory (confirm with the customer first)."
            />
          </Card>
        </div>
      </div>
    </Modal>
  );
}

function Metric({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: 'danger';
}) {
  return (
    <div>
      <div className="detail-item__label">{label}</div>
      <div
        className="num"
        style={{
          fontSize: 17,
          fontWeight: 650,
          color: tone === 'danger' ? 'var(--danger)' : undefined,
        }}
      >
        {value}
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="row gap-2">
      <span className="muted grow">{label}</span>
      <span className="strong right">{value}</span>
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
