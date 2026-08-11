/**
 * The Production Manager's job sheet (3.1 – 3.3).
 *
 * Shows exactly what 3.1 lists — items, quantities, the finalised rate, whether
 * stock comes from minimum stock or a fresh run, the delivery date, and the
 * destination *instead of* the customer. Lets the manager do exactly what 3.2
 * allows — move each line along its process cycle and reschedule delivery — and
 * nothing more. The order's creation timestamp is displayed read-only with a
 * note saying why it cannot be edited.
 */

import { useState } from 'react';
import type { Order, OrderItem } from '@/domain/types';
import {
  canChangeDeliveryDate,
  customerLabelFor,
  effectiveDeliveryDate,
  formatDate,
  formatDateTime,
  todayIso,
} from '@/domain/orderRules';
import { lineAmount, rateUnitFor } from '@/domain/productRules';
import {
  isTerminalStage,
  nextStage,
  prevStage,
  stageIndex,
  stageLabel,
  stagesFor,
} from '@/domain/processStages';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import {
  acknowledgeChange,
  changeDeliveryDate,
  setItemStage,
} from '@/store/slices/ordersSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import {
  Alert,
  Badge,
  Button,
  Field,
  Input,
  Modal,
  Select,
  Textarea,
} from '@/components/ui';
import { money, relativeTime } from '@/components/common/format';
import { SourceBadge } from '@/components/common/StatusBadge';
import { describeEntry } from '@/domain/productRules';

