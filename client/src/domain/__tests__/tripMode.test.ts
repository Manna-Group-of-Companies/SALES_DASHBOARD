/**
 * Trip mode and cost, derived from the legs rather than the stored summary.
 *
 * ERPNext keeps `Trip.primary_mode` and `Trip.estimated_cost` as separate
 * stored fields, and nothing on the site keeps them in step with the legs.
 * Editing a leg in the Desk leaves both behind — and since the per-km rate
 * follows the mode, reading the stale field pays the wrong money.
 */

import { describe, expect, it } from 'vitest';
import {
  displayMode,
  modesOf,
  primaryModeStale,
  storedCostStale,
  travelClaim,
} from '../trips';
import type { Trip, TripLeg, TripRates } from '../types';

/** The live rates: Bike ₹3.50/km, Own Vehicle ₹7.00/km, company vehicles free. */
const RATES: TripRates = {
  ownCar: 7,
  ownBike: 3.5,
  companyCar: 0,
  companyBike: 0,
  mixed: 0,
};

const leg = (mode: string, km: number): TripLeg =>
  ({
    id: `L-${mode}-${km}`,
    mode,
    hasOdometer: true,
    startOdometer: 0,
    endOdometer: km,
    distanceKm: km,
    actualStartOdometer: 0,
    actualEndOdometer: 0,
    notVerified: false,
    claimedAmount: 0,
    approvedAmount: 0,
    status: 'Pending',
  }) as unknown as TripLeg;

const trip = (over: Partial<Trip> = {}): Trip =>
  ({
    id: 'TRP-TEST',
    person: 'Prasad V',
    date: '2026-08-11',
    primaryMode: 'Own Vehicle',
    distanceKm: 79,
    estimatedCost: 553,
    totalExpenses: 150,
    status: 'Completed',
    taggedReps: [],
    legs: [leg('Bike', 79)],
    expenses: [],
    ...over,
  }) as Trip;

describe('TRP-00257 — the leg was changed to Bike, the trip was not', () => {
  const t = trip();

  it('reads the mode off the leg, not the stale trip field', () => {
    expect(t.primaryMode).toBe('Own Vehicle');
    expect(displayMode(t)).toBe('Bike');
  });

  it('notices the trip field disagrees', () => {
    expect(primaryModeStale(t)).toBe(true);
  });

  it('charges the Bike rate, not the Own Vehicle rate', () => {
    // 79 km × ₹3.50 = ₹276.50, against the ₹553 ERPNext still stores.
    expect(travelClaim(t, RATES)).toBeCloseTo(276.5, 2);
    expect(t.estimatedCost).toBe(553);
  });

  it('notices the stored cost is stale', () => {
    expect(storedCostStale(t, RATES)).toBe(true);
  });

  it('would have overpaid by ₹276.50 had the stored figure been trusted', () => {
    expect(t.estimatedCost - travelClaim(t, RATES)).toBeCloseTo(276.5, 2);
  });
});

describe('when the two agree, nothing is flagged', () => {
  const t = trip({ primaryMode: 'Bike', estimatedCost: 276.5 });

  it('is not stale', () => {
    expect(primaryModeStale(t)).toBe(false);
    expect(storedCostStale(t, RATES)).toBe(false);
  });

  it('tolerates rounding', () => {
    expect(storedCostStale(trip({ primaryMode: 'Bike', estimatedCost: 277 }), RATES)).toBe(false);
  });
});

describe('a trip with several modes', () => {
  const t = trip({
    primaryMode: 'Own Vehicle',
    legs: [leg('Bike', 20), leg('Own Vehicle', 30)],
  });

  it('lists both rather than picking one', () => {
    expect(modesOf(t)).toEqual(['Bike', 'Own Vehicle']);
    expect(displayMode(t)).toBe('Mixed — Bike, Own Vehicle');
  });

  it('prices each leg at its own rate', () => {
    // 20 × 3.50 + 30 × 7.00 = 70 + 210 = 280
    expect(travelClaim(t, RATES)).toBeCloseTo(280, 2);
  });

  it('is stale unless the trip says Mixed', () => {
    expect(primaryModeStale(t)).toBe(true);
    expect(primaryModeStale(trip({ ...t, primaryMode: 'Mixed' }))).toBe(false);
  });
});

describe('a trip with no legs', () => {
  const t = trip({ legs: [] });

  it('falls back to the stored field, which is all there is', () => {
    expect(displayMode(t)).toBe('Own Vehicle');
  });

  it('flags nothing — there is nothing to disagree with', () => {
    expect(primaryModeStale(t)).toBe(false);
    expect(storedCostStale(t, RATES)).toBe(false);
  });
});

describe('an unrecognised mode earns nothing rather than guessing a rate', () => {
  const t = trip({ primaryMode: 'Helicopter', legs: [leg('Helicopter', 100)] });

  it('pays zero', () => {
    expect(travelClaim(t, RATES)).toBe(0);
  });

  it('still shows what was recorded', () => {
    expect(displayMode(t)).toBe('Helicopter');
  });
});
