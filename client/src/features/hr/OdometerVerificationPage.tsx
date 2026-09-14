/**
 * Odometer verification — HR checks the photo against what the rep typed.
 *
 * Reps enter the odometer reading *and* photograph the dial. The two can
 * disagree, honestly or otherwise, and the difference is money: every km is
 * ₹3.50 on a bike and ₹7.00 in a car. This screen puts the photo next to the
 * typed figure so one person can settle it.
 *
 * Ticking "Not verified" reveals the actual-reading fields; what HR types
 * there becomes the figure the claim is computed from. Un-ticking clears them,
 * so a leg can never read as verified while still carrying a hidden override.
 *
 * Writes go through the signed-in user's own ERPNext session, so the record
 * shows who checked it.
 */

import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import type { Trip, TripLeg, TripRates } from '@/domain/types';
import {
  awaitingCorrection,
  checkState,
  effectiveReading,
  isImplausible,
  IMPLAUSIBLE_DAILY_KM,
  legClaim,
  legDistance,
  needsCheck,
  rateFor,
} from '@/domain/trips';
import { formatDate, todayIso } from '@/domain/orderRules';
import { shiftIso } from '@/domain/attendance';
import { Api } from '@/api/client';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Input,
  Modal,
  Segmented,
  Select,
} from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import './attendance.css';

/** How far back the queue looks. Older claims are settled, not pending. */
const WINDOW_DAYS = 60;

type Filter = 'todo' | 'flagged' | 'all';