export function ProductionOrderModal({ order, onClose }: { order: Order; onClose: () => void }) {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const saving = useAppSelector((s) => s.orders.saving);

  const [rescheduling, setRescheduling] = useState(false);
  const [newDate, setNewDate] = useState(effectiveDeliveryDate(order));
  const [reason, setReason] = useState('');

  if (!user) return null;

  const pendingAcks = order.timeline.filter((t) => t.requiresAck && !t.ackedAt);
  const canReschedule = canChangeDeliveryDate(order, user).allowed;

  const advance = async (item: OrderItem, stage: string) => {
    const result = await dispatch(
      setItemStage({ orderId: order.id, itemId: item.id, stage, user }),
    );
    if (setItemStage.fulfilled.match(result)) {
      dispatch(pushToast(`${item.itemName} → ${stageLabel(item.category, stage)}`, 'success'));
    }
  };

  const reschedule = async () => {
    if (!reason.trim()) return;
    const result = await dispatch(
      changeDeliveryDate({ orderId: order.id, newDate, reason: reason.trim(), user }),
    );
    if (changeDeliveryDate.fulfilled.match(result)) {
      dispatch(pushToast('Delivery date updated — the rep has been told.', 'warning'));
      setRescheduling(false);
      setReason('');
    }
  };

  if (rescheduling) {
    const direction = newDate > effectiveDeliveryDate(order) ? 'Postpone' : 'Prepone';
    return (
      <Modal
        title="Move the delivery date"
        onClose={() => setRescheduling(false)}
        footer={
          <>
            <Button onClick={() => setRescheduling(false)}>Cancel</Button>
            <Button
              variant="primary"
              loading={saving}
              disabled={!reason.trim() || newDate === effectiveDeliveryDate(order)}
              onClick={() => void reschedule()}
            >
              {direction} to {formatDate(newDate)}
            </Button>
          </>
        }
      >
        <div className="stack gap-3">
          <Alert tone="info">
            The rep and Sales Manager are notified immediately, and the new date becomes the one the
            edit freeze works to.
          </Alert>
          <Field label="Current delivery date">
            <Input value={formatDate(effectiveDeliveryDate(order))} disabled />
          </Field>
          <Field label="New delivery date">
            <Input
              type="date"
              min={todayIso()}
              value={newDate}
              onChange={(e) => setNewDate(e.target.value)}
            />
          </Field>
          <Field label="Reason" hint="The rep sees this — they may have to tell the customer.">
            <Textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. curing press down for maintenance until Thursday"
            />
          </Field>
        </div>
      </Modal>
    );
  }

  return (
    <Modal
      title={
        <span className="row gap-2">
          <span className="mono">{order.orderNo}</span>
          <Badge tone="neutral">{customerLabelFor(order, user)}</Badge>
        </span>
      }
      width="xwide"
      onClose={onClose}
      footer={
        <>
          <div className="grow small muted">
            Delivery {formatDate(effectiveDeliveryDate(order))}
            {order.revisedDeliveryDate && ` (moved from ${formatDate(order.deliveryDate)})`}
          </div>
          {canReschedule && (
            <Button onClick={() => setRescheduling(true)}>Move delivery date</Button>
          )}
          <Button variant="primary" onClick={onClose}>
            Done
          </Button>
        </>
      }
    >
      {/* --- must-acknowledge changes (3.3) ------------------------------ */}
      {pendingAcks.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert
            tone="danger"
            title={`${pendingAcks.length} change${pendingAcks.length === 1 ? '' : 's'} made after approval`}
            actions={
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
            }
          >
            {pendingAcks.map((t) => (
              <div key={t.id} className="small">
                <strong>{t.detail ?? t.action}</strong> — {t.actorName}, {relativeTime(t.at)}
              </div>
            ))}
          </Alert>
        </div>
      )}

      <div className="detail-grid" style={{ marginBottom: 16 }}>
        <Detail label="Destination">{order.destination}</Detail>
        <Detail label="Requested delivery">{formatDate(order.deliveryDate)}</Detail>
        {order.revisedDeliveryDate && (
          <Detail label="Revised delivery">{formatDate(order.revisedDeliveryDate)}</Detail>
        )}
        {/* 3.2 — never editable, and the screen says so rather than just disabling it. */}
        <Detail label="Order created" hint="Fixed for the life of the order">
          {formatDateTime(order.createdAt)}
        </Detail>
        <Detail label="Approved">{order.approvedAt ? formatDateTime(order.approvedAt) : '—'}</Detail>
      </div>

      <div className="table-wrap" style={{ border: '1px solid var(--border)', borderRadius: 'var(--r)' }}>
        <table className="table">
          <thead>
            <tr>
              <th>Item</th>
              <th>Entered</th>
              <th className="right">Quantity</th>
              <th className="right">Final rate</th>
              <th>Source</th>
              <th style={{ minWidth: 230 }}>Process stage</th>
              <th style={{ width: 150 }} />
            </tr>
          </thead>
          <tbody>
            {order.items.map((item) => {
              const stages = stagesFor(item.category);
              const index = stageIndex(item.category, item.stage);
              const next = nextStage(item.category, item.stage);
              const prev = prevStage(item.category, item.stage);
              const done = isTerminalStage(item.category, item.stage);

              return (
                <tr key={item.id}>
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
                      {rateUnitFor(item.category)} · 🔒
                    </div>
                    <div className="tiny dim">{money(lineAmount(item), 2)}</div>
                  </td>
                  <td>
                    <SourceBadge source={item.source} />
                  </td>
                  <td>
                    <Select
                      compact
                      value={item.stage ?? stages[0].key}
                      onChange={(e) => void advance(item, e.target.value)}
                    >
                      {stages.map((s, i) => (
                        <option key={s.key} value={s.key}>
                          {i + 1}. {s.label}
                        </option>
                      ))}
                    </Select>
                    <div className="stage-track" style={{ marginTop: 5 }}>
                      {stages.map((s, i) => (
                        <span
                          key={s.key}
                          className={`stage-pip ${i < index ? 'is-done' : ''} ${
                            i === index ? 'is-current' : ''
                          }`}
                        />
                      ))}
                    </div>
                    {stages[index]?.hint && (
                      <div className="tiny dim" style={{ marginTop: 3 }}>
                        {stages[index].hint}
                      </div>
                    )}
                    {item.stageUpdatedAt && (
                      <div className="tiny dim">updated {relativeTime(item.stageUpdatedAt)}</div>
                    )}
                  </td>
                  <td className="right">
                    <div className="row gap-1" style={{ justifyContent: 'flex-end' }}>
                      {prev && (
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => void advance(item, prev.key)}
                          aria-label={`Move ${item.itemName} back`}
                        >
                          ←
                        </Button>
                      )}
                      {next ? (
                        <Button size="sm" variant="primary" onClick={() => void advance(item, next.key)}>
                          {next.label} →
                        </Button>
                      ) : (
                        done && <Badge tone="ok">Ready</Badge>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}

function Detail({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <div className="detail-item__label">{label}</div>
      <div className="detail-item__value">{children}</div>
      {hint && <div className="tiny dim">{hint}</div>}
    </div>
  );
}
