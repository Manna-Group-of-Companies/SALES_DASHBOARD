/**
 * HR changes the vehicle a leg was recorded on — its mode and its number.
 *
 * Mostly this is a rep on their own motorbike who picked "Own Vehicle", which
 * pays the car rate. The dialog shows what the leg earns now and what it will
 * earn, before anything is saved, because the whole point of the change is
 * the money. The rule behind it is `withVehicle` in domain/trips.ts.
 */

import { useState } from 'react';
import type { Trip, TripLeg, TripRates } from '@/domain/types';
import { LEG_MODES, legClaim, legDistance, rateFor, withVehicle } from '@/domain/trips';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Button, Field, Input, Modal, Select } from '@/components/ui';
import { money } from '@/components/common/format';

export function ChangeVehicleModal({
  trip,
  leg,
  rates,
  onSaved,
  onClose,
}: {
  trip: Trip;
  leg: TripLeg;
  rates: TripRates;
  onSaved: (t: Trip) => void;
  onClose: () => void;
}) {
  // A leg on a mode this list does not know keeps it selectable, so opening
  // the dialog never silently proposes a different mode.
  const known = LEG_MODES.some((m) => m.value === leg.mode);
  const [mode, setMode] = useState(leg.mode);
  const [vehicleNo, setVehicleNo] = useState(leg.vehicleNo ?? '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const after = withVehicle(leg, { mode, vehicleNo });
  const claimNow = legClaim(leg, rates);
  const claimAfter = legClaim(after, rates);
  const delta = Math.round((claimAfter - claimNow) * 100) / 100;

  const dirty = mode !== leg.mode || vehicleNo.trim() !== (leg.vehicleNo ?? '').trim();
  const approved = leg.approvedAmount > 0 || leg.status === 'Approved';

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const updated = await Api.trips.changeLegVehicle({
        tripId: trip.id,
        legId: leg.id,
        mode,
        vehicleNo,
      });
      onSaved(updated);
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not change the vehicle.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      title="Change vehicle"
      onClose={() => !saving && onClose()}
      footer={
        <>
          <Button onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button
            variant="primary"
            loading={saving}
            disabled={!dirty}
            onClick={() => void save()}
          >
            Save vehicle
          </Button>
        </>
      }
    >
      <p>
        {trip.person} · {formatDate(trip.date)} · <span className="mono">{trip.id}</span>
      </p>
      <p className="note">
        Recorded as <b>{leg.mode || 'no mode'}</b>
        {leg.vehicleNo ? (
          <>
            {' '}
            on <b>{leg.vehicleNo}</b>
          </>
        ) : null}{' '}
        · {legDistance(leg)} km
      </p>

      <div className="stack gap-3" style={{ marginTop: 12 }}>
        <Field label="Mode" htmlFor="cv-mode">
          <Select id="cv-mode" value={mode} onChange={(e) => setMode(e.target.value)}>
            {!known && <option value={leg.mode}>{leg.mode || '—'}</option>}
            {LEG_MODES.map((m) => (
              <option key={m.value} value={m.value}>
                {m.label} — {money(rateFor(m.value, rates), 2)}/km
              </option>
            ))}
          </Select>
        </Field>

        <Field label="Vehicle number" htmlFor="cv-no" hint="Leave blank for a bus, train or taxi.">
          <Input
            id="cv-no"
            value={vehicleNo}
            onChange={(e) => setVehicleNo(e.target.value.toUpperCase())}
            placeholder="KL-07-AB-1234"
          />
        </Field>

        <table className="table odo__table">
          <tbody>
            <tr>
              <td>Claim now</td>
              <td className="right num">{money(claimNow, 2)}</td>
            </tr>
            <tr>
              <td>After the change</td>
              <td className="right num">
                <b>{money(claimAfter, 2)}</b>
                {delta !== 0 && (
                  <span className="dim">
                    {' '}
                    ({delta > 0 ? '+' : '−'}
                    {money(Math.abs(delta), 2)})
                  </span>
                )}
              </td>
            </tr>
          </tbody>
        </table>

        {mode === 'Own Vehicle' && leg.mode !== 'Own Vehicle' && (
          <Alert tone="warn">
            Own Vehicle is paid at the <b>car</b> rate. A rep on their own motorbike is{' '}
            <b>Bike</b>.
          </Alert>
        )}
        {(mode === 'Bus' || mode === 'Taxi') && (
          <Alert tone="info">
            Bus, train and taxi legs earn nothing per km. The fare is claimed in the trip's
            expenses, with its bill.
          </Alert>
        )}
        {approved && dirty && (
          <Alert tone="warn" title="This leg is already approved">
            {leg.approvedAmount > 0 ? `Approved for ${money(leg.approvedAmount, 2)}. ` : ''}
            The approved amount is not changed by this. Review the leg again if it should follow
            the new claim.
          </Alert>
        )}
        {error && (
          <Alert tone="danger" title="Not saved">
            {error}
          </Alert>
        )}
      </div>
    </Modal>
  );
}
