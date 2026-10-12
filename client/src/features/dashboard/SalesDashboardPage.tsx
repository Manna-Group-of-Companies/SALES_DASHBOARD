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
import { formatDate, todayIso } from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { useAppSelector } from '@/store/hooks';
import { selectOrders, selectPendingApproval, selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { daysWaiting } from './dashboardRules';
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

  /*
   * A "freezing within 24 hours" alert, tile and card stood here until
   * 11 October 2026, counting down to 1 PM on each delivery date. That cutoff
   * is gone — approval alone ends editing (order_locked_after_approval.json) —
   * so the queue below is now the only time-critical thing on the page.
   */

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
          <div className="page-head__title">Dashboard</div>
          <div className="page-head__sub">
            {/* `todayIso` is local time — `toISOString` is UTC and would read
                as yesterday for most of the Indian evening. */}
            {user.name} · {formatDate(todayIso())}
          </div>
        </div>
      </div>

      {/* --- what cannot wait --------------------------------------------- */}
      {/*
        Everything here opens Team Orders, not an approvals inbox.

        These tiles count ORDERS awaiting a decision, and they used to link to
        /approvals — a queue that deliberately never held orders at all. A
        manager clicking "3 awaiting approval" landed on a screen of customer
        sites. Orders are approved in Team Orders and nowhere else; the
        approvals inbox itself went on 11 October 2026.
      */}
      <div className="stack gap-3" style={{ marginBottom: 16 }}>
        {oldest && oldestDays >= 3 && (
          <Alert
            tone="danger"
            title={`${oldest.orderNo} has been waiting ${oldestDays} days`}
            actions={
              <Button size="sm" onClick={() => navigate('/orders')}>
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
          label="Awaiting approval"
          value={String(waiting.length)}
          tone={waiting.length ? 'warn' : undefined}
          // Deliberately all-time, not this week — see the note at the top.
          foot={oldest ? `Oldest ${oldestDays}d` : undefined}
          onClick={() => navigate('/orders')}
        />
        <Tile
          label="Value awaiting"
          value={moneyShort(waitingValue)}
          onClick={() => navigate('/orders')}
        />
        <Tile
          label="Live orders"
          value={String(live.length)}
          onClick={() => navigate('/orders')}
        />
      </div>

      <div className="stack gap-3">
        {/* --- the queue, read-only -------------------------------------- */}
        <Card
          title="Longest Waiting"
          actions={
            <Button size="sm" variant="ghost" onClick={() => navigate('/orders')}>
              View all
            </Button>
          }
          flush
        >
          {waiting.length === 0 ? (
            <Empty icon="✓" title="No orders awaiting approval" />
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
