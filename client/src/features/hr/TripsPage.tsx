/**
 * HR — trips, every rep.
 *
 * A list, not a workbench. Each row is a claim; opening one goes to the trip
 * detail, where the route, the GPS log, the legs and the expenses are.
 *
 * The map deliberately lives there and not here. A map per row would load
 * Leaflet and a routing request for every trip on screen to answer a question
 * nobody has asked yet — and the route only means something next to the
 * odometer readings and the visits, which are on the detail page anyway.
 */

import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { SalesPerson, Trip } from '@/domain/types';
import { activeSalesPeople } from '@/domain/attendance';
import { IMPLAUSIBLE_DAILY_KM, isImplausible, tripDistance } from '@/domain/trips';

import { formatDate } from '@/domain/orderRules';
import { addDays, isoDate, mondayOf } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Select } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { ExportButton } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import './attendance.css';
import '@/features/orders/orders.css';

/**
 * A trip is implausible when any leg is, or when the day totals beyond what
 * anyone drives. TRP-00215 records 35,184 km in one day — a typo, not a
 * journey, and the sort of thing HR should see before paying it.
 */
function tripImplausible(t: Trip): boolean {
  return t.legs.some(isImplausible) || tripDistance(t) > IMPLAUSIBLE_DAILY_KM;
}

export function TripsPage() {
  const user = useAppSelector(selectUser);
  const navigate = useNavigate();

  const [trips, setTrips] = useState<Trip[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rep, setRep] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Opens on the current week, on the server's clock rather than the browser's.
  useEffect(() => {
    if (from && to) return;
    const monday = mondayOf(serverNow());
    setFrom(isoDate(monday));
    setTo(isoDate(addDays(monday, 6)));
  }, [from, to]);

  useEffect(() => {
    if (!from || !to) return;
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.trips.list(from, to), Api.attendance.listSalesPeople()])
      .then(([t, p]) => {
        if (!live) return;
        setTrips(t);
        setPeople(p);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read trips.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [from, to, tick]);

  const staff = useMemo(() => activeSalesPeople(people), [people]);

  const rows = useMemo(() => {
    const list = rep ? trips.filter((t) => t.person === rep) : trips;
    return [...list].sort(
      (a, b) => b.date.localeCompare(a.date) || a.person.localeCompare(b.person),
    );
  }, [trips, rep]);

  const stats = useMemo(
    () => ({
      trips: rows.length,
      km: Math.round(rows.reduce((n, t) => n + tripDistance(t), 0)),
      claim: Math.round(rows.reduce((n, t) => n + t.estimatedCost, 0)),
      flagged: rows.filter(tripImplausible).length,
    }),
    [rows],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Trips</div>
          <div className="page-head__sub">
            Every representative · open one to see its route and GPS log
          </div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`trips-${from}-to-${to}.xlsx`}
            sheet="Trips"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((t) => ({
                Trip: t.id,
                Representative: t.person,
                Date: t.date,
                Mode: t.primaryMode,
                'Distance (km)': tripDistance(t),
                'Travel claim': t.estimatedCost,
                Expenses: t.totalExpenses,
                Status: t.status,
                'Tagged with': t.taggedReps.join(', '),
              }))
            }
          />
          <RefreshButton onClick={() => setTick((n) => n + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read trips">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Trips" value={String(stats.trips)} foot="In this range" />
        <Tile label="Distance" value={`${stats.km} km`} foot="Claimed, from odometers" />
        <Tile label="Travel claim" value={money(stats.claim, 0)} foot="At the per-km rates" />
        <Tile
          label="Implausible"
          value={String(stats.flagged)}
          tone={stats.flagged ? 'warn' : undefined}
          foot="Beyond a day's driving"
        />
      </div>

      <div className="cal__toolbar">
        <Input
          type="date"
          value={from}
          onChange={(e) => setFrom(e.target.value)}
          aria-label="From date"
        />
        <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="To date" />
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {staff.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
      </div>

      {loading && <Empty icon="◔" title="Reading trips…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="—" title="No trips in this range">
          Widen the dates, or clear the representative filter.
        </Empty>
      )}

      {!loading && rows.length > 0 && (
        <Card flush>
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Trip</th>
                  <th>Representative</th>
                  <th>Date</th>
                  <th>Mode</th>
                  <th className="right">Claimed</th>
                  <th className="right">Travel claim</th>
                  <th className="right">Expenses</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((t) => (
                  <tr
                    key={t.id}
                    className="row--link"
                    onClick={() => navigate(`/hr/trips/${t.id}`)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        navigate(`/hr/trips/${t.id}`);
                      }
                    }}
                    tabIndex={0}
                    role="button"
                    title={`Open ${t.id}`}
                  >
                    <td className="mono small">{t.id}</td>
                    <td>{t.person}</td>
                    <td className="num">{formatDate(t.date)}</td>
                    <td className="dim small">{t.primaryMode}</td>
                    <td className="right num">
                      {tripDistance(t)} km
                      {/* 35,184 km in one day is a typo, not a journey. */}
                      {tripImplausible(t) && (
                        <Badge tone="danger" title="Beyond what anyone drives in a day">
                          check
                        </Badge>
                      )}
                    </td>
                    <td className="right num">{money(t.estimatedCost, 0)}</td>
                    <td className="right num dim">{money(t.totalExpenses, 0)}</td>
                    <td className="small">
                      <Badge tone={t.status === 'Completed' ? 'ok' : 'neutral'}>{t.status}</Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      {!loading && rows.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          Open a trip to see its route, the GPS points the phone actually logged, and how the
          claimed distance compares with the places the rep checked in at.
        </p>
      )}
    </div>
  );
}
