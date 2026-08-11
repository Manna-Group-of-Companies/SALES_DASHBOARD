/**
 * B3 — Close the week.
 *
 * Groups a finished week's completed orders into one `Combined Order` per
 * customer.
 *
 * The list is shown **grouped by customer, exactly as it will be combined**,
 * so the manager sees the outcome before agreeing to it rather than after.
 *
 * **Forward is disabled once it would reach a week that has not finished.** A
 * week still running would keep taking orders after its combined order was
 * made, and nothing goes back to add them.
 *
 * **The run is repeatable, never unwound.** Already-grouped orders are
 * excluded from the eligible set, so a run that fails halfway is finished by
 * running it again. There is deliberately no rollback: deleting a
 * partially-populated group risks pointing member orders at a record that no
 * longer exists.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { TeamOrder } from '@/domain/types';
import { isClosed, lastClosedWeek, shiftWeek, type Week } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Button, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { CompletionTick } from '@/components/common/StatusPill';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import '@/features/orders/orders.css';
import './production.css';

export function CloseWeekPage() {
  const [week, setWeek] = useState<Week | null>(null);
  const [orders, setOrders] = useState<TeamOrder[]>([]);
  const [confirming, setConfirming] = useState(false);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  // Opens on the most recently *finished* week: the current one is still
  // taking orders, and grouping it would strand everything booked after.
  useEffect(() => {
    if (!week) setWeek(lastClosedWeek(serverNow()));
  }, [week]);

  const load = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!week) return;
    let live = true;
    setLoading(true);
    setError(null);
    Api.sales
      .listGroupableOrders({ start: week.start, end: week.end })
      .then((o) => {
        if (live) setOrders(o);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the week.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [week, tick]);

  /** Grouped exactly as they will be combined — one card per customer. */
  const groups = useMemo(() => {
    const map = new Map<string, { name: string; orders: TeamOrder[] }>();
    for (const o of orders) {
      if (!o.customer) continue;
      const g = map.get(o.customer) ?? { name: o.customerName || o.customer, orders: [] };
      g.orders.push(o);
      map.set(o.customer, g);
    }
    return [...map.values()].sort((a, b) => a.name.localeCompare(b.name));
  }, [orders]);

  const total = useMemo(() => orders.reduce((s, o) => s + o.total, 0), [orders]);

  /*
   * Stepping forward would land on a week that has not finished, so it is
   * disabled rather than allowed and then refused.
   */
  const canGoForward = useMemo(() => {
    if (!week) return false;
    return isClosed(shiftWeek(week, 1), serverNow());
  }, [week]);

  const run = async () => {
    if (!week) return;
    setBusy(true);
    setError(null);
    try {
      const r = await Api.sales.closeWeek({ week: { start: week.start, end: week.end } });
      setConfirming(false);
      if (r.failed.length) {
        setError(
          `Grouped ${r.orders} order(s) into ${r.groups} combined order(s), but ${r.failed.length} did not save: ${r.failed.join(', ')}. Run it again — already-grouped orders are skipped, so a repeat finishes the job rather than duplicating it.`,
        );
      } else {
        setDone(
          `Grouped ${r.orders} order${r.orders === 1 ? '' : 's'} into ${r.groups} combined order${r.groups === 1 ? '' : 's'}.`,
        );
      }
      load();
    } catch (e) {
      setError(
        `${e instanceof Error ? e.message : 'The run failed.'} Nothing is rolled back — run it again, and already-grouped orders will be skipped.`,
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Close the week</div>
          <div className="page-head__sub">
            Group completed orders into one combined order per customer
          </div>
        </div>
        <div className="cal__nav">
          <RefreshButton onClick={load} loading={loading} />
          <Link to="/production" className="btn btn--ghost btn--sm">
            ← Queue
          </Link>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not finish">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      {week && (
        <div className="cal__toolbar">
          <Button size="sm" variant="ghost" onClick={() => setWeek(shiftWeek(week, -1))}>
            ← Earlier
          </Button>
          <div className="week__label">
            <div>{week.label}</div>
            <div className="tiny dim">Monday to Sunday</div>
          </div>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => setWeek(shiftWeek(week, 1))}
            disabled={!canGoForward}
            title={
              canGoForward
                ? 'Next week'
                : 'That week has not finished yet — it would keep taking orders after being grouped'
            }
          >
            Later →
          </Button>
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Groupable orders" value={String(orders.length)} foot="Completed, not grouped" />
        <Tile label="Combined orders" value={String(groups.length)} foot="One per customer" />
        <Tile label="Value" value={money(total, 0)} foot="Across this week" />
      </div>

      {loading && <Empty icon="◔" title="Reading the week…" />}

      {!loading && !error && groups.length === 0 && (
        <Empty icon="✓" title="Nothing left to group for this week">
          Only completed orders are grouped, and anything already grouped is not offered again.
        </Empty>
      )}

      {!loading && groups.length > 0 && (
        <>
          <div className="orders__list">
            {groups.map((g) => (
              <Card
                key={g.name}
                title={g.name}
                actions={
                  <span className="tiny dim">
                    {g.orders.length} order{g.orders.length === 1 ? '' : 's'} → 1 combined order
                  </span>
                }
                flush
              >
                <table className="table">
                  <tbody>
                    {g.orders.map((o) => (
                      <tr key={o.id}>
                        <td>
                          <CompletionTick productionStatus={o.productionStatus} />
                        </td>
                        <td className="mono small">{o.id}</td>
                        <td className="num">{formatDate(o.placedOn)}</td>
                        <td className="right num">{money(o.total, 0)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </Card>
            ))}
          </div>

          {!confirming ? (
            <div className="line__edit-bar">
              <Button onClick={() => setConfirming(true)} disabled={busy}>
                Group {orders.length} into {groups.length} combined order
                {groups.length === 1 ? '' : 's'}
              </Button>
            </div>
          ) : (
            <Card title="Close this week?" className="mt-16">
              <p>
                {orders.length} completed order{orders.length === 1 ? '' : 's'} from{' '}
                <b>{week?.label}</b> will be grouped into {groups.length} combined order
                {groups.length === 1 ? '' : 's'}, one per customer.
              </p>
              <p className="note">Everyone will see the combined order against these orders.</p>
              <div className="prod__actions">
                <Button onClick={run} loading={busy}>
                  Group them
                </Button>
                <Button variant="ghost" onClick={() => setConfirming(false)} disabled={busy}>
                  Cancel
                </Button>
              </div>
            </Card>
          )}
        </>
      )}
    </div>
  );
}
