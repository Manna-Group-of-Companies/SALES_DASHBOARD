/**
 * Range summary — every sales officer over any span of dates.
 *
 * Mirrors the sheet HR already circulates: per officer, the distance covered,
 * shops visited and money claimed, alongside the "shop visit with manager"
 * block that records how much of the period the team head was actually out
 * with them. The dates are free rather than a fixed week, because a pay run,
 * a visit cycle and a month rarely start on the same day.
 *
 * "With manager" is derived rather than typed. A shared trip is one document,
 * so the manager travelling with a rep shows up either as the manager tagged
 * on the rep's trip or the rep tagged on the manager's — both mean the same
 * thing on the ground and both are counted.
 *
 * Totals dedupe by trip: a shared trip appears on two officers' rows but is
 * one journey and one cost, so summing the rows would bill it twice.
 */

import { useEffect, useMemo, useState } from 'react';
import type { SalesPerson, SalesVisit, Trip, TripRates } from '@/domain/types';
import {
  distinctDays,
  participationOf,
  travelledWithManager,
  teamClaim,
  tripClaim,
  tripDistance,
  tripsFor,
} from '@/domain/trips';
import { activeSalesPeople } from '@/domain/attendance';
import { todayIso, weekEndOf, weekStartOf } from '@/domain/orderRules';
import { shiftIso } from '@/domain/attendance';
import { Api } from '@/api/client';
import { Alert, Button, Card, Empty, Field, Input } from '@/components/ui';
import { ExportButton } from './ExportButton';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './reports.css';

interface Row {
  person: SalesPerson;
  /** Trips this officer owns — the ones they claim. */
  owned: Trip[];
  km: number;
  visits: number;
  claimed: number;
  /** Trips on which their team head travelled too, owned by either party. */
  withManager: Trip[];
  withManagerVisits: number;
}

