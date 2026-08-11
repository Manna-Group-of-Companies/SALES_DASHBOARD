/**
 * §7.4 — The General Manager's queue.
 *
 * Everything a sales manager could not finalise: orders that would take a
 * customer past their credit limit. Each card leads with the credit picture,
 * because that is the whole reason the order arrived here — a GM opening this
 * screen is answering one question, and it should not need a click.
 *
 * "Open the order" gives the GM the same full review the sales manager gets,
 * where their three exemptions apply: they may edit past the 1 pm freeze, they
 * may edit an order that is not theirs, and they may change a rate the sales
 * manager already locked. See `orderStatus.ts` for why all three exist.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { SalesCustomer, TeamOrder } from '@/domain/types';
import { creditPicture, PO_STATUS } from '@/domain/orderStatus';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Card, Empty, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

export function GmQueuePage() {
  const user = useAppSelector(selectUser);

  const [orders, setOrders] = useState<TeamOrder[]>([]);
  const [customers, setCustomers] = useState<SalesCustomer[]>([]);
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.sales.listOrders(), Api.sales.listCustomers()])
      .then(([o, c]) => {
        if (!live) return;
        setOrders(o.filter((x) => x.poStatus === PO_STATUS.pendingGm));
        setCustomers(c);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the queue.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const byId = useMemo(() => new Map(customers.map((c) => [c.id, c])), [customers]);

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return orders;
    return orders.filter(
      (o) =>
        o.id.toLowerCase().includes(q) ||
        o.customerName.toLowerCase().includes(q) ||
        o.rep.toLowerCase().includes(q),
    );
  }, [orders, query]);

  const totals = useMemo(
    () => ({
      value: orders.reduce((s, o) => s + o.total, 0),
      over: orders.reduce((s, o) => {
        const c = byId.get(o.customer);
        return (
          s +
          creditPicture({
            outstanding: c?.outstanding,
            creditLimit: c?.creditLimit,
            orderTotal: o.total,
          }).over
        );
      }, 0),
    }),
    [orders, byId],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Escalated to you</div>
          <div className="page-head__sub">
            Orders that would take a customer past their credit limit
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the queue">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Waiting on you"
          value={String(orders.length)}
          tone={orders.length ? 'warn' : 'ok'}
          foot={orders.length ? 'Nobody else can decide these' : 'Queue clear'}
        />
        <Tile label="Value" value={money(totals.value, 0)} foot="Across the queue" />
        <Tile label="Over limit by" value={money(totals.over, 0)} foot="Total exposure" />
      </div>

      <div className="cal__toolbar">
        <Input
          placeholder="Search order, customer or rep…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search the queue"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading the queue…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="Nothing escalated to you">
          An order arrives here when approving it would take a customer past their credit limit.
        </Empty>
      )}

      <div className="loc__grid">
        {rows.map((o) => {
          const c = byId.get(o.customer);
          const p = creditPicture({
            outstanding: c?.outstanding,
            creditLimit: c?.creditLimit,
            orderTotal: o.total,
          });
          return (
            <Card
              key={o.id}
              title={o.customerName}
              actions={<span className="tiny dim mono">{o.id}</span>}
            >
              <table className="table loc__facts">
                <tbody>
                  <tr>
                    <td className="dim">Owes now</td>
                    <td className="num">{money(p.outstanding, 0)}</td>
                  </tr>
                  <tr>
                    <td className="dim">This order</td>
                    <td className="num">{money(p.orderTotal, 0)}</td>
                  </tr>
                  <tr>
                    <td className="dim">Would owe</td>
                    <td className="num">
                      <b>{money(p.projected, 0)}</b>
                    </td>
                  </tr>
                  <tr>
                    <td className="dim">Credit limit</td>
                    <td className="num">{money(p.creditLimit, 0)}</td>
                  </tr>
                </tbody>
              </table>

              <div className="gm__over">Over by {money(p.over, 0)}</div>

              <div className="ordrow__meta" style={{ marginTop: 8 }}>
                {o.rep} · raised {formatDate(o.placedOn)}
                {o.deliveryDate ? ` · deliver ${formatDate(o.deliveryDate)}` : ''}
              </div>

              <div className="loc__actions">
                <Link to={`/orders/${o.id}`} className="btn btn--sm">
                  Open the order
                </Link>
              </div>
            </Card>
          );
        })}
      </div>

      {!loading && rows.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          Inside the order you may change lines, quantities, the delivery date and the rate — even
          past the 1 pm freeze and even on rates the sales manager already locked. Those exemptions
          are yours alone: an escalation that arrived with no power to change anything would be a
          rubber stamp.
        </p>
      )}
    </div>
  );
}
