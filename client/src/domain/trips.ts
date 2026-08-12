/**
 * Travel claims — what a trip is worth, and whether it can be trusted.
 *
 * Verified against the live site on 7 Aug 2026:
 *
 *   - A `Trip` belongs to one `sales_person` and carries child `legs`,
 *     `expenses` and `tagged_reps`. A shared trip is ONE trip: the owner
 *     claims it, and everyone else is named in `tagged_csv`.
 *   - Money has two independent halves — **distance** (legs x per-km rate)
 *     and **out of pocket** (the expense rows). They are added, never mixed.
 *   - `primary_mode` "Mixed" means mixed *transport*, not shared travel. A
 *     mixed trip prices leg by leg, each leg at its own mode's rate.
 *
 * Pure module: no React, no Redux, no Axios.
 */

import type { Trip, TripExpense, TripLeg, TripRates, TravelMode } from './types';

/** Rates to fall back on only when the site's Single cannot be read. */
export const RATE_FALLBACK: TripRates = {
  ownCar: 0,
  ownBike: 0,
  companyCar: 0,
  companyBike: 0,
  mixed: 0,
};

/**
 * A day's distance beyond which the odometer is almost certainly a typo.
 *
 * Not a rule about how far anyone may travel — a detector for the reading
 * being entered instead of the difference. One live trip records 35,184 km in
 * a single day and claims a quarter of a million rupees on it.
 */
export const IMPLAUSIBLE_DAILY_KM = 500;

/** The per-km rate for a mode. Unknown modes earn nothing rather than guess. */
export function rateFor(mode: TravelMode, rates: TripRates): number {
  switch (mode) {
    case 'Own Vehicle':
      return rates.ownCar;
    case 'Bike':
      return rates.ownBike;
    case 'Company Vehicle (Car)':
      return rates.companyCar;
    case 'Company Vehicle (Bike)':
      return rates.companyBike;
    case 'Mixed':
      return rates.mixed;
    default:
      return 0;
  }
}

// ------------------------------------------------------- mode, from legs ---

/**
 * The modes actually travelled, taken from the legs.
 *
 * `Trip.primary_mode` is a **separate stored field**, not a summary of the
 * legs, and nothing keeps the two in step — there are no server scripts here.
 * Changing a leg from Own Vehicle to Bike in the Desk leaves `primary_mode`
 * saying Own Vehicle, and reading it then reports a mode nobody drove and a
 * rate nobody earned. TRP-00257 on 11 Aug 2026 is exactly that: leg `Bike`,
 * `primary_mode` `Own Vehicle`, ₹553 stored against ₹276.50 actually due.
 */
export function modesOf(trip: Trip): TravelMode[] {
  return [...new Set(trip.legs.map((l) => l.mode).filter(Boolean))];
}

/**
 * What to show in a Mode column.
 *
 * Derived from the legs. Several modes read as "Mixed" plus the list, because
 * a trip that was half bike and half car is not honestly either. With no legs
 * at all there is nothing to derive, so the stored field is the only thing
 * left — and it is at least what the rep originally chose.
 */
export function displayMode(trip: Trip): string {
  const modes = modesOf(trip);
  if (modes.length === 0) return trip.primaryMode || '—';
  if (modes.length === 1) return modes[0];
  return `Mixed — ${modes.join(', ')}`;
}

/**
 * Whether `primary_mode` disagrees with the legs.
 *
 * Surfaced rather than silently corrected: the stale field is what the mobile
 * app and any ERPNext report still read, so a disagreement is a live problem
 * on other screens, not a display detail here.
 */
export function primaryModeStale(trip: Trip): boolean {
  const modes = modesOf(trip);
  if (modes.length === 0) return false;
  if (modes.length > 1) return trip.primaryMode !== 'Mixed';
  return modes[0] !== trip.primaryMode;
}

/**
 * Whether the stored `estimated_cost` disagrees with what the legs now earn.
 *
 * A tolerance of one rupee absorbs rounding; anything above that is a real
 * gap, and on TRP-00257 it is ₹276.50 against ₹553.
 */
export function storedCostStale(trip: Trip, rates: TripRates): boolean {
  if (!trip.legs.length) return false;
  return Math.abs(trip.estimatedCost - travelClaim(trip, rates)) > 1;
}

