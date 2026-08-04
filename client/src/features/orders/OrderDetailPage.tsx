/**
 * Order detail — the one screen every role shares.
 *
 * What it shows changes by role, but the underlying record does not:
 *  - A Production Manager sees the destination and never the customer (3.1).
 *  - Rates render read-only the moment they are locked (2.2).
 *  - Item editing stays open to rep and Sales Manager right through production,
 *    and shuts at 1:00 PM on the delivery date for everyone (3.3).
 *  - Delivery-date changes made by production are surfaced back here (3.2).
 */

import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import type { Order, OrderItem } from '@/domain/types';
import { ACTOR_ROLE_LABEL } from '@/domain/types';
import {
  canEditItems,
  customerLabelFor,
  effectiveDeliveryDate,
  formatDate,
  formatDateTime,
  formatFreezeCountdown,
  freezeUrgency,
  isRateLocked,
  canSeeCustomerIdentity,
} from '@/domain/orderRules';
import { lineAmount, orderTotal, rateUnitFor } from '@/domain/productRules';
import { stageLabel, stagesFor } from '@/domain/processStages';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectCustomers, selectOrders, selectUser } from '@/store/selectors';
import { acknowledgeChange } from '@/store/slices/ordersSlice';
import { Alert, Badge, Button, Card, Empty, Modal } from '@/components/ui';
import { money, relativeTime } from '@/components/common/format';
import { FreezeChip, SourceBadge, StatusBadge } from '@/components/common/StatusBadge';
import { EditItemsModal } from './EditItemsModal';
import { ProformaDocument } from './ProformaDocument';
import './orders.css';

