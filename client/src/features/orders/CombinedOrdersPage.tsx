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
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Card, Empty, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
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
          <div className="page-head__title">Combined orders</div>
          <div className="page-head__sub">
            One per customer per week · created by production when a week is closed
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read combined orders">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Combined orders" value={String(groups.length)} foot="Across all weeks" />
        <Tile label="Orders grouped" value={String(totals.orders)} foot="From the headers" />
        <Tile label="Value" value={money(totals.value, 0)} foot="From the headers" />
        {orphans.length > 0 && (
          <Tile
            label="Ungrouped"
            value={String(orphans.length)}
            tone="warn"
            foot="Header unreadable"
          />
        )}
      </div>

      <div className="cal__toolbar">
        <Input
          placeholder="Search customer or group…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search combined orders"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading combined orders…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="—" title="No combined orders yet">
          A week is grouped by the production manager once its orders are dispatched.
        </Empty>
      )}

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
                      <span className="mono">{g.id}</span> · {formatDate(g.weekStart)} to{' '}
                      {formatDate(g.weekEnd)} · {g.orderCount} order
                      {g.orderCount === 1 ? '' : 's'} combined
                    </div>
                  </span>
                  {/* The header's own total — not the sum of what is loaded. */}
                  <b className="num">{money(g.total, 0)}</b>
                </div>

                {/* Members only when expanded, so the group total and the line
                    items are never both on screen adding up to twice the money. */}
                {isOpen && (
                  <div className="comb__body">
                    {inside.length === 0 ? (
                      <p className="note">
                        The header says {g.orderCount} order{g.orderCount === 1 ? '' : 's'}, but
                        none are visible to you — they may belong to another team.
                      </p>
                    ) : (
                      <table className="table">
                        <tbody>
                          {inside.map((o) => (
                            <tr key={o.id}>
                              <td className="mono small">
                                <Link to={`/orders/${o.id}`}>{o.id}</Link>
                              </td>
                              <td className="num">{formatDate(o.placedOn)}</td>
                              <td className="dim">{o.rep}</td>
                              <td>
                                <CompletionTick productionStatus={o.productionStatus} />
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
        <Card title="Grouped, but the group could not be read" className="mt-16" flush>
          <div className="scroll-x">
            <table className="table">
              <tbody>
                {orphans.map((o) => (
                  <tr key={o.id}>
                    <td className="mono small">
                      <Link to={`/orders/${o.id}`}>{o.id}</Link>
                    </td>
                    <td>{o.customerName}</td>
                    <td className="num">{formatDate(o.placedOn)}</td>
                    <td className="dim small">points at {o.combinedOrder}</td>
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
