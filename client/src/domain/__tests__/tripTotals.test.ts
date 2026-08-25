/**
 * A trip's stored figures, computed from its legs.
 *
 * `shared/fixtures/trip_totals.json` states the rule; this asserts the
 * dashboard obeys it and `app/test/trip_totals_test.dart` asserts the phone
 * does. Both suites read the same cases, because both apps write trips and
 * this decides what a rep is paid.
 *
 * Two live bugs are pinned here:
 *
 *   - TRP-00311 claimed ₹371 against ₹185.50 after its leg was edited from
 *     Own Vehicle to Bike and nothing recomputed the stored cost.
 *   - Five of Prashanth's trips read as ₹0 because `legClaim` ignored
 *     `claimed_amount` on Mixed legs — ₹3,121 of real claims reported as stale.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/trip_totals.json';
import { legClaim, tripTotalsFromLegs } from '../trips';
import type { TripLeg, TripRates } from '../types';

const RATES: TripRates = {
  ownCar: cases.rates['Own Vehicle'],
  ownBike: cases.rates.Bike,
  companyCar: cases.rates['Company Vehicle (Car)'],
  companyBike: cases.rates['Company Vehicle (Bike)'],
  mixed: cases.rates.Mixed,
};

interface FixtureLeg {
  mode: string;
  km: number;
  has_odometer: number;
  claimed_amount: number;
}

/**
 * The fixture states a distance directly. `legDistance` derives it from the
 * odometer readings, so they are synthesised here — the arithmetic under test
 * is the totalling, not the subtraction.
 */
const toLeg = (l: FixtureLeg): TripLeg =>
  ({
    id: 'L',
    mode: l.mode,
    hasOdometer: l.has_odometer === 1,
    startOdometer: 0,
    endOdometer: l.has_odometer === 1 ? l.km : 0,
    distanceKm: l.km,
    claimedAmount: l.claimed_amount,
    approvedAmount: 0,
    notVerified: false,
    actualStartOdometer: 0,
    actualEndOdometer: 0,
  }) as TripLeg;

describe('trip totals, from the legs', () => {
  for (const c of cases.totals) {
    it(c.why, () => {
      const got = tripTotalsFromLegs((c.legs as FixtureLeg[]).map(toLeg), RATES);
      expect(got.totalKm).toBe(c.expect.total_km);
      expect(got.odometerKm).toBe(c.expect.odometer_km);
      expect(got.cost).toBe(c.expect.cost);
      expect(got.primaryMode).toBe(c.expect.primary_mode);
      expect(got.costBasis).toBe(c.expect.cost_basis);
    });
  }
});

describe('the two bugs this was written for', () => {
  it('TRP-00311: the same 53 km is ₹185.50 as Bike and ₹371 as Own Vehicle', () => {
    // Exactly double. "Own Vehicle" prices at the own-CAR rate, so a rep on
    // their own motorbike recorded that way is paid twice over.
    const km = 53;
    const bike = tripTotalsFromLegs(
      [toLeg({ mode: 'Bike', km, has_odometer: 1, claimed_amount: 0 })],
      RATES,
    );
    const car = tripTotalsFromLegs(
      [toLeg({ mode: 'Own Vehicle', km, has_odometer: 1, claimed_amount: 0 })],
      RATES,
    );
    expect(bike.cost).toBe(185.5);
    expect(car.cost).toBe(371);
    expect(car.cost).toBe(bike.cost * 2);
  });

  it("Prashanth's fares are not zero", () => {
    // A Mixed leg with no distance is a bus ticket. Reading it as ₹0 reported
    // five real claims as stale and would have cost him ₹3,121.
    const fares = [1088, 623, 168, 605, 637];
    for (const fare of fares) {
      const leg = toLeg({ mode: 'Mixed', km: 0, has_odometer: 0, claimed_amount: fare });
      expect(legClaim(leg, RATES)).toBe(fare);
      expect(tripTotalsFromLegs([leg], RATES).cost).toBe(fare);
    }
  });

  it('a fare on a non-Mixed leg is still ignored', () => {
    // The kilometres already paid for that journey. Adding the claimed amount
    // would pay for it twice, which is the opposite mistake.
    const leg = toLeg({ mode: 'Bike', km: 10, has_odometer: 1, claimed_amount: 500 });
    expect(legClaim(leg, RATES)).toBe(35);
  });
});
