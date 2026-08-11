/**
 * One trip, in full — where an odometer reading came from.
 *
 * The verification screen shows a leg out of context; this is the context.
 * Who travelled, when they started and finished, every leg with its own mode
 * and rate, what was spent, which shops were visited, and who else was in the
 * vehicle. It is the page HR opens before deciding a reading is wrong.
 *
 * Read-only. Corrections belong on the verification screen, so there is one
 * place to make them.
 */

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { SalesVisit, Trip, TripRates } from '@/domain/types';
import {
  awaitingCorrection,
  billedExpenses,
  costPerHead,
  dailyAllowance,
  effectiveReading,
  headcount,
  isImplausible,
  isShared,
  legClaim,
  legDistance,
  outOfPocket,
  rateFor,
  travelClaim,
  tripClaim,
} from '@/domain/trips';
import { clockOf } from '@/domain/attendance';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Badge, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

export function TripDetailPage() {
  const { tripId = '' } = useParams();
  const [trip, setTrip] = useState<Trip | null>(null);
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
      Api.trips.get(tripId),
      Api.trips.listVisitsForTrip(tripId),
      Api.trips.getRates(),
    ])
      .then(([t, v, r]) => {
        if (!live) return;
        setTrip(t);
        setVisits(v);
        setRates(r);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read this trip.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tripId, tick]);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            Trip <span className="mono">{tripId}</span>
          </div>
          <div className="page-head__sub">
            {trip ? `${trip.person} · ${formatDate(trip.date)}` : 'Loading…'}
          </div>
        </div>
        <span style={{ display: 'inline-flex', gap: 6 }}>
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
          <Link to="/hr/odometer" className="btn btn--ghost btn--sm">
            ← Odometer check
          </Link>
        </span>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read this trip">
          {error}
        </Alert>
      )}
      {loading && !error && <Empty icon="◔" title="Reading trip…" />}

      {!loading && !error && trip && rates && (
        <>
          {isShared(trip) && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="info" title={`Shared trip — ${headcount(trip)} people`}>
                <b>{trip.person}</b> owns and claims this trip. Also travelling:{' '}
                <b>{trip.taggedReps.join(', ')}</b>. The cost is claimed once, in full, by the
                owner — it is never split. Per head that works out at{' '}
                <b>{money(costPerHead(trip, rates), 2)}</b>, shown for comparison only.
              </Alert>
            </div>
          )}

          <div className="tiles">
            <Tile label="Distance" value={`${trip.distanceKm} km`} foot={trip.costBasis ?? '—'} />
            <Tile label="Travel claim" value={money(travelClaim(trip, rates), 2)} foot="Legs × per-km rate" />
            <Tile label="Out of pocket" value={money(outOfPocket(trip), 2)} foot={`D.A ${money(dailyAllowance(trip), 0)} · bills ${money(billedExpenses(trip), 0)}`} />
            <Tile label="Total claim" value={money(tripClaim(trip, rates), 2)} tone="ok" foot="Travel + out of pocket" />
            <Tile label="Shop visits" value={String(visits.length)} foot="Checked in on this trip" />
          </div>

          <div className="cols cols--2" style={{ marginTop: 16 }}>
            <Card title="Trip" flush>
              <div className="scroll-x">
                <table className="table">
                  <tbody>
                    <Row label="Sales person" value={trip.person} />
                    <Row label="Date" value={formatDate(trip.date)} />
                    <Row label="Started" value={clockOf(trip.startTime)} />
                    <Row label="Finished" value={trip.endTime ? clockOf(trip.endTime) : '— still open'} />
                    <Row label="Primary mode" value={trip.primaryMode || '—'} />
                    <Row label="Cost basis" value={trip.costBasis ?? '—'} />
                    <Row label="Status" value={trip.status} />
                    <Row label="Expense status" value={trip.expenseStatus ?? '—'} />
                    <Row label="Purpose" value={trip.purpose || '—'} />
                  </tbody>
                </table>
              </div>
            </Card>

            <Card title="Expenses" flush>
              {trip.expenses.length === 0 ? (
                <Empty icon="—" title="Nothing claimed out of pocket" />
              ) : (
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Category</th>
                        <th className="right">Amount</th>
                        <th className="right">Approved</th>
                        <th>Bill</th>
                      </tr>
                    </thead>
                    <tbody>
                      {trip.expenses.map((e) => (
                        <tr key={e.id}>
                          <td>{e.category || e.expenseName || '—'}</td>
                          <td className="right num">{money(e.amount, 2)}</td>
                          <td className="right num">
                            {e.approvedAmount ? money(e.approvedAmount, 2) : <span className="dim">—</span>}
                          </td>
                          <td>
                            {e.billPhoto ? (
                              <a href={e.billPhoto} target="_blank" rel="noreferrer">
                                View
                              </a>
                            ) : (
                              <span className="dim">{e.hasBill ? 'claimed, no file' : '—'}</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>
          </div>

          <Card title="Vehicle legs" flush className="mt-16">
            {trip.legs.length === 0 ? (
              <Empty icon="—" title="No vehicle legs on this trip" />
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Leg</th>
                      <th>Mode</th>
                      <th>Vehicle</th>
                      <th className="right">Start</th>
                      <th className="right">End</th>
                      <th className="right">Distance</th>
                      <th className="right">Rate</th>
                      <th className="right">Claim</th>
                      <th>Verification</th>
                    </tr>
                  </thead>
                  <tbody>
                    {trip.legs.map((leg) => {
                      const reading = effectiveReading(leg);
                      return (
                        <tr key={leg.id}>
                          <td className="mono small">{leg.id}</td>
                          <td>{leg.mode}</td>
                          <td className="dim">{leg.vehicleNo || '—'}</td>
                          <td className="right num">{reading.start || '—'}</td>
                          <td className="right num">{reading.end || '—'}</td>
                          <td className="right num">
                            {legDistance(leg)} km
                            {isImplausible(leg) && ' ⚠'}
                          </td>
                          <td className="right num">{money(rateFor(leg.mode, rates), 2)}</td>
                          <td className="right num">{money(legClaim(leg, rates), 2)}</td>
                          <td>
                            {isImplausible(leg) ? (
                              <Badge tone="danger">impossible distance</Badge>
                            ) : awaitingCorrection(leg) ? (
                              <Badge tone="warn">awaiting reading</Badge>
                            ) : reading.corrected ? (
                              <Badge tone="ok">corrected by HR</Badge>
                            ) : (
                              <Badge tone="neutral">as entered</Badge>
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

          <Card title="Shop visits" flush className="mt-16">
            {visits.length === 0 ? (
              <Empty icon="—" title="No shop visits recorded on this trip">
                A visit is created when a rep checks in at a lead or customer.
              </Empty>
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Visit</th>
                      <th>Lead / customer</th>
                      <th className="right">In</th>
                      <th className="right">Out</th>
                      <th className="right">Minutes</th>
                      <th>Purpose</th>
                    </tr>
                  </thead>
                  <tbody>
                    {visits.map((v) => (
                      <tr key={v.id}>
                        <td className="mono small">{v.id}</td>
                        <td className="small">{v.customerId || v.leadId || '—'}</td>
                        <td className="right num">{clockOf(v.checkIn)}</td>
                        <td className="right num">{clockOf(v.checkOut)}</td>
                        <td className="right num">{v.durationMinutes}</td>
                        <td className="dim small">{v.purpose || '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <tr>
      <td className="dim" style={{ width: 150 }}>
        {label}
      </td>
      <td>{value}</td>
    </tr>
  );
}