// ------------------------------------------------------------ odometers ---

export interface Reading {
  start: number;
  end: number;
  /** True when HR's figures differ from the rep's — a real correction. */
  corrected: boolean;
}

/** Has HR recorded what the photo actually says, either way? */
export function hasCheckedReading(leg: TripLeg): boolean {
  return leg.actualStartOdometer > 0 || leg.actualEndOdometer > 0;
}

/**
 * Where a leg stands in the check.
 *
 * Three states, and the difference between the first two is the point:
 * `unchecked` means nobody has compared the photo with the typed figure yet,
 * while `verified` means somebody has and they agree. An expense sheet that
 * cannot tell those apart is asking HR to trust a number no one has looked at.
 */
export type CheckState = 'unchecked' | 'verified' | 'corrected';

export function checkState(leg: TripLeg): CheckState {
  if (leg.notVerified) return hasCheckedReading(leg) ? 'corrected' : 'unchecked';
  return hasCheckedReading(leg) ? 'verified' : 'unchecked';
}

export function isVerified(leg: TripLeg): boolean {
  return checkState(leg) === 'verified';
}

/**
 * The odometer readings a claim should actually be computed from.
 *
 * HR's figures win once they exist. A ticked "differs" with both fields still
 * blank means *flagged, not yet corrected* — pricing that at zero would
 * quietly dock the rep before anyone had checked anything.
 */
export function effectiveReading(leg: TripLeg): Reading {
  if (hasCheckedReading(leg)) {
    return {
      start: leg.actualStartOdometer,
      end: leg.actualEndOdometer,
      corrected:
        leg.actualStartOdometer !== leg.startOdometer ||
        leg.actualEndOdometer !== leg.endOdometer,
    };
  }
  return { start: leg.startOdometer, end: leg.endOdometer, corrected: false };
}

/** Distance for one leg, in km. Never negative. */
export function legDistance(leg: TripLeg): number {
  if (!leg.hasOdometer) return Math.max(0, leg.distanceKm);
  const { start, end } = effectiveReading(leg);
  if (!(start > 0 && end > 0)) return Math.max(0, leg.distanceKm);
  return Math.max(0, round1(end - start));
}

/** Has HR flagged this leg but not yet supplied the real numbers? */
export function awaitingCorrection(leg: TripLeg): boolean {
  return leg.notVerified && !hasCheckedReading(leg);
}

/** A leg worth a human look: it has a photo to check, or the numbers look wrong. */
export function needsCheck(leg: TripLeg): boolean {
  if (!leg.hasOdometer) return false;
  if (legDistance(leg) > IMPLAUSIBLE_DAILY_KM) return true;
  if (leg.notVerified) return true;
  // Already confirmed against the photo — no longer anybody's work.
  if (isVerified(leg)) return false;
  return Boolean(leg.startOdometerPhoto || leg.endOdometerPhoto);
}

export function isImplausible(leg: TripLeg): boolean {
  return legDistance(leg) > IMPLAUSIBLE_DAILY_KM;
}

/**
 * A trip's distance, recomputed from its legs.
 *
 * NOT `Trip.total_distance_km`. That field holds what the rep's app worked out
 * from the typed odometer, so a leg HR has since corrected leaves the stored
 * total stale — and the total is what a month's kilometres, and therefore the
 * travel claim, are summed from. Recomputing from `legDistance` means one
 * corrected reading flows through the row, the month and the payout together.
 *
 * Falls back to the stored figure only when a trip has no legs at all.
 */
export function tripDistance(trip: Trip): number {
  if (!trip.legs.length) return Math.max(0, trip.distanceKm);
  return round1(trip.legs.reduce((sum, l) => sum + legDistance(l), 0));
}

// ---------------------------------------------------------------- money ---

/** Distance money for one leg. */
export function legClaim(leg: TripLeg, rates: TripRates): number {
  return round2(legDistance(leg) * rateFor(leg.mode, rates));
}

/** Distance money for a whole trip — every leg at its own mode's rate. */
export function travelClaim(trip: Trip, rates: TripRates): number {
  return round2(trip.legs.reduce((sum, l) => sum + legClaim(l, rates), 0));
}