export function OrderDetailPage() {
  const { orderId } = useParams<{ orderId: string }>();
  const navigate = useNavigate();
  const dispatch = useAppDispatch();

  const user = useAppSelector(selectUser);
  const orders = useAppSelector(selectOrders);
  const customers = useAppSelector(selectCustomers);

  const [editing, setEditing] = useState(false);
  const [showProforma, setShowProforma] = useState(false);

  const order = orders.find((o) => o.id === orderId);
  const customer = customers.find((c) => c.id === order?.customerId);

  const permission = useMemo(
    () => (order && user ? canEditItems(order, user) : null),
    [order, user],
  );

  if (!user) return null;
  if (!order) {
    return (
      <Empty
        icon="📄"
        title="Order not found"
        action={<Button onClick={() => navigate('/orders')}>Back to orders</Button>}
      />
    );
  }

  const showCustomer = canSeeCustomerIdentity(user);
  const urgency = freezeUrgency(order);
  const pendingAcks = order.timeline.filter((t) => t.requiresAck && !t.ackedAt);
  const total = orderTotal(order.items);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="row gap-2 wrap">
            <span className="page-head__title">{order.orderNo}</span>
            <StatusBadge status={order.status} />
            <FreezeChip order={order} />
          </div>
          <div className="page-head__sub">
            {customerLabelFor(order, user)} · raised by {order.repName} ·{' '}
            {formatDateTime(order.createdAt)}
          </div>
        </div>

        <div className="row gap-2">
          <Button variant="ghost" onClick={() => navigate(-1)}>
            ← Back
          </Button>
          {order.proformaGenerated && showCustomer && (
            <Button onClick={() => setShowProforma(true)}>View proforma</Button>
          )}
          {permission?.allowed && (
            <Button variant="primary" onClick={() => setEditing(true)}>
              Edit items
            </Button>
          )}
        </div>
      </div>

      {/* --- why editing is closed, when it is ---------------------------- */}
      {permission && !permission.allowed && permission.reason === 'frozen' && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="danger" title="Order frozen" icon="🔒">
            {permission.message}
          </Alert>
        </div>
      )}
      {urgency === 'imminent' && permission?.allowed && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="warn" title="Edit window closing">
            Changes must be made before 1:00 PM on {formatDate(effectiveDeliveryDate(order))} —{' '}
            {formatFreezeCountdown(order)}.
          </Alert>
        </div>
      )}

      {/* --- post-approval changes the floor has not seen yet (3.3) ------- */}
      {pendingAcks.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <Alert
            tone="danger"
            title={`${pendingAcks.length} change${pendingAcks.length === 1 ? '' : 's'} after approval`}
            actions={
              user.role === 'production_manager' ? (
                <Button
                  size="sm"
                  variant="danger"
                  onClick={() =>
                    pendingAcks.forEach((t) =>
                      dispatch(acknowledgeChange({ orderId: order.id, timelineId: t.id, user })),
                    )
                  }
                >
                  Acknowledge all
                </Button>
              ) : undefined
            }
          >
            {pendingAcks.map((t) => (
              <div key={t.id} className="small">
                {t.detail ?? t.action} — {relativeTime(t.at)}
              </div>
            ))}
            {user.role !== 'production_manager' && (
              <div className="tiny dim" style={{ marginTop: 4 }}>
                Waiting on the Production Manager to acknowledge.
              </div>
            )}
          </Alert>
        </div>
      )}

      {order.status === 'rejected' && order.rejectionReason && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="danger" title="Rejected by the Sales Manager">
            {order.rejectionReason}
          </Alert>
        </div>
      )}

      <div className="cols cols--sidebar">
        <div className="stack gap-4">
          {/* ------------------------------------------------- items --- */}
          <Card title={`Items (${order.items.length})`} flush>
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th>Entered</th>
                    <th className="right">Quantity</th>
                    <th className="right">Rate</th>
                    <th className="right">Amount</th>
                    <th>Source</th>
                    {(order.status === 'in_production' ||
                      order.status === 'approved' ||
                      order.status === 'dispatched') && <th>Stage</th>}
                  </tr>
                </thead>
                <tbody>
                  {order.items.map((item) => (
                    <ItemRow key={item.id} item={item} order={order} />
                  ))}
                </tbody>
              </table>
            </div>
            <div
              className="row gap-3"
              style={{ padding: '12px 14px', borderTop: '1px solid var(--border)' }}
            >
              <span className="grow muted small">Order value</span>
              <span style={{ fontSize: 19, fontWeight: 700 }} className="num">
                {money(total, 2)}
              </span>
            </div>
          </Card>

          {/* --------------------------------------------- timeline --- */}
          <Card title="History">
            <div className="timeline">
              {[...order.timeline].reverse().map((t) => (
                <div
                  key={t.id}
                  className={`tl-item ${t.requiresAck && !t.ackedAt ? 'is-alert' : ''} ${
                    t.ackedAt ? 'is-acked' : ''
                  }`}
                >
                  <div className="tl-item__action">{t.action}</div>
                  {t.detail && <div className="tl-item__detail">{t.detail}</div>}
                  <div className="tl-item__meta">
                    {t.actorName} · {ACTOR_ROLE_LABEL[t.actorRole]} · {formatDateTime(t.at)}
                  </div>
                  {t.requiresAck && (
                    <div style={{ marginTop: 4 }}>
                      {t.ackedAt ? (
                        <Badge tone="ok">Acknowledged by {t.ackedBy}</Badge>
                      ) : (
                        <Badge tone="danger">Awaiting production acknowledgement</Badge>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </Card>
        </div>

        {/* ------------------------------------------------- sidebar --- */}
        <div className="stack gap-4">
          <Card title="Details">
            <div className="detail-grid">
              <Detail label={showCustomer ? 'Customer' : 'Destination'}>
                {customerLabelFor(order, user)}
              </Detail>
              {showCustomer && <Detail label="Destination">{order.destination}</Detail>}
              {showCustomer && customer && (
                <Detail label="GSTIN">
                  <span className="mono">{customer.gstin || '—'}</span>
                </Detail>
              )}
              <Detail label="Requested delivery">{formatDate(order.deliveryDate)}</Detail>
              {order.revisedDeliveryDate && (
                <Detail label="Revised delivery">
                  <span style={{ color: 'var(--warn)', fontWeight: 600 }}>
                    {formatDate(order.revisedDeliveryDate)}
                  </span>
                </Detail>
              )}
              {/* Immutable, by rule (1.7, 3.2). */}
              <Detail label="Created">{formatDateTime(order.createdAt)}</Detail>
              {order.approvedAt && (
                <Detail label="Approved">
                  {formatDateTime(order.approvedAt)}
                  <div className="tiny dim">by {order.approvedBy}</div>
                </Detail>
              )}
              <Detail label="Rep">{order.repName}</Detail>
              <Detail label="Proforma">
                {order.proformaGenerated ? (
                  <span className="mono">{order.proformaNo}</span>
                ) : (
                  <span className="dim">Not generated</span>
                )}
              </Detail>
            </div>
            {order.notes && (
              <div style={{ marginTop: 14 }}>
                <div className="detail-item__label">Notes</div>
                <div className="small" style={{ marginTop: 2 }}>
                  {order.notes}
                </div>
              </div>
            )}
          </Card>

          {/* Date moves the rep needs to know about (3.2). */}
          {order.deliveryDateHistory?.length ? (
            <Card title="Delivery date changes">
              <div className="stack gap-3">
                {order.deliveryDateHistory.map((h, i) => (
                  <div key={i}>
                    <div className="small strong">
                      {formatDate(h.from)} → {formatDate(h.to)}
                    </div>
                    <div className="tiny muted">{h.reason}</div>
                    <div className="tiny dim">
                      {h.changedBy} · {relativeTime(h.changedAt)}
                    </div>
                  </div>
                ))}
              </div>
            </Card>
          ) : null}

          <Card title="Rate policy">
            <p className="small muted">
              {order.approvedAt
                ? 'Rates were finalised by the Sales Manager at approval and are locked permanently. Items and quantities can still be changed until the freeze.'
                : 'Rates shown are the rep’s quote. The Sales Manager finalises them at approval, after which they can never be changed.'}
            </p>
          </Card>
        </div>
      </div>

      {editing && (
        <EditItemsModal order={order} user={user} onClose={() => setEditing(false)} />
      )}

      {showProforma && customer && (
        <Modal
          title={`Proforma ${order.proformaNo ?? ''}`}
          width="wide"
          onClose={() => setShowProforma(false)}
          footer={
            <>
              <Button onClick={() => setShowProforma(false)}>Close</Button>
              <Button variant="primary" onClick={() => window.print()}>
                Print
              </Button>
            </>
          }
        >
          <ProformaDocument
            customer={customer}
            orderNo={order.orderNo}
            proformaNo={order.proformaNo ?? 'PF-DRAFT'}
            deliveryDate={effectiveDeliveryDate(order)}
            lines={order.items.map((it) => ({
              itemName: it.itemName,
              detail: describeEntry(it),
              quantity: it.quantity,
              uom: it.uom,
              rate: it.finalRate ?? it.quotedRate,
              amount: lineAmount(it),
              category: it.category,
              tins: it.tins,
            }))}
          />
        </Modal>
      )}
    </div>
  );
}

function ItemRow({ item, order }: { item: OrderItem; order: Order }) {
  const locked = isRateLocked(item, order);
  const showStage =
    order.status === 'approved' || order.status === 'in_production' || order.status === 'dispatched';
  const stages = stagesFor(item.category);
  const current = stages.findIndex((s) => s.key === (item.stage ?? stages[0].key));

  return (
    <tr>
      <td>
        <div className="strong small">{item.itemName}</div>
        <div className="tiny dim mono">
          {item.itemCode} · {item.category}
        </div>
      </td>
      <td className="small muted">{describeEntry(item)}</td>
      <td className="right num">
        {item.quantity.toLocaleString('en-IN', { maximumFractionDigits: 3 })} {item.uom}
      </td>
      <td className="right num">
        {money(item.finalRate ?? item.quotedRate, 2)}
        <div className="tiny dim">
          {rateUnitFor(item.category)}
          {locked && ' · 🔒'}
        </div>
        {item.finalRate != null && item.finalRate !== item.quotedRate && (
          <div className="tiny dim">quoted {money(item.quotedRate, 2)}</div>
        )}
      </td>
      <td className="right num strong">{money(lineAmount(item), 2)}</td>
      <td>
        <SourceBadge source={item.source} />
      </td>
      {showStage && (
        <td style={{ minWidth: 140 }}>
          <div className="small">{stageLabel(item.category, item.stage)}</div>
          <div className="stage-track" style={{ marginTop: 4 }}>
            {stages.map((s, i) => (
              <span
                key={s.key}
                className={`stage-pip ${i < current ? 'is-done' : ''} ${i === current ? 'is-current' : ''}`}
              />
            ))}
          </div>
        </td>
      )}
    </tr>
  );
}

function Detail({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="detail-item__label">{label}</div>
      <div className="detail-item__value">{children}</div>
    </div>
  );
}

/** "12 rolls + 3 belts", "60 kg", "4 x 30L tins" — how the rep keyed it. */
export function describeEntry(item: OrderItem): string {
  switch (item.category) {
    case 'PCTR': {
      const parts: string[] = [];
      if (item.rolls) parts.push(`${item.rolls} roll${item.rolls === 1 ? '' : 's'}`);
      if (item.looseBelts) parts.push(`${item.looseBelts} belt${item.looseBelts === 1 ? '' : 's'}`);
      return parts.join(' + ') || '—';
    }
    case 'CTR':
      return `${item.rolls ?? 0} roll${item.rolls === 1 ? '' : 's'}`;
    case 'BG': {
      const kg = item.kg ?? item.quantity;
      const boxes = Math.floor(kg / 20);
      const rolls = Math.round((kg % 20) / 5);
      const parts: string[] = [];
      if (boxes) parts.push(`${boxes} box${boxes === 1 ? '' : 'es'}`);
      if (rolls) parts.push(`${rolls} roll${rolls === 1 ? '' : 's'}`);
      return parts.length ? `${parts.join(' + ')} (${kg} kg)` : `${kg} kg`;
    }
    case 'VS':
      return `${item.tins ?? 0} x ${item.tinSize ?? 10}L tin${(item.tins ?? 0) === 1 ? '' : 's'}`;
  }
}
