/**
 * Customers — this manager's team only.
 *
 * Scoped to the reps reporting to the signed-in manager, and narrowed further
 * by the dropdown. Other teams are not shown at all: a manager has no decision
 * to make about somebody else's customers, and listing them only makes the
 * ones that are theirs harder to find.
 *
 * The route can be assigned in place. The dropdown offers only that rep's
 * routes — see `RouteCell` for why.
 *
 * `custom_assigned_reps` is a Link to Sales Person holding a bare name, so it
 * is matched by equality. It was once pipe-wrapped free text matched with
 * LIKE, and every rep's list came back empty when that changed.
 */

import { useEffect, useMemo, useState } from 'react';
import type { SalesCustomer, SalesPerson, SalesRoute } from '@/domain/types';
import { activeSalesPeople } from '@/domain/attendance';
import { creditBreached, hasRoute, teamOf } from '@/domain/sales';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { RouteCell } from './RouteCell';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';

type Filter = 'all' | 'no_route' | 'over_limit';

export function CustomersPage() {
  const user = useAppSelector(selectUser);

  const [customers, setCustomers] = useState<SalesCustomer[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [routes, setRoutes] = useState<SalesRoute[]>([]);
  const [rep, setRep] = useState<string>('');
  const [filter, setFilter] = useState<Filter>('all');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        // Only ever this manager's team — other teams are not their business.
        const team = teamOf(p, user?.salesPerson);
        const [c, r] = await Promise.all([
          Api.sales.listCustomers(team.length ? team : undefined),
          Api.sales.listRoutesFor(),
        ]);
        if (!live) return;
        setCustomers(c);
        setRoutes(r);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read customers.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, user]);

  const staff = useMemo(() => activeSalesPeople(people), [people]);
  const myTeam = useMemo(() => teamOf(people, user?.salesPerson), [people, user]);

  /** Only the manager's own reps appear in the dropdown. */
  const repOptions = useMemo(
    () =>
      staff
        .filter((p) => !myTeam.length || myTeam.includes(p.id))
        .sort((a, b) => a.name.localeCompare(b.name)),
    [staff, myTeam],
  );

  const rows = useMemo(() => {
    let list = rep ? customers.filter((c) => c.assignedRep === rep) : customers;
    if (filter === 'no_route') list = list.filter((c) => !hasRoute(c.route));
    if (filter === 'over_limit')
      list = list.filter((c) => creditBreached(c.outstanding, c.creditLimit));
    const q = query.trim().toLowerCase();
    if (!q) return list;
    return list.filter(
      (c) =>
        c.name.toLowerCase().includes(q) ||
        (c.route ?? '').toLowerCase().includes(q) ||
        (c.gstin ?? '').toLowerCase().includes(q) ||
        (c.assignedRep ?? '').toLowerCase().includes(q),
    );
  }, [customers, rep, query, filter]);

  const stats = useMemo(
    () => ({
      total: rows.length,
      noRoute: rows.filter((c) => !hasRoute(c.route)).length,
      noRep: rows.filter((c) => !c.assignedRep).length,
      overLimit: rows.filter((c) => creditBreached(c.outstanding, c.creditLimit)).length,
      owed: rows.reduce((s, c) => s + c.outstanding, 0),
    }),
    [rows],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Customers</div>
          <div className="page-head__sub">
            {customers.length} in your team
            {myTeam.length ? ` · ${myTeam.length} representatives` : ''}
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read customers">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Shown" value={String(stats.total)} foot={rep || 'Your team'} />
        <Tile
          label="No route"
          value={String(stats.noRoute)}
          tone={stats.noRoute ? 'warn' : undefined}
          foot="Cannot be ordered from"
        />
        <Tile
          label="Unassigned"
          value={String(stats.noRep)}
          tone={stats.noRep ? 'warn' : undefined}
          foot="No rep on the record"
        />
        <Tile
          label="Over credit limit"
          value={String(stats.overLimit)}
          tone={stats.overLimit ? 'alert' : undefined}
          foot="Owes more than allowed"
        />
        <Tile label="Outstanding" value={money(stats.owed, 0)} foot="Across those shown" />
      </div>

      <div className="cal__toolbar">
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
              {p.teamManager ? ` — ${p.teamManager}` : ''}
            </option>
          ))}
        </Select>
        <Input
          placeholder="Search name, route, GSTIN…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search customers"
        />
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'all', label: 'All' },
            { value: 'no_route', label: `No route (${stats.noRoute})` },
            { value: 'over_limit', label: 'Over limit' },
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Reading customers…" />}

      {!loading && !error && (
        <Card flush>
          {rows.length === 0 ? (
            <Empty icon="—" title="No customers match" />
          ) : (
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Customer</th>
                    <th>Representative</th>
                    <th>Route</th>
                    <th>GSTIN</th>
                    <th className="right">Credit limit</th>
                    <th className="right">Outstanding</th>
                    <th>Location</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((c) => {
                    const over = creditBreached(c.outstanding, c.creditLimit);
                    return (
                      <tr key={c.id}>
                        <td>{c.name}</td>
                        <td className="dim">
                          {c.assignedRep || <Badge tone="warn">unassigned</Badge>}
                        </td>
                        <td className="small">
                          <RouteCell
                            kind="customer"
                            id={c.id}
                            rep={c.assignedRep}
                            route={c.route}
                            routes={routes}
                            onSaved={(r) =>
                              setCustomers((cur) =>
                                cur.map((x) => (x.id === c.id ? { ...x, route: r } : x)),
                              )
                            }
                            onError={setError}
                          />
                        </td>
                        <td className="mono small">{c.gstin || <span className="dim">—</span>}</td>
                        <td className="right num">
                          {c.creditLimit ? money(c.creditLimit, 0) : <span className="dim">—</span>}
                        </td>
                        <td className="right num">
                          {over ? (
                            <b style={{ color: 'var(--danger)' }}>{money(c.outstanding, 0)}</b>
                          ) : (
                            money(c.outstanding, 0)
                          )}
                        </td>
                        <td>
                          {c.locationStatus === 'Verified' ? (
                            <Badge tone="ok">verified</Badge>
                          ) : (
                            <span className="dim small">{c.locationStatus || '—'}</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      )}

      {!loading && stats.noRoute > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          {stats.noRoute} of the customers shown have no sales route. An order cannot be started
          for them — production is given the route and nothing else, so an order without one
          reaches the floor with nowhere to send it.
        </p>
      )}
    </div>
  );
}
