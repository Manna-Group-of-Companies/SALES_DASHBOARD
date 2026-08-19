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
import { creditBreached, hasRoute, scopeFor, teamOf, NO_TEAM_MESSAGE } from '@/domain/sales';
import { agingOf, bucketsOf } from '@/domain/credit';
import { canAssignOwner, isPooledUnit, visibleReps, type Person } from '@/domain/visibility';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { RouteCell } from './RouteCell';
import { OwnerCell } from './OwnerCell';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/common/aging.css';

/**
 * A customer in the shape the credit helpers take — raw ERPNext field names,
 * the same shape the phone reads and the fixtures are written in. One
 * translation point rather than one per screen.
 */
function rowOf(c: SalesCustomer) {
  return {
    custom_outstanding_balance: c.outstanding,
    custom_credit_limit: c.creditLimit,
    custom_outstanding_0_30: c.outstanding0_30,
    custom_outstanding_30_60: c.outstanding30_60,
    custom_outstanding_60_90: c.outstanding60_90,
    custom_outstanding_90_plus: c.outstanding90Plus,
  };
}
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
        const team = scopeFor(p, user?.salesPerson);
        /* Fail closed: an unresolved team must show nothing, never everyone. */
        if (!team) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        // A pooled unit's list also includes an unassigned customer — a
        // freshly imported UAE record with no owner yet must be visible to
        // the manager immediately, not sit dark until somebody opens Desk.
        // See domain/visibility.ts, visibleOwnerValues.
        const asVis: Person[] = p.map((sp) => ({
          name: sp.id,
          unit: sp.unit,
          enabled: sp.enabled,
          isGroup: sp.isGroup,
        }));
        const myUnit = asVis.find((v) => v.name === user?.salesPerson)?.unit;
        const fetchTeam = isPooledUnit(myUnit) ? [...team, ''] : team;
        const [c, r] = await Promise.all([
          Api.sales.listCustomers(fetchTeam),
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

  /** Who this manager may hand a customer/lead to — empty outside UAE. */
  const assignPeers = useMemo(() => {
    const asVis: Person[] = people.map((p) => ({
      name: p.id,
      unit: p.unit,
      enabled: p.enabled,
      isGroup: p.isGroup,
    }));
    return canAssignOwner(asVis, user?.salesPerson) ? visibleReps(asVis, user?.salesPerson) : [];
  }, [people, user]);

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
                    <th className="right">0–30</th>
                    <th className="right">30–60</th>
                    <th className="right">60–90</th>
                    <th className="right">90+</th>
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
                        <td className="small">
                          <OwnerCell
                            kind="customer"
                            id={c.id}
                            owner={c.assignedRep}
                            peers={assignPeers}
                            onSaved={(rep) =>
                              setCustomers((cur) =>
                                cur.map((x) => (x.id === c.id ? { ...x, assignedRep: rep } : x)),
                              )
                            }
                            onError={setError}
                          />
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
                        {/* One figure, because SAP sends one. */}
                        <td className="right num">
                          {c.creditLimit ? money(c.creditLimit, 0) : <span className="dim">—</span>}
                        </td>
                        {/*
                          SAP's four age buckets. A dash, never a zero, when
                          nothing has been synced for this customer: four
                          zeros beside a real balance reads as "nothing is
                          overdue", which is a claim nobody has the data for.
                        */}
                        {bucketsOf(agingOf(rowOf(c))).map((b) => (
                          <td
                            key={b.key}
                            className={`right num${b.overdue ? ' cell--overdue' : ''}`}
                            title={b.label}
                          >
                            {agingOf(rowOf(c)).bucketsKnown ? (
                              money(b.amount, 0)
                            ) : (
                              <span className="dim">—</span>
                            )}
                          </td>
                        ))}
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
