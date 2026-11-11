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

import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { TeamOrder } from '@/domain/types';
import { formatDate, todayIso } from '@/domain/orderRules';
import { isApproved } from '@/domain/orderStatus';
import { orderBucket } from '@/domain/sapOrderState';
import { scopeFor, NO_TEAM_MESSAGE } from '@/domain/sales';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { daysWaiting } from './dashboardRules';
import '@/components/layout/layout.css';
import './dashboard.css';

/*
 * The team's orders, read exactly as Team Orders reads them (11 Nov 2026).
 * The page used to count the Redux order list, the fixture-era path: on the
 * live site those rows carry no `status`, so every tile read 0 while Team
 * Orders showed orders waiting. Same team scope, same "To approve" rule, so
 * the two pages cannot disagree.
 */
function useTeamOrders(salesPerson?: string) {
  const [orders, setOrders] = useState<TeamOrder[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    Api.attendance
      .listSalesPeople()
      .then(async (people) => {
        const team = scopeFor(people, salesPerson);
        // Fail closed: an unresolved team shows nothing, never everyone.
        if (!team) {
          if (live) setError(NO_TEAM_MESSAGE);
          return;
        }
        const rows = await Api.sales.listOrders(team);
        if (live) setOrders(rows);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read orders.');
      });
    return () => {
      live = false;
    };
  }, [salesPerson]);
  return { orders, error };
}

const bucketOf = (o: TeamOrder) =>
  orderBucket({
    approved: isApproved(o.poStatus),
    poStatus: o.poStatus,
    salesOrderStatus: o.sapSalesOrderStatus,
  });

export function SalesDashboardPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const { orders, error } = useTeamOrders(user?.salesPerson);

  /** Oldest first: the queue is worked from the top, so the top must be the worst. */
  const waiting = useMemo(
    () =>
      orders
        .filter((o) => bucketOf(o) === 'to_approve')
        .sort((a, b) => a.placedOn.localeCompare(b.placedOn)),
    [orders],
  );

  /*
   * A "freezing within 24 hours" alert, tile and card stood here until
   * 11 October 2026, counting down to 1 PM on each delivery date. That cutoff
   * is gone — approval alone ends editing (order_locked_after_approval.json) —
   * so the queue below is now the only time-critical thing on the page.
   */

  // Approved and not yet invoiced in full: still being made or delivered.
  const live = useMemo(
    () => orders.filter((o) => bucketOf(o) === 'approved' && !o.sapInvoice),
    [orders],
  );

  const waitingValue = useMemo(() => waiting.reduce((sum, o) => sum + (o.total || 0), 0), [waiting]);

  if (!user) return null;

  const oldest = waiting[0];
  const oldestDays = oldest ? daysWaiting(oldest.placedOn) : 0;

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
        {error && <Alert tone="danger">{error}</Alert>}
        {oldest && oldestDays >= 3 && (
          <Alert
            tone="danger"
            title={`${orderNo(oldest)} has been waiting ${oldestDays} days`}
            actions={
              <Button size="sm" onClick={() => navigate('/orders')}>
                Open queue
              </Button>
            }
          >
            Raised by {oldest.rep} for {oldest.customerName}.
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

/** SAP's order number once SAP has it, the ERPNext name before. */
const orderNo = (o: TeamOrder) => o.sapSalesOrder || o.id;

function OrderRow({ order, onOpen }: { order: TeamOrder; onOpen: () => void }) {
  const days = daysWaiting(order.placedOn);
  return (
    <tr onClick={onOpen} style={{ cursor: 'pointer' }}>
      <td className="mono small">{orderNo(order)}</td>
      <td className="small">{order.customerName}</td>
      <td className="right num">{money(order.total)}</td>
      <td className="right num">
        <Badge tone={days >= 3 ? 'danger' : days >= 1 ? 'warn' : 'neutral'}>{days}d</Badge>
      </td>
    </tr>
  );
}
