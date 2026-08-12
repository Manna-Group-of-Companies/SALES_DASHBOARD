/**
 * Leads — a separate doctype from Customer, and a separate screen.
 *
 * A lead becomes a customer when its first order is approved. Until then it
 * has its own route, its own captured location and its own gaps, so folding it
 * into the customer list would hide which of the two you were looking at.
 *
 * The manager can put a lead on a route from here. The dropdown offers only
 * that rep's routes: a route is named `<Rep> - <Place>` and belongs to one
 * person, so offering all 98 would invite exactly the wrong choice.
 */

import { useEffect, useMemo, useState } from 'react';
import type { SalesLead, SalesPerson, SalesRoute } from '@/domain/types';
import { hasRoute, scopeFor, teamOf, NO_TEAM_MESSAGE } from '@/domain/sales';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { RouteCell } from './RouteCell';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';

type Filter = 'all' | 'no_route' | 'pending_location';

export function LeadsPage() {
  const user = useAppSelector(selectUser);

  const [leads, setLeads] = useState<SalesLead[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [routes, setRoutes] = useState<SalesRoute[]>([]);
  const [rep, setRep] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const myTeam = useMemo(() => teamOf(people, user?.salesPerson), [people, user]);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        const team = scopeFor(p, user?.salesPerson);
        /* Fail closed: an unresolved team must show nothing, never everyone. */
        if (!team) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        const [l, r] = await Promise.all([
          Api.sales.listLeads(team),
          Api.sales.listRoutesFor(),
        ]);
        if (!live) return;
        setLeads(l);
        setRoutes(r);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read leads.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, user]);

  const repOptions = useMemo(
    () =>
      people
        .filter((p) => p.enabled && !p.isGroup && (!myTeam.length || myTeam.includes(p.id)))
        .sort((a, b) => a.name.localeCompare(b.name)),
    [people, myTeam],
  );

  const rows = useMemo(() => {
    let list = rep ? leads.filter((l) => l.rep === rep) : leads;
    if (filter === 'no_route') list = list.filter((l) => !hasRoute(l.route));
    if (filter === 'pending_location')
      list = list.filter((l) => l.locationStatus === 'Pending Verification');
    const q = query.trim().toLowerCase();
    if (q) {
      list = list.filter(
        (l) =>
          l.name.toLowerCase().includes(q) ||
          (l.city ?? '').toLowerCase().includes(q) ||
          (l.mobile ?? '').includes(q) ||
          (l.rep ?? '').toLowerCase().includes(q),
      );
    }
    return list.slice(0, 500);
  }, [leads, rep, filter, query]);

  const stats = useMemo(
    () => ({
      total: leads.length,
      noRoute: leads.filter((l) => !hasRoute(l.route)).length,
      pending: leads.filter((l) => l.locationStatus === 'Pending Verification').length,
      converted: leads.filter((l) => l.customer).length,
    }),
    [leads],
  );

  const onRouteSaved = (id: string, route: string) =>
    setLeads((cur) => cur.map((l) => (l.id === id ? { ...l, route } : l)));

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Leads</div>
          <div className="page-head__sub">
            {stats.total} in your team · not yet customers
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read leads">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Leads" value={String(stats.total)} foot="Across your team" />
        <Tile
          label="No route"
          value={String(stats.noRoute)}
          tone={stats.noRoute ? 'warn' : undefined}
          foot="Cannot be ordered from"
        />
        <Tile
          label="Location to verify"
          value={String(stats.pending)}
          tone={stats.pending ? 'warn' : undefined}
          foot="Waiting on you"
        />
        <Tile label="Converted" value={String(stats.converted)} foot="Now customers" />
      </div>

      <div className="cal__toolbar">
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
        <Input
          placeholder="Search name, city or mobile…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search leads"
        />
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'all', label: 'All' },
            { value: 'no_route', label: `No route (${stats.noRoute})` },
            { value: 'pending_location', label: `Location (${stats.pending})` },
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Reading leads…" />}

      {!loading && !error && (
        <Card flush>
          {rows.length === 0 ? (
            <Empty icon="—" title="No leads match" />
          ) : (
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Lead</th>
                    <th>Representative</th>
                    <th>Route</th>
                    <th>Place</th>
                    <th>Type</th>
                    <th>Location</th>
                    <th>Converted</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((l) => (
                    <tr key={l.id}>
                      <td>
                        <div>{l.name}</div>
                        <div className="mono tiny dim">{l.id}</div>
                      </td>
                      <td className="dim">{l.rep || <Badge tone="warn">unassigned</Badge>}</td>
                      <td>
                        <RouteCell
                          kind="lead"
                          id={l.id}
                          rep={l.rep}
                          route={l.route}
                          routes={routes}
                          onSaved={(r) => onRouteSaved(l.id, r)}
                          onError={setError}
                        />
                      </td>
                      <td className="dim small">{l.city || '—'}</td>
                      <td className="dim small">{l.shopType || '—'}</td>
                      <td>
                        {l.locationStatus === 'Verified' ? (
                          <Badge tone="ok">verified</Badge>
                        ) : l.locationStatus === 'Pending Verification' ? (
                          <Badge tone="warn">to verify</Badge>
                        ) : (
                          <span className="dim small">not captured</span>
                        )}
                      </td>
                      <td className="mono small">
                        {l.customer ? <Badge tone="ok">{l.customer}</Badge> : <span className="dim">—</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      )}

      {!loading && rows.length === 500 && (
        <p className="note" style={{ marginTop: 12 }}>
          Showing the first 500 of {leads.length}. Narrow with the rep filter or search — the list
          is capped rather than truncated silently.
        </p>
      )}
    </div>
  );
}
