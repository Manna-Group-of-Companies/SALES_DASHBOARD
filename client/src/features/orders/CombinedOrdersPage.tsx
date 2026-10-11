/**
 * A4 — Combined orders (weekly).
 *
 * The sales manager sees these but does not create them; closing a week is the
 * production manager's job.
 *
 * Two display rules keep the money honest:
 *
 *   - **Never list a group and its members side by side.** The same money
 *     would be counted once in the group and again underneath it.
 *   - **Take the totals from the `Combined Order` header**, not from the
 *     members that happen to be loaded. A customer served by two reps in one
 *     week should show the whole week to both, not each rep's share.
 *
 * And one failure rule: if a header cannot be read, its orders are left
 * showing **individually**. A user seeing an order ungrouped has a worse list;
 * a user seeing neither has lost work off their screen.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { CombinedOrder, TeamOrder } from '@/domain/types';
import { isSet } from '@/domain/orderStatus';
import { orderProgress } from '@/domain/sapOrderState';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Card, Empty, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { CompletionTick } from '@/components/common/StatusPill';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

export function CombinedOrdersPage() {
  const [groups, setGroups] = useState<CombinedOrder[]>([]);
  const [orders, setOrders] = useState<TeamOrder[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.sales.listCombinedOrders(), Api.sales.listOrders()])
      .then(([g, o]) => {
        if (!live) return;
        setGroups(g);
        setOrders(o);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read combined orders.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  /** Members, by the combined order they belong to. */
  const members = useMemo(() => {
    const map = new Map<string, TeamOrder[]>();
    for (const o of orders) {
      if (!isSet(o.combinedOrder)) continue;
      const key = o.combinedOrder as string;
      map.set(key, [...(map.get(key) ?? []), o]);
    }
    return map;
  }, [orders]);

  const known = useMemo(() => new Set(groups.map((g) => g.id)), [groups]);

  /*
   * Orders whose combined order is set but whose header could not be read.
   * They are shown on their own rather than dropped — losing work off the
   * screen is worse than showing it ungrouped.
   */
  const orphans = useMemo(
    () => orders.filter((o) => isSet(o.combinedOrder) && !known.has(o.combinedOrder as string)),
    [orders, known],
  );

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return groups;
    return groups.filter(
      (g) => g.customerName.toLowerCase().includes(q) || g.id.toLowerCase().includes(q),
    );
  }, [groups, query]);

  const totals = useMemo(
    () => ({
      // From the headers, never from the members loaded here.
      value: groups.reduce((s, g) => s + g.total, 0),
      orders: groups.reduce((s, g) => s + g.orderCount, 0),
    }),
    [groups],
  );

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Combined Orders</div>
          {/* The summary, taken from the headers and never from the members
              loaded here. */}
          {!loading && !error && (
            <div className="page-head__sub">
              {groups.length} combined order{groups.length === 1 ? '' : 's'} · {totals.orders}{' '}
              order{totals.orders === 1 ? '' : 's'} grouped ·{' '}
              <b className="num">{money(totals.value, 0)}</b>
              {orphans.length > 0 && (
                <>
                  {' · '}
                  <span className="orders__count warn">{orphans.length} ungrouped</span>
                </>
              )}
            </div>
          )}
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read combined orders">
          {error}
        </Alert>
      )}

      <div className="cal__toolbar">
        <Input
          className="orders__search"
          placeholder="Search customer or order"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search combined orders"
        />
      </div>

      {loading && <Empty icon="◔" title="Loading combined orders…" />}

      {!loading && !error && rows.length === 0 && <Empty icon="—" title="No combined orders" />}

      {!loading && rows.length > 0 && (
        <div className="orders__list">
          {rows.map((g) => {
            const inside = members.get(g.id) ?? [];
            const isOpen = open === g.id;
            return (
              <div key={g.id} className="comb">
                <div
                  className="comb__head"
                  role="button"
                  tabIndex={0}
                  onClick={() => setOpen(isOpen ? null : g.id)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault();
                      setOpen(isOpen ? null : g.id);
                    }
                  }}
                >
                  <span className="comb__caret" aria-hidden="true">
                    {isOpen ? '▾' : '▸'}
                  </span>
                  <span className="grow">
                    <div className="ordrow__party">{g.customerName}</div>
                    <div className="ordrow__meta">
                      <span className="mono">{g.id}</span> · {formatDate(g.weekStart)} –{' '}
                      {formatDate(g.weekEnd)} · {g.orderCount} order
                      {g.orderCount === 1 ? '' : 's'}
                    </div>
                  </span>
                  {/* The header's own total — not the sum of what is loaded. */}
                  <b className="num">{money(g.total, 0)}</b>
                </div>

                {/* Members only when expanded, so the group total and the line
                    items are never both on screen adding up to twice the money. */}
                {isOpen && (
                  <div className="comb__body">
                    {/* The header may count orders this login cannot see — they
                        may belong to another team. */}
                    {inside.length === 0 ? (
                      <p className="comb__none">Not visible to your team</p>
                    ) : (
                      <table className="table">
                        <thead>
                          <tr>
                            <th>Order</th>
                            <th>Date</th>
                            <th>Rep</th>
                            <th>Status</th>
                            <th className="right">Amount</th>
                          </tr>
                        </thead>
                        <tbody>
                          {inside.map((o) => (
                            <tr key={o.id}>
                              <td className="mono small">
                                <Link to={`/orders/${o.id}`}>{o.id}</Link>
                              </td>
                              <td className="num">{formatDate(o.placedOn)}</td>
                              <td className="dim">{o.rep}</td>
                              <td>
                                <CompletionTick
                                  productionStatus={orderProgress(
                                    { salesOrder: o.sapSalesOrder, invoice: o.sapInvoice },
                                    o.productionStatus,
                                  )}
                                />
                              </td>
                              <td className="right num">{money(o.total, 0)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {!loading && orphans.length > 0 && (
        <Card title="Ungrouped Orders" className="mt-16" flush>
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Customer</th>
                  <th>Date</th>
                  <th>Combined order</th>
                  <th className="right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {orphans.map((o) => (
                  <tr key={o.id}>
                    <td className="mono small">
                      <Link to={`/orders/${o.id}`}>{o.id}</Link>
                    </td>
                    <td>{o.customerName}</td>
                    <td className="num">{formatDate(o.placedOn)}</td>
                    <td className="dim small">
                      <span className="mono">{o.combinedOrder}</span> · unavailable
                    </td>
                    <td className="right num">{money(o.total, 0)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  );
}
