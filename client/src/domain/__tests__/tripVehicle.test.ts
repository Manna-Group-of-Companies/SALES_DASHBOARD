/**
 * HR changing a leg's vehicle — the rate moves, the kilometres do not.
 *
 * Rates are the live ones from `shared/fixtures/trip_totals.json`, so the
 * money asserted here is the money a rep would actually be paid.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/trip_totals.json';
import {
  LEG_MODES,
  legClaim,
  legDistance,
  modeHasOdometer,
  tripTotalsFromLegs,
  withVehicle,
} from '../trips';
import type { TripLeg, TripRates } from '../types';

const RATES: TripRates = {
  ownCar: cases.rates['Own Vehicle'],
  ownBike: cases.rates.Bike,
  companyCar: cases.rates['Company Vehicle (Car)'],
  companyBike: cases.rates['Company Vehicle (Bike)'],
  mixed: cases.rates.Mixed,
};

function leg(over: Partial<TripLeg> = {}): TripLeg {
  return {
    id: 'L1',
    mode: 'Own Vehicle',
    vehicleNo: 'KL-07-AB-1234',
    hasOdometer: true,
    startOdometer: 1000,
    endOdometer: 1053,
    distanceKm: 53,
    notVerified: false,
    actualStartOdometer: 0,
    actualEndOdometer: 0,
    claimedAmount: 0,
    approvedAmount: 0,
    ...over,
  };
}

describe('withVehicle', () => {
  it('TRP-00311: a motorbike recorded as Own Vehicle is paid at the bike rate once changed', () => {
    const before = leg();
    const after = withVehicle(before, { mode: 'Bike', vehicleNo: 'KL-07-AB-1234' });
    expect(legClaim(before, RATES)).toBe(371);
    expect(legClaim(after, RATES)).toBe(185.5);
    expect(legDistance(after)).toBe(53);
    expect(tripTotalsFromLegs([after], RATES)).toMatchObject({ cost: 185.5, primaryMode: 'Bike' });
  });

  it('keeps a corrected reading when the new mode has no odometer', () => {
    // Typed 1000 → 1100, HR read 1000 → 1050 off the photo. The stored
    // leg_distance_km still says 100; falling back to it would undo the check.
    const corrected = leg({
      endOdometer: 1100,
      distanceKm: 100,
      notVerified: true,
      actualStartOdometer: 1000,
      actualEndOdometer: 1050,
    });
    expect(legDistance(corrected)).toBe(50);
    const mixed = withVehicle(corrected, { mode: 'Mixed', vehicleNo: '' });
    expect(mixed.hasOdometer).toBe(false);
    expect(legDistance(mixed)).toBe(50);
    expect(legClaim(mixed, RATES)).toBe(200);
  });

  it('a bus or taxi leg earns nothing per km, and has no odometer to check', () => {
    const bus = withVehicle(leg(), { mode: 'Bus', vehicleNo: '' });
    expect(bus.hasOdometer).toBe(false);
    expect(legClaim(bus, RATES)).toBe(0);
    expect(legDistance(bus)).toBe(53);
  });

  it('a Mixed fare survives a round trip through another mode', () => {
    // As the phone records one: no odometer on a Mixed leg, so no readings.
    const fare = leg({
      mode: 'Mixed',
      hasOdometer: false,
      startOdometer: 0,
      endOdometer: 0,
      distanceKm: 0,
      claimedAmount: 1088,
    });
    const bike = withVehicle(fare, { mode: 'Bike', vehicleNo: '' });
    expect(legClaim(bike, RATES)).toBe(0);
    const back = withVehicle(bike, { mode: 'Mixed', vehicleNo: '' });
    expect(legClaim(back, RATES)).toBe(1088);
  });

  it('leaves the readings, photos, check and approval alone', () => {
    const before = leg({
      startOdometerPhoto: '/private/files/start_odo.jpg',
      notVerified: true,
      actualStartOdometer: 1000,
      actualEndOdometer: 1050,
      approvedAmount: 350,
      status: 'Approved',
      remarks: 'checked',
    });
    const after = withVehicle(before, { mode: 'Company Vehicle (Car)', vehicleNo: ' KL-01 ' });
    expect(after).toEqual({
      ...before,
      mode: 'Company Vehicle (Car)',
      vehicleNo: 'KL-01',
      hasOdometer: true,
    });
  });

  it('a blank vehicle number clears it', () => {
    expect(withVehicle(leg(), { mode: 'Bike', vehicleNo: '   ' }).vehicleNo).toBeUndefined();
  });
});

describe('LEG_MODES', () => {
  it('offers every mode that has a rate, plus the fare-only ones', () => {
    for (const mode of Object.keys(cases.rates).filter((k) => k !== 'note')) {
      expect(LEG_MODES.map((m) => m.value)).toContain(mode);
    }
  });

  it('marks exactly the four vehicle modes as odometer modes, as the phone does', () => {
    expect(LEG_MODES.filter((m) => modeHasOdometer(m.value)).map((m) => m.value)).toEqual([
      'Own Vehicle',
      'Bike',
      'Company Vehicle (Car)',
      'Company Vehicle (Bike)',
    ]);
  });
});