export function OdometerVerificationPage() {
  const today = todayIso();
  const [trips, setTrips] = useState<Trip[]>([]);
  const [rates, setRates] = useState<TripRates | null>(null);
  const [filter, setFilter] = useState<Filter>('todo');
  const [person, setPerson] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = () => {
    setLoading(true);
    setError(null);
    Promise.all([Api.trips.list(shiftIso(today, -WINDOW_DAYS), today), Api.trips.getRates()])
      .then(([t, r]) => {
        setTrips(t);
        setRates(r);
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not read trips from ERPNext.'),
      )
      .finally(() => setLoading(false));
  };

  useEffect(load, [today]);

  /**
   * Everyone with something to check, with their outstanding count.
   *
   * Built from the unfiltered set so the dropdown does not shrink as you work
   * through it — a name vanishing mid-review is disorienting.
   */
  const peopleWithWork = useMemo(() => {
    const counts = new Map<string, number>();
    for (const trip of trips) {
      const n = trip.legs.filter(needsCheck).length;
      if (n) counts.set(trip.person, (counts.get(trip.person) ?? 0) + n);
    }
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [trips]);

  /**
   * Legs worth a human look, newest first, each with its parent trip.
   *
   * `all` means every leg, including the ones with no photo on them at all.
   * Those are invisible to `needsCheck` by design — there is nothing to check
   * against — but they are exactly the legs somebody needs to reach in order
   * to attach the missing photo, so a filter that hides them leaves no way in.
   */
  const rows = useMemo(() => {
    const out: Array<{ trip: Trip; leg: TripLeg }> = [];
    for (const trip of trips) {
      if (person && trip.person !== person) continue;
      for (const leg of trip.legs) {
        if (filter === 'all') {
          out.push({ trip, leg });
          continue;
        }
        if (!needsCheck(leg)) continue;
        if (filter === 'flagged' && !leg.notVerified) continue;
        if (filter === 'todo' && leg.notVerified && !awaitingCorrection(leg)) continue;
        out.push({ trip, leg });
      }
    }
    return out.sort((a, b) => b.trip.date.localeCompare(a.trip.date));
  }, [trips, filter, person]);

  /** How many of the shown legs are still missing one or both photos. */
  const missingPhotos = useMemo(
    () => rows.filter(({ leg }) => !leg.startOdometerPhoto || !leg.endOdometerPhoto).length,
    [rows],
  );

  const implausible = useMemo(
    () => trips.flatMap((t) => t.legs.filter(isImplausible).map((l) => ({ trip: t, leg: l }))),
    [trips],
  );

  const onSaved = (updated: Trip) => {
    setTrips((cur) => cur.map((t) => (t.id === updated.id ? updated : t)));
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Odometer verification</div>
          <div className="page-head__sub">
            Check the photo against what the rep typed — last {WINDOW_DAYS} days
          </div>
        </div>
        <div className="odo__toolbar">
          <RefreshButton onClick={load} loading={loading} />
          <Select
            value={person}
            onChange={(e) => setPerson(e.target.value)}
            aria-label="Sales person"
          >
            <option value="">Everyone ({peopleWithWork.reduce((s, [, n]) => s + n, 0)})</option>
            {peopleWithWork.map(([name, n]) => (
              <option key={name} value={name}>
                {name} ({n})
              </option>
            ))}
          </Select>
          <Segmented
            ariaLabel="Filter"
            value={filter}
            onChange={setFilter}
            options={[
              { value: 'todo', label: 'To check' },
              { value: 'flagged', label: 'Flagged' },
              { value: 'all', label: 'All legs' },
            ]}
          />
        </div>
      </div>

      {!loading && !error && rows.length > 0 && (
        <p className="note" style={{ marginBottom: 12 }}>
          Showing <b>{rows.length}</b> leg{rows.length === 1 ? '' : 's'}
          {person ? ` for ${person}` : ' across everyone'}
          {missingPhotos > 0 && (
            <>
              {' — '}
              <b>{missingPhotos}</b> still missing a photo.
            </>
          )}
          {missingPhotos === 0 && '.'}
        </p>
      )}

      {error && (
        <Alert tone="danger" title="Could not read trips">
          {error}
        </Alert>
      )}

      {!error && implausible.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert
            tone="danger"
            title={`${implausible.length} leg${implausible.length === 1 ? '' : 's'} record an impossible distance`}
          >
            More than {IMPLAUSIBLE_DAILY_KM} km in a single day — almost always an odometer
            *reading* typed where the *difference* belongs. Correct these first; they distort every
            total they touch.
          </Alert>
        </div>
      )}

      {loading && <Empty icon="◔" title="Reading trips…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="Nothing to check">
          {filter === 'todo'
            ? 'Every leg with a photo has been looked at.'
            : 'No legs match this filter.'}
        </Empty>
      )}

      {!loading && !error && rates && (
        <div className="stack gap-3">
          {rows.map(({ trip, leg }) => (
            <LegCard
              key={leg.id}
              trip={trip}
              leg={leg}
              rates={rates}
              onSaved={onSaved}
              onError={setError}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function LegCard({
  trip,
  leg,
  rates,
  onSaved,
  onError,
}: {
  trip: Trip;
  leg: TripLeg;
  rates: TripRates;
  onSaved: (t: Trip) => void;
  onError: (m: string) => void;
}) {
  const reading = effectiveReading(leg);
  const state = checkState(leg);

  /** `unchecked` | `verified` (photo matches) | `corrected` (photo differs). */
  const [outcome, setOutcome] = useState<'unchecked' | 'verified' | 'corrected'>(state);
  const [start, setStart] = useState(leg.actualStartOdometer || leg.startOdometer || 0);
  const [end, setEnd] = useState(leg.actualEndOdometer || leg.endOdometer || 0);
  const [saving, setSaving] = useState(false);

  /** Which photo slot is mid-upload, or null. One at a time per leg: both
   *  writes go through the same `legs` array, so overlapping them would let
   *  the slower one re-send the other's row as it was before. */
  const [uploading, setUploading] = useState<'start' | 'end' | null>(null);

  const addPhoto = async (slot: 'start' | 'end', file: File) => {
    setUploading(slot);
    try {
      const updated = await Api.trips.uploadLegPhoto({
        tripId: trip.id,
        legId: leg.id,
        slot,
        file,
      });
      onSaved(updated);
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not upload the photo.');
    } finally {
      setUploading(null);
    }
  };

  /** The slot whose delete is awaiting confirmation, or null. */
  const [confirmingDelete, setConfirmingDelete] = useState<'start' | 'end' | null>(null);

  const deletePhoto = async (slot: 'start' | 'end') => {
    setUploading(slot);
    try {
      const updated = await Api.trips.removeLegPhoto({ tripId: trip.id, legId: leg.id, slot });
      onSaved(updated);
      setConfirmingDelete(null);
    } catch (e) {
      setConfirmingDelete(null);
      onError(e instanceof Error ? e.message : 'Could not delete the photo.');
    } finally {
      setUploading(null);
    }
  };

  const rate = rateFor(leg.mode, rates);
  const currentDistance = legDistance(leg);
  const currentClaim = legClaim(leg, rates);

  // What the claim becomes if this outcome is saved.
  const nextDistance =
    outcome === 'corrected' && start > 0 && end > 0
      ? Math.max(0, end - start)
      : outcome === 'verified'
        ? Math.max(0, (leg.endOdometer || 0) - (leg.startOdometer || 0))
        : currentDistance;
  const nextClaim = Math.round(nextDistance * rate * 100) / 100;
  const delta = Math.round((nextClaim - currentClaim) * 100) / 100;

  const dirty =
    outcome !== state ||
    (outcome === 'corrected' &&
      (start !== leg.actualStartOdometer || end !== leg.actualEndOdometer));

  const save = async () => {
    setSaving(true);
    try {
      const updated = await Api.trips.verifyLeg({
        tripId: trip.id,
        legId: leg.id,
        outcome: outcome === 'unchecked' ? 'clear' : outcome,
        actualStart: start,
        actualEnd: end,
      });
      onSaved(updated);
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not save the check.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card
      title={
        <span className="odo__title">
          <span>
            {trip.person} · {formatDate(trip.date)}
          </span>
          {/* Which trip this reading came from, and a way into its full record. */}
          <Link to={`/hr/trips/${trip.id}`} className="odo__triplink">
            <span className="mono">{trip.id}</span>
            <span aria-hidden> →</span>
          </Link>
        </span>
      }
      actions={
        <span className="odo__chips">
          <Badge tone="neutral">{leg.mode}</Badge>
          {leg.vehicleNo && <Badge tone="neutral">#{leg.vehicleNo}</Badge>}
          {isImplausible(leg) && <Badge tone="danger">impossible distance</Badge>}
          {awaitingCorrection(leg) && <Badge tone="warn">awaiting reading</Badge>}
          {state === 'verified' && <Badge tone="ok">verified</Badge>}
        </span>
      }
    >
      <div className="odo">
        <div className="odo__photos">
          <Photo
            label="Start photo"
            src={leg.startOdometerPhoto}
            busy={uploading === 'start'}
            disabled={uploading !== null}
            onPick={(file) => addPhoto('start', file)}
            onDelete={() => setConfirmingDelete('start')}
          />
          <Photo
            label="End photo"
            src={leg.endOdometerPhoto}
            busy={uploading === 'end'}
            disabled={uploading !== null}
            onPick={(file) => addPhoto('end', file)}
            onDelete={() => setConfirmingDelete('end')}
          />
        </div>

        {confirmingDelete && (
          <Modal
            title={`Delete the ${confirmingDelete} photo?`}
            onClose={() => uploading === null && setConfirmingDelete(null)}
            footer={
              <>
                <Button onClick={() => setConfirmingDelete(null)} disabled={uploading !== null}>
                  Cancel
                </Button>
                <Button
                  variant="danger"
                  loading={uploading !== null}
                  onClick={() => void deletePhoto(confirmingDelete)}
                >
                  Delete photo
                </Button>
              </>
            }
          >
            <p>
              {trip.person} · {formatDate(trip.date)} · {leg.mode}
            </p>
            <p className="note">
              The photo is taken off this leg. The file itself stays attached to trip{' '}
              <span className="mono">{trip.id}</span> in ERPNext, so there is still a record of
              what was there and who added it.
            </p>
          </Modal>
        )}

        <div className="odo__data">
          <table className="table odo__table">
            <thead>
              <tr>
                <th />
                <th className="right">Typed by rep</th>
                <th className="right">Actual (from photo)</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Start</td>
                <td className="right num">{leg.startOdometer || '—'}</td>
                <td className="right">
                  {outcome === 'corrected' ? (
                    <Input
                      numeric
                      compact
                      type="number"
                      value={start || ''}
                      onChange={(e) => setStart(Number(e.target.value) || 0)}
                    />
                  ) : outcome === 'verified' ? (
                    <span className="num">{leg.startOdometer || '—'}</span>
                  ) : (
                    <span className="dim">—</span>
                  )}
                </td>
              </tr>
              <tr>
                <td>End</td>
                <td className="right num">{leg.endOdometer || '—'}</td>
                <td className="right">
                  {outcome === 'corrected' ? (
                    <Input
                      numeric
                      compact
                      type="number"
                      value={end || ''}
                      onChange={(e) => setEnd(Number(e.target.value) || 0)}
                    />
                  ) : outcome === 'verified' ? (
                    <span className="num">{leg.endOdometer || '—'}</span>
                  ) : (
                    <span className="dim">—</span>
                  )}
                </td>
              </tr>
              <tr>
                <td>Distance</td>
                <td className="right num">{currentDistance} km</td>
                <td className="right num">
                  {outcome === 'unchecked' ? '—' : `${nextDistance} km`}
                </td>
              </tr>
              <tr>
                <td>
                  Claim <span className="dim tiny">@ {money(rate, 2)}/km</span>
                </td>
                <td className="right num">{money(currentClaim, 2)}</td>
                <td className="right num">
                  {outcome === 'unchecked' ? (
                    '—'
                  ) : (
                    <b className={delta < 0 ? 'odo__down' : delta > 0 ? 'odo__up' : undefined}>
                      {money(nextClaim, 2)}
                    </b>
                  )}
                </td>
              </tr>
            </tbody>
          </table>

          {state === 'verified' && !dirty && (
            <p className="note">Checked against the photo — the readings agree.</p>
          )}
          {reading.corrected && !dirty && (
            <p className="note">Priced from HR's corrected readings, not the rep's.</p>
          )}

          {outcome !== 'unchecked' && delta !== 0 && (
            <p className="note">
              Saving changes this claim by <b>{money(Math.abs(delta), 2)}</b>{' '}
              {delta < 0 ? 'downward' : 'upward'}.
            </p>
          )}

          <div className="odo__actions">
            <span className="odo__checks">
              <label className="odo__check">
                <input
                  type="checkbox"
                  checked={outcome === 'verified'}
                  onChange={(e) => setOutcome(e.target.checked ? 'verified' : 'unchecked')}
                />
                Verified — photo matches the typed reading
              </label>
              <label className="odo__check">
                <input
                  type="checkbox"
                  checked={outcome === 'corrected'}
                  onChange={(e) => setOutcome(e.target.checked ? 'corrected' : 'unchecked')}
                />
                Not verified — photo differs
              </label>
            </span>
            <Button
              size="sm"
              onClick={save}
              disabled={
                !dirty || saving || (outcome === 'corrected' && !(start > 0 && end > 0))
              }
              loading={saving}
            >
              Save
            </Button>
          </div>
        </div>
      </div>
    </Card>
  );
}

/**
 * One odometer photo, and the way to put one there.
 *
 * A rep photographs the dial from the phone, but a phone with no signal at the
 * depot gate, a camera that failed, or a leg entered by hand all end the same
 * way: a claim with no evidence behind it. HR can attach the picture the rep
 * sent another way rather than leaving the leg unverifiable for good.
 */
function Photo({
  label,
  src,
  busy,
  disabled,
  onPick,
  onDelete,
}: {
  label: string;
  src?: string;
  busy: boolean;
  disabled: boolean;
  onPick: (file: File) => void;
  onDelete: () => void;
}) {
  const inputRef = useRef<HTMLInputElement | null>(null);

  return (
    <Field label={label}>
      {src ? (
        // Private files are served by Frappe through the same session cookie,
        // so the dev proxy reaches them without any extra auth.
        <a href={src} target="_blank" rel="noreferrer" className="odo__photo">
          <img src={src} alt={label} loading="lazy" />
        </a>
      ) : (
        <div className="odo__photo is-empty">No photo</div>
      )}
      <div className="odo__photoadd">
        <input
          ref={inputRef}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            const file = e.target.files?.[0];
            // Cleared so that picking the SAME file again still fires
            // `change` — otherwise a failed upload cannot be retried with the
            // very file that failed, which is the one you always want to retry.
            e.target.value = '';
            if (file) onPick(file);
          }}
        />
        <Button
          size="sm"
          variant="ghost"
          onClick={() => inputRef.current?.click()}
          loading={busy}
          disabled={disabled}
        >
          {src ? 'Replace photo' : 'Add photo'}
        </Button>
        {src && (
          <Button size="sm" variant="danger" onClick={onDelete} disabled={disabled}>
            Delete
          </Button>
        )}
      </div>
    </Field>
  );
}
