/**
 * The Sales Manager's landing page.
 *
 * One rule governs this whole folder: **a dashboard summarises and navigates,
 * it never decides.** There is no Approve button here, and there never should
 * be. Order decisions live in exactly one place — the approvals queue — because
 * a second place to decide is a second place to miss something, which is how a
 * lead order once sat pending where nobody was looking.
 *
 * The counts are therefore links, not controls.
 *
 * The "waiting" tile counts **across all time**, not this week. A weekly figure
 * quietly drops an order that has been pending for three weeks, which is
 * precisely the order most in need of a decision — so the oldest one is named
 * on the tile's foot as well.
 */

import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Order } from '@/domain/types';
import {
  effectiveDeliveryDate,
  formatDate,
  formatFreezeCountdown,
  freezeUrgency,
  todayIso,
} from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { useAppSelector } from '@/store/hooks';
import { selectOrders, selectPendingApproval, selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { greeting, money, moneyShort } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { daysWaiting, plural } from './dashboardRules';
import '@/components/layout/layout.css';
import './dashboard.css';

export function SalesDashboardPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const orders = useAppSelector(selectOrders);
  const pending = useAppSelector(selectPendingApproval);

  /** Oldest first: the queue is worked from the top, so the top must be the worst. */
  const waiting = useMemo(
    () => [...pending].sort((a, b) => a.createdAt.localeCompare(b.createdAt)),
    [pending],
  );

  /**
   * Orders whose 1 PM edit deadline lands inside the next day. After it passes
   * nothing on the order can be changed, so this is the only genuinely
   * time-critical thing on the page.
   */
  const freezing = useMemo(
    () =>
      orders
        .filter(
          (o) =>
            freezeUrgency(o) === 'imminent' && o.status !== 'rejected' && o.status !== 'grouped',
        )
        .sort((a, b) => effectiveDeliveryDate(a).localeCompare(effectiveDeliveryDate(b))),
    [orders],
  );

  const live = useMemo(
    () =>
      orders.filter(
        (o) => o.status === 'approved' || o.status === 'in_production' || o.status === 'dispatched',
      ),
    [orders],
  );

  const waitingValue = useMemo(
    () => waiting.reduce((sum, o) => sum + orderTotal(o.items), 0),
    [waiting],
  );

  if (!user) return null;

  const oldest = waiting[0];
  const oldestDays = oldest ? daysWaiting(oldest.createdAt) : 0;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {greeting()}, {user.name.split(' ')[0]}
          </div>
          <div className="page-head__sub">
            {/* `todayIso` is local time — `toISOString` is UTC and would read
                as yesterday for most of the Indian evening. */}
            {formatDate(todayIso())} ·{' '}
            {waiting.length
              ? `${waiting.length} ${plural(waiting.length, 'order')} waiting on you`
              : 'Nothing waiting on you'}
          </div>
        </div>
      </div>

      {/* --- what cannot wait --------------------------------------------- */}
      <div className="stack gap-3" style={{ marginBottom: 16 }}>
        {freezing.length > 0 && (
          <Alert
            tone="warn"
            title={`${freezing.length} ${plural(freezing.length, 'order')} freeze within a day`}
            actions={
              <Button size="sm" onClick={() => navigate('/orders')}>
                Open orders
              </Button>
            }
          >
            After 1:00 PM on the delivery date nothing on the order can be changed — by anyone.
            The soonest is {freezing[0]!.orderNo}, {formatFreezeCountdown(freezing[0]!)}.
          </Alert>
        )}
        {oldest && oldestDays >= 3 && (
          <Alert
            tone="danger"
            title={`${oldest.orderNo} has been waiting ${oldestDays} days`}
            actions={
              <Button size="sm" onClick={() => navigate('/approvals')}>
                Open queue
              </Button>
            }
          >
            Raised by {oldest.repName} for {oldest.customerName}.
          </Alert>
        )}
      </div>

      {/* --- tiles -------------------------------------------------------- */}
      <div className="tiles">
        <Tile
          label="Waiting on you"
          value={String(waiting.length)}
          tone={waiting.length ? 'warn' : undefined}
          // Deliberately all-time, not this week — see the note at the top.
          foot={oldest ? `Oldest ${oldestDays}d` : 'Queue is clear'}
          onClick={() => navigate('/approvals')}
        />
        <Tile
          label="Value awaiting approval"
          value={moneyShort(waitingValue)}
          foot={waiting.length ? `Across ${waiting.length} ${plural(waiting.length, 'order')}` : '—'}
          onClick={() => navigate('/approvals')}
        />
        <Tile
          label="Live orders"
          value={String(live.length)}
          foot="Approved, in production or dispatched"
          onClick={() => navigate('/orders')}
        />
        <Tile
          label="Freezing within a day"
          value={String(freezing.length)}
          tone={freezing.length ? 'alert' : undefined}
          foot={freezing.length ? 'Edit now or never' : 'Nothing urgent'}
          onClick={() => navigate('/orders')}
        />
      </div>

      <div className="cols cols--sidebar">
        {/* --- the queue, read-only -------------------------------------- */}
        <Card
          title="Longest waiting"
          actions={
            <Button size="sm" variant="ghost" onClick={() => navigate('/approvals')}>
              Approvals queue →
            </Button>
          }
          flush
        >
          {waiting.length === 0 ? (
            <Empty icon="✓" title="Nothing is waiting for a decision">
              Orders raised in the field-sales app land here for approval.
            </Empty>
          ) : (
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Customer</th>
                  <th className="right">Value</th>
                  <th className="right">Waiting</th>
                </tr>
              </thead>
              <tbody>
                {waiting.slice(0, 8).map((o) => (
                  <OrderRow key={o.id} order={o} onOpen={() => navigate(`/orders/${o.id}`)} />
                ))}
              </tbody>
            </table>
          )}
        </Card>

        {/* --- freeze watch ---------------------------------------------- */}
        <Card title="Freeze watch">
          {freezing.length === 0 ? (
            <Empty icon="🕐" title="No deadline inside a day">
              Every live order still has more than 24 hours of edit window left.
            </Empty>
          ) : (
            <div className="stack gap-2">
              {freezing.slice(0, 6).map((o) => (
                <button
                  key={o.id}
                  className="linkrow"
                  onClick={() => navigate(`/orders/${o.id}`)}
                >
                  <span className="mono small">{o.orderNo}</span>
                  <span className="small dim">{formatDate(effectiveDeliveryDate(o))}</span>
                  <Badge tone="warn">{formatFreezeCountdown(o)}</Badge>
                </button>
              ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

function OrderRow({ order, onOpen }: { order: Order; onOpen: () => void }) {
  const days = daysWaiting(order.createdAt);
  return (
    <tr onClick={onOpen} style={{ cursor: 'pointer' }}>
      <td className="mono small">{order.orderNo}</td>
      <td className="small">{order.customerName}</td>
      <td className="right num">{money(orderTotal(order.items))}</td>
      <td className="right num">
        <Badge tone={days >= 3 ? 'danger' : days >= 1 ? 'warn' : 'neutral'}>{days}d</Badge>
      </td>
    </tr>
  );
}