/** What the rep actually paid out: allowances, lodging, tickets. */
export function outOfPocket(trip: Trip): number {
  return round2(trip.expenses.reduce((sum, e) => sum + (e.amount || 0), 0));
}

/** What HR has approved so far of that out-of-pocket total. */
export function approvedOutOfPocket(trip: Trip): number {
  return round2(trip.expenses.reduce((sum, e) => sum + (e.approvedAmount || 0), 0));
}

/** The full claim for a trip: distance money plus out of pocket. */
export function tripClaim(trip: Trip, rates: TripRates): number {
  return round2(travelClaim(trip, rates) + outOfPocket(trip));
}

export function expenseByCategory(trip: Trip, category: string): number {
  return round2(
    trip.expenses
      .filter((e) => (e.category || '').toLowerCase() === category.toLowerCase())
      .reduce((sum, e) => sum + (e.amount || 0), 0),
  );
}

export function dailyAllowance(trip: Trip): number {
  return expenseByCategory(trip, 'Daily Allowance');
}

/** Everything that is not the daily allowance — lodging, bus and train tickets. */
export function billedExpenses(trip: Trip): number {
  return round2(
    trip.expenses
      .filter((e) => (e.category || '').toLowerCase() !== 'daily allowance')
      .reduce((sum, e) => sum + (e.amount || 0), 0),
  );
}

export function hasBills(trip: Trip): TripExpense[] {
  return trip.expenses.filter((e) => e.hasBill && e.billPhoto);
}

// --------------------------------------------------------------- shared ---

/** `|Renjith|Saneesh|` -> `['Renjith', 'Saneesh']`. */
export function parseTagged(csv?: string): string[] {
  if (!csv) return [];
  return csv
    .split('|')
    .map((s) => s.trim())
    .filter(Boolean);
}

export function isShared(trip: Trip): boolean {
  return trip.taggedReps.length > 0;
}

/** Everyone the cost covered — the owner plus whoever travelled along. */
export function headcount(trip: Trip): number {
  return 1 + trip.taggedReps.length;
}

/**
 * Cost per head, for information only.
 *
 * The claim is never split: it is owed in full to whoever paid. This figure
 * exists so HR can see that a ₹1,764 trip carrying three people was cheaper
 * per person than three solo ones — not so anyone can divide the payment.
 */
export function costPerHead(trip: Trip, rates: TripRates): number {
  return round2(tripClaim(trip, rates) / headcount(trip));
}

/** How this trip should read on one person's sheet. */
export type Participation = 'owner' | 'joined' | 'none';

export function participationOf(trip: Trip, person: string): Participation {
  if (trip.person === person) return 'owner';
  if (trip.taggedReps.includes(person)) return 'joined';
  return 'none';
}

/**
 * Trips to show on one person's monthly sheet.
 *
 * Includes the ones they were tagged on: a day where somebody else paid still
 * has to appear, or the sheet reads as if they did nothing that day.
 */
export function tripsFor(trips: Trip[], person: string): Trip[] {
  return trips
    .filter((t) => participationOf(t, person) !== 'none')
    .sort((a, b) => a.date.localeCompare(b.date));
}

/**
 * Did this person's team manager travel with them on this trip?
 *
 * Two shapes count, because either party can own the document: the rep's own
 * trip with the manager tagged on it, or the manager's trip with the rep
 * tagged. Both mean the same thing on the ground — they were in the vehicle
 * together — and the weekly report counts them the same way.
 */
export function travelledWithManager(trip: Trip, personId: string, manager: string): boolean {
  if (!manager) return false;
  const role = participationOf(trip, personId);
  if (role === 'none') return false;
  if (trip.person === manager) return true;
  return trip.taggedReps.includes(manager);
}

/** Distinct days on which any of these trips happened. */
export function distinctDays(trips: Trip[]): number {
  return new Set(trips.map((t) => t.date)).size;
}

/**
 * Team-level cost, counting each trip once.
 *
 * A shared trip appears on several sheets; summing per person would bill it
 * two or three times over.
 */
export function teamClaim(trips: Trip[], rates: TripRates): number {
  const seen = new Set<string>();
  let total = 0;
  for (const t of trips) {
    if (seen.has(t.id)) continue;
    seen.add(t.id);
    total += tripClaim(t, rates);
  }
  return round2(total);
}

// ---------------------------------------------------------------- utils ---

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
