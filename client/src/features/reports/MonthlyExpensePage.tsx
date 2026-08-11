/**
 * Monthly expense sheet — one person, one month, one row per trip.
 *
 * Mirrors the sheet HR already works from: typed odometer beside the reading
 * taken off the photo, distance, per-km rate, daily allowance, bills, shop
 * visits, and the two money columns.
 *
 * The part that is new is **shared trips**. A shared trip is one document: the
 * owner claims it in full and everyone else is tagged on it. So it produces two
 * different rows —
 *
 *   - on the owner's sheet, the money, badged `Lead +2`
 *   - on each passenger's sheet, a ₹0 row badged `Joined`, naming whose trip it
 *     was
 *
 * That second row is the point. Without it a passenger's day is simply blank
 * and reads as though they did nothing, when they were in the vehicle all day.
 * The totals count only what this person actually claims.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type {
  FieldLeaveRequest,
  SalesPerson,
  SalesVisit,
  Trip,
  TripLeg,
  TripRates,
} from '@/domain/types';
import {
  billedExpenses,
  checkState,
  costPerHead,
  dailyAllowance,
  isImplausible,
  outOfPocket,
  participationOf,
  rateFor,
  travelClaim,
  tripClaim,
  tripDistance,
  tripsFor,
} from '@/domain/trips';
import { activeSalesPeople, isoOf } from '@/domain/attendance';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Badge, Button, Card, Empty, Select } from '@/components/ui';
import { ExportButton } from './ExportButton';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './reports.css';

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

export function MonthlyExpensePage() {
  const now = new Date();

  const [cursor, setCursor] = useState({ y: now.getFullYear(), m: now.getMonth() });
  const [personId, setPersonId] = useState('');
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [trips, setTrips] = useState<Trip[]>([]);
  const [visits, setVisits] = useState<SalesVisit[]>([]);
  const [leave, setLeave] = useState<FieldLeaveRequest[]>([]);
  const [rates, setRates] = useState<TripRates | null>(null);
  /** Bumped to re-run the load effect — the Refresh button's only job. */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const from = isoOf(cursor.y, cursor.m, 1);
  const to = isoOf(cursor.y, cursor.m, new Date(cursor.y, cursor.m + 1, 0).getDate());

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.attendance.listSalesPeople(),
      Api.trips.list(from, to),
      Api.trips.listVisits(from, to),
      Api.attendance.listLeaveRequests(),
      Api.trips.getRates(),
    ])
      .then(([p, t, v, lv, r]) => {
        if (!live) return;
        setPeople(p);
        setTrips(t);
        setVisits(v);
        setLeave(lv);
        setRates(r);
        const first = activeSalesPeople(p)[0];
        if (first) setPersonId((cur) => cur || first.id);
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
  const person = useMemo(() => staff.find((p) => p.id === personId), [staff, personId]);

  const mine = useMemo(
    () => (person ? tripsFor(trips, person.id) : []),
    [trips, person],
  );

  /** Shop visits per trip, so the count lines up with the row it belongs to. */
  const visitsByTrip = useMemo(() => {
    const m = new Map<string, number>();
    for (const v of visits) {
      if (!v.tripId) continue;
      m.set(v.tripId, (m.get(v.tripId) ?? 0) + 1);
    }
    return m;
  }, [visits]);

  const monthLeave = useMemo(
    () =>
      person
        ? leave.filter(
            (l) => l.person === person.id && l.status === 'Approved' && l.date >= from && l.date <= to,
          )
        : [],
    [leave, person, from, to],
  );

  /** Totals count owned trips only — a joined row is somebody else's claim. */
  const totals = useMemo(() => {
    if (!person || !rates) return { travel: 0, pocket: 0, claimed: 0, visits: 0, km: 0, joined: 0 };
    let travel = 0, pocket = 0, claimed = 0, visitCount = 0, km = 0, joined = 0;
    for (const t of mine) {
      if (participationOf(t, person.id) === 'joined') {
        joined++;
        continue;
      }
      travel += travelClaim(t, rates);
      pocket += outOfPocket(t);
      claimed += tripClaim(t, rates);
      visitCount += visitsByTrip.get(t.id) ?? 0;
      km += tripDistance(t);
    }
    return {
      travel: round2(travel), pocket: round2(pocket), claimed: round2(claimed),
      visits: visitCount, km: round1(km), joined,
    };
  }, [mine, person, rates, visitsByTrip]);

  const shift = (d: number) => {
    const dt = new Date(cursor.y, cursor.m + d, 1);
    setCursor({ y: dt.getFullYear(), m: dt.getMonth() });
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Monthly expense sheet</div>
          <div className="page-head__sub">
            Travel and out-of-pocket claims, one row per trip
          </div>
        </div>
      </div>

      <div className="cal__toolbar">
        <Select value={personId} onChange={(e) => setPersonId(e.target.value)} aria-label="Sales person">
          {staff.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}{p.teamManager ? ` — ${p.teamManager}` : ''}
            </option>
          ))}
        </Select>
        <div className="cal__nav">
          <ExportButton
            filename={`expenses-${person?.name ?? 'all'}-${MONTHS[cursor.m]}-${cursor.y}.xlsx`}
            sheet="Expenses"
            disabled={!person || mine.length === 0}
            rows={() =>
              mine.map((t) => {
                const leg = t.legs[0];
                const joined = participationOf(t, person!.id) === 'joined';
                return {
                  Date: t.date,
                  Mode: t.legs.length > 1 ? 'Mixed legs' : t.primaryMode,
                  Trip: t.id,
                  Shared: joined
                    ? `Joined ${t.person}`
                    : t.taggedReps.length
                      ? `Lead +${t.taggedReps.length} (${t.taggedReps.join(', ')})`
                      : '',
                  'Typed start': leg?.startOdometer ?? '',
                  'Typed stop': leg?.endOdometer ?? '',
                  'Photo start': leg?.actualStartOdometer || '',
                  'Photo stop': leg?.actualEndOdometer || '',
                  'Distance (km)': tripDistance(t),
                  'Rate (per km)': leg && rates ? rateFor(leg.mode, rates) : '',
                  'Daily allowance': joined ? 0 : dailyAllowance(t),
                  Bills: joined ? 0 : billedExpenses(t),
                  Visits: visitsByTrip.get(t.id) ?? 0,
                  Actual: joined ? 0 : outOfPocket(t),
                  Claimed: joined ? 0 : rates ? tripClaim(t, rates) : '',
                };
              })
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
          <Button size="sm" variant="ghost" onClick={() => shift(-1)} aria-label="Previous month">‹</Button>
          <div className="cal__title">{MONTHS[cursor.m]} {cursor.y}</div>
          <Button size="sm" variant="ghost" onClick={() => shift(1)} aria-label="Next month">›</Button>
        </div>
      </div>

      {error && <Alert tone="danger" title="Could not read trips">{error}</Alert>}
      {loading && !error && <Empty icon="◔" title="Reading trips…" />}

      {!loading && !error && person && rates && (
        <>
          <div className="tiles" style={{ marginBottom: 14 }}>
            <Tile label="Distance" value={`${totals.km} km`} foot="Own trips only" />
            <Tile label="Travel claim" value={money(totals.travel, 0)} foot="Distance × rate" />
            <Tile label="Out of pocket" value={money(totals.pocket, 0)} foot="D.A, lodging, tickets" />
            <Tile label="Total claimed" value={money(totals.claimed, 0)} tone="ok" foot="What payroll pays" />
            <Tile label="Shop visits" value={String(totals.visits)} foot="On own trips" />
          </div>

          {totals.joined > 0 && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="info" title={`${totals.joined} shared trip${totals.joined === 1 ? '' : 's'} joined`}>
                {person.name} travelled on {totals.joined} trip{totals.joined === 1 ? '' : 's'} paid
                for by someone else. Those rows show ₹0 here on purpose — the claim sits on the
                owner's sheet, and counting it twice would pay it twice.
              </Alert>
            </div>
          )}

          <Card flush>
            {mine.length === 0 ? (
              <Empty icon="—" title={`No trips for ${person.name} in ${MONTHS[cursor.m]}`} />
            ) : (
              <div className="scroll-x">
                <table className="table exp">
                  <thead>
                    <tr>
                      <th rowSpan={2}>Date</th>
                      <th rowSpan={2}>Mode</th>
                      <th rowSpan={2}>Trip</th>
                      <th rowSpan={2}>Shared</th>
                      <th colSpan={2} className="exp__grouphead">Typed by rep</th>
                      <th colSpan={2} className="exp__grouphead">From photo</th>
                      <th rowSpan={2} className="right">Distance</th>
                      <th rowSpan={2} className="right">Rate</th>
                      <th rowSpan={2} className="right">D.A</th>
                      <th rowSpan={2} className="right">Bills</th>
                      <th rowSpan={2} className="right">Visits</th>
                      <th rowSpan={2} className="right">Actual</th>
                      <th rowSpan={2} className="right">Claimed</th>
                    </tr>
                    <tr>
                      <th className="right">Start</th>
                      <th className="right">Stop</th>
                      <th className="right">Start</th>
                      <th className="right">Stop</th>
                    </tr>
                  </thead>
                  <tbody>
                    {mine.map((t) => (
                      <TripRow
                        key={t.id}
                        trip={t}
                        person={person.id}
                        rates={rates}
                        visits={visitsByTrip.get(t.id) ?? 0}
                      />
                    ))}
                    <tr className="exp__total">
                      <td colSpan={8}>Total — own trips only</td>
                      <td className="right num">{totals.km} km</td>
                      <td />
                      <td />
                      <td />
                      <td className="right num">{totals.visits}</td>
                      <td className="right num">{money(totals.pocket, 0)}</td>
                      <td className="right num">{money(totals.claimed, 0)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          {monthLeave.length > 0 && (
            <Card title="Approved leave this month" flush className="mt-16">
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr><th>Request</th><th>Date</th><th className="right">Days</th><th>Reason</th></tr>
                  </thead>
                  <tbody>
                    {monthLeave.map((l) => (
                      <tr key={l.id}>
                        <td className="mono small">{l.id}</td>
                        <td className="num">{formatDate(l.date)}</td>
                        <td className="right num">{l.days}</td>
                        <td className="dim">{l.reason || '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </Card>
          )}
        </>
      )}
    </div>
  );
}

function TripRow({
  trip,
  person,
  rates,
  visits,
}: {
  trip: Trip;
  person: string;
  rates: TripRates;
  visits: number;
}) {
  const role = participationOf(trip, person);
  const joined = role === 'joined';

  // One row per trip, so a multi-leg trip is summarised: the first leg's
  // readings stand in, and the mode column says the legs differ.
  const leg = trip.legs[0];
  const mixedLegs = trip.legs.length > 1;
  const rate = leg ? rateFor(leg.mode, rates) : 0;

  return (
    <tr className={joined ? 'exp__joined' : undefined}>
      <td className="num">{formatDate(trip.date)}</td>
      <td>
        {mixedLegs ? <span title={trip.legs.map((l) => l.mode).join(' + ')}>Mixed legs</span> : trip.primaryMode || '—'}
      </td>
      <td>
        <Link to={`/hr/trips/${trip.id}`} className="mono small">{trip.id}</Link>
      </td>
      <td>
        {joined ? (
          <Badge tone="neutral" title={`Claimed on ${trip.person}'s sheet`}>
            Joined · {trip.person}
          </Badge>
        ) : trip.taggedReps.length ? (
          <Badge tone="accent" title={`With ${trip.taggedReps.join(', ')} · ${money(costPerHead(trip, rates), 0)}/head`}>
            Lead +{trip.taggedReps.length}
          </Badge>
        ) : (
          <span className="dim">—</span>
        )}
      </td>
      <td className="right num">{leg?.startOdometer || '—'}</td>
      <td className="right num">{leg?.endOdometer || '—'}</td>
      <td className="right num">
        <PhotoReading leg={leg} which="start" />
      </td>
      <td className="right num">
        <PhotoReading leg={leg} which="end" />
      </td>
      <td className="right num">
        {tripDistance(trip)} km{leg && isImplausible(leg) ? ' ⚠' : ''}
      </td>
      <td className="right num">{rate ? money(rate, 2) : '—'}</td>
      <td className="right num">{joined ? dash() : money(dailyAllowance(trip), 0)}</td>
      <td className="right num">{joined ? dash() : money(billedExpenses(trip), 0)}</td>
      <td className="right num">{visits || <span className="dim">—</span>}</td>
      <td className="right num">{joined ? dash() : money(outOfPocket(trip), 0)}</td>
      <td className="right num">
        {joined ? (
          <span className="dim" title={`Claimed by ${trip.person}`}>₹0</span>
        ) : (
          <b>{money(tripClaim(trip, rates), 0)}</b>
        )}
      </td>
    </tr>
  );
}

function dash() {
  return <span className="dim">—</span>;
}

/**
 * What HR read off the odometer photo.
 *
 * Blank means nobody has checked yet — deliberately distinct from a figure
 * that matches, because "no discrepancy" and "nobody looked" are very
 * different things to sign a payment against. A corrected figure is coloured,
 * since that is the one that changed the money.
 */
function PhotoReading({ leg, which }: { leg?: TripLeg; which: 'start' | 'end' }) {
  if (!leg) return <span className="dim">—</span>;
  const state = checkState(leg);
  if (state === 'unchecked') {
    return (
      <span className="dim" title="Not yet checked against the photo">
        —
      </span>
    );
  }
  const value = which === 'start' ? leg.actualStartOdometer : leg.actualEndOdometer;
  const typed = which === 'start' ? leg.startOdometer : leg.endOdometer;
  const differs = value !== typed;
  return (
    <span
      className={differs ? 'exp__corrected' : undefined}
      title={differs ? `Rep typed ${typed}` : 'Matches the typed reading'}
    >
      {value || '—'}
    </span>
  );
}

function round1(n: number) { return Math.round(n * 10) / 10; }
function round2(n: number) { return Math.round(n * 100) / 100; }