export function RangeSummaryPage() {
  /** Free dates, defaulted to the current week so the first view is familiar. */
  const [from, setFrom] = useState(() => weekStartOf(todayIso()));
  const [to, setTo] = useState(() => weekEndOf(todayIso()));
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [visits, setVisits] = useState<SalesVisit[]>([]);
  const [rates, setRates] = useState<TripRates | null>(null);
  /** Bumped to re-run the load effect — the Refresh button's only job. */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.attendance.listSalesPeople(),
      Api.trips.list(from, to),
      Api.trips.listVisits(from, to),
      Api.trips.getRates(),
    ])
      .then(([p, t, v, r]) => {
        if (!live) return;
        setPeople(p);
        setTrips(t);
        setVisits(v);
        setRates(r);
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

  const visitsByTrip = useMemo(() => {
    const m = new Map<string, number>();
    for (const v of visits) {
      if (v.tripId) m.set(v.tripId, (m.get(v.tripId) ?? 0) + 1);
    }
    return m;
  }, [visits]);

  const rows: Row[] = useMemo(() => {
    if (!rates) return [];
    return activeSalesPeople(people)
      .map((person) => {
        const involved = tripsFor(trips, person.id);
        const owned = involved.filter((t) => participationOf(t, person.id) === 'owner');
        const withManager = involved.filter((t) =>
          travelledWithManager(t, person.id, person.teamManager),
        );
        return {
          person,
          owned,
          km: round1(owned.reduce((s, t) => s + tripDistance(t), 0)),
          visits: owned.reduce((s, t) => s + (visitsByTrip.get(t.id) ?? 0), 0),
          claimed: round2(owned.reduce((s, t) => s + tripClaim(t, rates), 0)),
          withManager,
          withManagerVisits: withManager.reduce((s, t) => s + (visitsByTrip.get(t.id) ?? 0), 0),
        };
      })
      .filter((r) => r.owned.length > 0 || r.withManager.length > 0)
      .sort((a, b) => a.person.name.localeCompare(b.person.name));
  }, [people, trips, rates, visitsByTrip]);

  const grand = useMemo(() => {
    if (!rates) return { visits: 0, days: 0, claimed: 0, km: 0 };
    return {
      // Counted over the whole trip set, not summed per row, so a shared trip
      // contributes once.
      visits: [...visitsByTrip.values()].reduce((s, n) => s + n, 0),
      days: distinctDays(trips),
      claimed: teamClaim(trips, rates),
      km: round1(trips.reduce((s, t) => s + tripDistance(t), 0)),
    };
  }, [trips, rates, visitsByTrip]);

  /** Shift the whole window by its own length — "the period before this one". */
  const shiftBy = (direction: -1 | 1) => {
    const days = Math.max(1, Math.round((Date.parse(to) - Date.parse(from)) / 86_400_000) + 1);
    setFrom(shiftIso(from, direction * days));
    setTo(shiftIso(to, direction * days));
  };

  const preset = (fromIso: string, toIso: string) => {
    setFrom(fromIso);
    setTo(toIso);
  };

  const today = todayIso();
  const monthStart = `${today.slice(0, 7)}-01`;
  const invalid = to < from;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Summary by date range</div>
          <div className="page-head__sub">
            Shop visits, distance and claims by sales officer
          </div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`summary-${from}-to-${to}.xlsx`}
            sheet="Summary"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((r) => ({
                'Sales officer': r.person.name,
                'Team head': r.person.teamManager,
                'Business unit': r.person.unit,
                Days: distinctDays(r.owned),
                'Distance (km)': r.km,
                Shops: r.visits,
                Claimed: r.claimed,
                'With manager: days': distinctDays(r.withManager),
                'With manager: shops': r.withManagerVisits,
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      <div className="rangebar">
        <Field label="From">
          <Input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
        </Field>
        <Field label="To">
          <Input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
        </Field>
        <div className="rangebar__presets">
          <Button size="sm" variant="ghost" onClick={() => shiftBy(-1)} title="Previous period of the same length">
            ‹ Previous
          </Button>
          <Button size="sm" variant="ghost" onClick={() => preset(weekStartOf(today), weekEndOf(today))}>
            This week
          </Button>
          <Button size="sm" variant="ghost" onClick={() => preset(monthStart, today)}>
            This month
          </Button>
          <Button size="sm" variant="ghost" onClick={() => preset(shiftIso(today, -29), today)}>
            Last 30 days
          </Button>
          <Button size="sm" variant="ghost" onClick={() => shiftBy(1)} title="Next period of the same length">
            Next ›
          </Button>
        </div>
      </div>

      {invalid && (
        <Alert tone="warn" title="The end date is before the start date">
          Nothing can fall in that range — move one of the dates.
        </Alert>
      )}

      {error && (
        <Alert tone="danger" title="Could not read trips">
          {error}
        </Alert>
      )}
      {loading && !error && <Empty icon="◔" title="Reading trips…" />}

      {!loading && !error && (
        <>
          <div className="tiles" style={{ marginBottom: 14 }}>
            <Tile label="Total shop visits" value={String(grand.visits)} foot="Across the team" />
            <Tile label="Days of visit" value={String(grand.days)} foot="Distinct days with a trip" />
            <Tile label="Total distance" value={`${grand.km} km`} foot="Every trip once" />
            <Tile label="Total claimed" value={money(grand.claimed, 0)} tone="ok" foot="Shared trips counted once" />
            <Tile label="Officers active" value={String(rows.length)} foot="With a trip in range" />
          </div>

          <Card flush>
            {rows.length === 0 ? (
              <Empty icon="—" title="No trips in this range" />
            ) : (
              <div className="scroll-x">
                <table className="table exp">
                  <thead>
                    <tr>
                      <th rowSpan={2}>Sales officer</th>
                      <th rowSpan={2}>Team head</th>
                      <th rowSpan={2} className="right">Days</th>
                      <th rowSpan={2} className="right">Distance</th>
                      <th rowSpan={2} className="right">Shops</th>
                      <th rowSpan={2} className="right">Claimed</th>
                      <th colSpan={2} className="exp__grouphead">Shop visit with manager</th>
                    </tr>
                    <tr>
                      <th className="right">Days</th>
                      <th className="right">Shops</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((r) => (
                      <tr key={r.person.id}>
                        <td>{r.person.name}</td>
                        <td className="dim">{r.person.teamManager || '—'}</td>
                        <td className="right num">{distinctDays(r.owned)}</td>
                        <td className="right num">{r.km} km</td>
                        <td className="right num">{r.visits || <span className="dim">—</span>}</td>
                        <td className="right num">{money(r.claimed, 0)}</td>
                        <td className="right num">
                          {r.withManager.length ? (
                            distinctDays(r.withManager)
                          ) : (
                            <span className="dim">—</span>
                          )}
                        </td>
                        <td className="right num">
                          {r.withManagerVisits || <span className="dim">—</span>}
                        </td>
                      </tr>
                    ))}
                    <tr className="exp__total">
                      <td colSpan={2}>Total — each trip counted once</td>
                      <td className="right num">{grand.days}</td>
                      <td className="right num">{grand.km} km</td>
                      <td className="right num">{grand.visits}</td>
                      <td className="right num">{money(grand.claimed, 0)}</td>
                      <td colSpan={2} />
                    </tr>
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <p className="note" style={{ marginTop: 12 }}>
            Per-officer rows count only the trips that officer owns and claims. The team total
            counts each trip once, so a shared journey is not billed twice — which is why the
            column does not add up to the total.
          </p>
        </>
      )}
    </div>
  );
}

function round1(n: number) {
  return Math.round(n * 10) / 10;
}
function round2(n: number) {
  return Math.round(n * 100) / 100;
}
