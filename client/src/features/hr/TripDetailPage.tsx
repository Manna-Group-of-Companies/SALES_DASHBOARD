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

import { lazy, Suspense, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { SalesVisit, Trip, TripRates, TripTrack } from '@/domain/types';
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
import { checkDistance, hasFix, haversineKm, pathKm, routeOf, waypointsOf } from '@/domain/geo';
import { Api } from '@/api/client';
import { Alert, Badge, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';
import './trip-map.css';

/*
 * Leaflet and its CSS are ~165 kB and only this screen needs them, so they
 * load when a trip is opened rather than on every page in the app.
 */
const TripMap = lazy(() => import('./TripMap').then((m) => ({ default: m.TripMap })));

const VERDICT: Record<string, { label: string; tone: 'ok' | 'warn' | 'danger' | 'neutral' }> = {
  consistent: { label: 'Consistent', tone: 'ok' },
  far_above: { label: 'Well above the minimum', tone: 'warn' },
  impossible: { label: 'Below the minimum — impossible', tone: 'danger' },
  no_evidence: { label: 'No location evidence', tone: 'neutral' },
  unknown: { label: 'Cannot be checked', tone: 'neutral' },
};

export function TripDetailPage() {
  const { tripId = '' } = useParams();
  const [trip, setTrip] = useState<Trip | null>(null);
  const [visits, setVisits] = useState<SalesVisit[]>([]);
  const [rates, setRates] = useState<TripRates | null>(null);
  const [track, setTrack] = useState<TripTrack | null>(null);
  const [roadKm, setRoadKm] = useState<number | undefined>(undefined);
  /** Bumped to re-run the load effect — the Refresh button's only job. */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  /** The plotted route and the verdict on the claimed distance. */
  const geo = useMemo(() => {
    if (!track) return { waypoints: [], check: checkDistance({ claimedKm: 0, straightKm: 0, stops: 0 }) };
    const waypoints = waypointsOf({
      start: track.start,
      end: track.end,
      visits: track.stops,
      gpsPoints: track.gpsPoints,
    });
    const stops = routeOf(waypoints);
    return {
      waypoints,
      check: checkDistance({
        claimedKm: track.trip.distanceKm,
        straightKm: pathKm(stops),
        roadKm,
        stops: stops.length,
      }),
    };
  }, [track, roadKm]);

  /**
   * The GPS log, with the gap to the previous fix on each row.
   *
   * The gaps are what make the sparseness legible. A list of five coordinates
   * looks like a track until you see that four hours passed between the first
   * two — at which point it is obviously a handful of samples, and the reader
   * stops expecting the map to show a journey.
   */
  const gps = useMemo(() => {
    const points = track?.gpsPoints ?? [];
    return points.map((g, i) => {
      const prev = i > 0 ? points[i - 1] : undefined;
      const moved = prev && hasFix(prev) && hasFix(g) ? haversineKm(prev, g) : undefined;
      let gapLabel = '—';
      if (prev?.at && g.at) {
        const mins = Math.round(
          (new Date(g.at.replace(' ', 'T')).getTime() -
            new Date(prev.at.replace(' ', 'T')).getTime()) /
            60000,
        );
        if (Number.isFinite(mins)) {
          gapLabel =
            mins >= 60 ? `${Math.floor(mins / 60)}h ${String(mins % 60).padStart(2, '0')}m` : `${mins}m`;
        }
      }
      return {
        ...g,
        gapLabel,
        movedLabel: moved == null ? '—' : `${moved.toFixed(1)} km`,
      };
    });
  }, [track]);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRoadKm(undefined);
    Promise.all([
      Api.trips.get(tripId),
      Api.trips.listVisitsForTrip(tripId),
      Api.trips.getRates(),
      // The route is assembled from several documents, so a failure here must
      // not cost the rest of the page.
      Api.trips.getTrack(tripId).catch(() => null),
    ])
      .then(([t, v, r, k]) => {
        if (!live) return;
        setTrip(t);
        setVisits(v);
        setRates(r);
        setTrack(k);
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
            {/*
              How many GPS fixes the phone actually logged. This is the figure
              that decides whether the distance can be checked at all, so it
              belongs beside the money rather than buried below it.
            */}
            <Tile
              label="GPS points"
              value={String(track?.gpsPoints.length ?? 0)}
              tone={(track?.gpsPoints.length ?? 0) < 2 ? 'warn' : undefined}
              foot={
                (track?.gpsPoints.length ?? 0) < 2
                  ? 'Too few to trace'
                  : 'Logged during the trip'
              }
            />
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

          {/*
            The route, and what it can honestly say about the claim.
            Placed above the legs because the odometer figures below only mean
            something once you know where the rep actually went.
          */}
          <Card title="Route" className="mt-16">
            {!track ? (
              <Empty icon="—" title="No route could be assembled for this trip" />
            ) : geo.waypoints.length === 0 ? (
              <Empty icon="—" title="Nothing was recorded to plot">
                No punch-in fix, and none of the shops visited have coordinates on file.
              </Empty>
            ) : (
              <>
                <div className="tm__verdict">
                  <Badge tone={VERDICT[geo.check.verdict].tone}>
                    {VERDICT[geo.check.verdict].label}
                  </Badge>
                  <span className="small">{geo.check.note}</span>
                </div>

                <Suspense fallback={<Empty icon="◔" title="Loading the map…" />}>
                  <TripMap waypoints={geo.waypoints} onRoadDistance={setRoadKm} />
                </Suspense>

                {track.stops.length > 0 && (
                  <table className="table tm__stops">
                    <tbody>
                      {track.stops.map((s, i) => (
                        <tr key={s.visit.id}>
                          <td className="dim small" style={{ width: 28 }}>
                            {i + 1}
                          </td>
                          <td>{s.name}</td>
                          <td className="num small">{s.visit.checkIn?.slice(11, 16) ?? '—'}</td>
                          <td className="dim small">
                            {s.place ? '' : 'no coordinates on this party'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </>
            )}
          </Card>

          {/*
            The raw GPS log.
            Shown so HR can see for themselves whether the phone was recording,
            rather than inferring it from a map that looks sparse. The gap
            columns are the point: two fixes three hours apart cannot describe
            what happened in between, however precise each one is.
          */}
          <Card
            title="GPS points logged"
            className="mt-16"
            flush
            actions={
              <Badge tone={gps.length >= 2 ? 'ok' : 'warn'}>
                {gps.length} {gps.length === 1 ? 'point' : 'points'}
              </Badge>
            }
          >
            {gps.length === 0 ? (
              <Empty icon="—" title="The phone logged no GPS points on this trip">
                Nothing can be verified against location for this trip. The claimed distance rests
                on the odometer photographs alone.
              </Empty>
            ) : (
              <>
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Time</th>
                        <th>Coordinates</th>
                        <th className="right">Gap</th>
                        <th className="right">Moved</th>
                      </tr>
                    </thead>
                    <tbody>
                      {gps.map((g, i) => (
                        <tr key={`${g.latitude},${g.longitude},${i}`}>
                          <td className="dim small">{i + 1}</td>
                          <td className="num small">{g.at ? clockOf(g.at) : '—'}</td>
                          <td className="num small">
                            <a
                              href={`https://www.google.com/maps?q=${g.latitude},${g.longitude}`}
                              target="_blank"
                              rel="noreferrer"
                            >
                              {g.latitude.toFixed(5)}, {g.longitude.toFixed(5)}
                            </a>
                          </td>
                          <td className="right num small dim">{g.gapLabel}</td>
                          <td className="right num small dim">{g.movedLabel}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <p className="note" style={{ padding: '10px 12px 12px' }}>
                  {gps.length < 2 ? (
                    <>
                      A single fix records where the rep was at one moment. It cannot show a
                      journey, so no distance can be derived from it.
                    </>
                  ) : (
                    <>
                      These are samples, not a track — the app logs a fix occasionally rather than
                      continuously, so the straight lines between them are not the roads taken. The
                      route above is built from the shops checked in at, which is firmer evidence.
                    </>
                  )}
                </p>
              </>
            )}
          </Card>

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
