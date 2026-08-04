/**
 * Phase 3 — the Production Manager's board (3.1 – 3.3).
 *
 * The customer's identity is deliberately absent everywhere on this screen: the
 * floor sees the destination, because it needs it to plan routing, and nothing
 * else about who the goods are for (3.1). `customerLabelFor` enforces that
 * rather than each card remembering to.
 */

import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Order } from '@/domain/types';
import { customerLabelFor, effectiveDeliveryDate, formatDate } from '@/domain/orderRules';
import { allItemsReady, orderProgress, stageLabel } from '@/domain/processStages';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectProductionQueue, selectUser } from '@/store/selectors';
import { dispatchOrder } from '@/store/slices/ordersSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Badge, Button, Card, Empty, Meter, Tabs, type TabDef } from '@/components/ui';
import { relativeTime } from '@/components/common/format';
import { StatusBadge } from '@/components/common/StatusBadge';
import { ProductionOrderModal } from './ProductionOrderModal';
import '@/features/orders/orders.css';

type View = 'queue' | 'late' | 'ready';

export function ProductionBoard() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const queue = useAppSelector(selectProductionQueue);
  const [view, setView] = useState<View>('queue');
  const [open, setOpen] = useState<Order | null>(null);

  const today = new Date().toISOString().slice(0, 10);

  const late = useMemo(
    () => queue.filter((o) => effectiveDeliveryDate(o) < today && !allItemsReady(o.items)),
    [queue, today],
  );
  const ready = useMemo(() => queue.filter((o) => allItemsReady(o.items)), [queue]);

  const rows = view === 'late' ? late : view === 'ready' ? ready : queue;

  const tabs: TabDef<View>[] = [
    { id: 'queue', label: 'All jobs', count: queue.length },
    { id: 'late', label: 'Behind schedule', count: late.length },
    { id: 'ready', label: 'Ready to dispatch', count: ready.length },
  ];

  const send = async (order: Order) => {
    if (!user) return;
    const result = await dispatch(dispatchOrder({ orderId: order.id, user }));
    if (dispatchOrder.fulfilled.match(result)) {
      dispatch(pushToast(`${order.orderNo} marked dispatched.`, 'success'));
    }
  };

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Production board</div>
          <div className="page-head__sub">
            {queue.length} live job{queue.length === 1 ? '' : 's'} · destination shown, customer
            identity withheld
          </div>
        </div>
        <Button onClick={() => navigate('/dispatch')}>Weekly compile →</Button>
      </div>

      {late.length > 0 && view !== 'late' && (
        <div style={{ marginBottom: 12 }}>
          <Alert
            tone="danger"
            title={`${late.length} job${late.length === 1 ? ' is' : 's are'} past the delivery date`}
            actions={
              <Button size="sm" variant="danger" onClick={() => setView('late')}>
                Show them
              </Button>
            }
          >
            Postpone the date if the job genuinely cannot be met — the rep is told automatically.
          </Alert>
        </div>
      )}

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={view} onChange={setView} />
        </div>

        {rows.length === 0 ? (
          <Empty icon="⚙" title="Nothing here">
            Approved orders arrive on this board automatically.
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Job</th>
                  <th>Destination</th>
                  <th>Delivery</th>
                  <th style={{ width: 170 }}>Progress</th>
                  <th>Lines</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((order) => {
                  const progress = orderProgress(order.items);
                  const isLate = effectiveDeliveryDate(order) < today;
                  const unacked = order.timeline.filter((t) => t.requiresAck && !t.ackedAt).length;
                  const canDispatch = allItemsReady(order.items);

                  return (
                    <tr key={order.id}>
                      <td>
                        <div className="mono small strong">{order.orderNo}</div>
                        <div className="tiny dim">
                          approved {relativeTime(order.approvedAt ?? order.createdAt)}
                        </div>
                        {/* Post-approval changes must not be missable (3.3). */}
                        {unacked > 0 && (
                          <div style={{ marginTop: 3 }}>
                            <Badge tone="danger">⚠ {unacked} change to acknowledge</Badge>
                          </div>
                        )}
                      </td>
                      <td>
                        <div className="small strong">{customerLabelFor(order, user)}</div>
                      </td>
                      <td className="small">
                        <span style={{ color: isLate ? 'var(--danger)' : undefined, fontWeight: isLate ? 600 : undefined }}>
                          {formatDate(effectiveDeliveryDate(order))}
                        </span>
                        {order.revisedDeliveryDate && (
                          <div className="tiny dim">was {formatDate(order.deliveryDate)}</div>
                        )}
                      </td>
                      <td>
                        <Meter
                          value={progress}
                          tone={progress === 1 ? 'ok' : isLate ? 'danger' : 'accent'}
                          label={`Progress for ${order.orderNo}`}
                        />
                        <div className="tiny dim" style={{ marginTop: 3 }}>
                          {Math.round(progress * 100)}% complete
                        </div>
                      </td>
                      <td className="small">
                        {order.items.map((it) => (
                          <div key={it.id} className="tiny">
                            {it.itemName.slice(0, 26)}
                            {it.itemName.length > 26 ? '…' : ''} —{' '}
                            <span className="muted">{stageLabel(it.category, it.stage)}</span>
                          </div>
                        ))}
                      </td>
                      <td>
                        <StatusBadge status={order.status} />
                      </td>
                      <td className="right">
                        <div className="row gap-2" style={{ justifyContent: 'flex-end' }}>
                          <Button size="sm" onClick={() => setOpen(order)}>
                            Open
                          </Button>
                          <Button
                            size="sm"
                            variant="primary"
                            disabled={!canDispatch}
                            onClick={() => void send(order)}
                            title={
                              canDispatch
                                ? 'Mark this job dispatched'
                                : 'Every line must reach Ready for Dispatch first'
                            }
                          >
                            Dispatch
                          </Button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {open && (
        <ProductionOrderModal
          order={
            // Re-read from the store so the modal follows live updates.
            queue.find((o) => o.id === open.id) ?? open
          }
          onClose={() => setOpen(null)}
        />
      )}
    </div>
  );
}
