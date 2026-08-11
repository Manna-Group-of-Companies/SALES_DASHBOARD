/**
 * Trip geography, and what it can honestly tell HR.
 *
 * The brief was a map with a blue line showing the road distance actually
 * travelled, so a claimed distance could be checked against a real one. The
 * data does not support that, and it matters that the screen says so rather
 * than drawing a line that looks like proof.
 *
 * **What the site actually stores.** `Trip.gps_points` is not a breadcrumb
 * trail. TRP-00250 claims 179 km and holds **one** point, recorded at
 * punch-in. TRP-00253 claims 93 km and holds **two**, three hours apart and
 * about 18 km from each other. `gps_distance_km` is 0 on all 140 trips because
 * there is nothing to compute it from, and `Trip Log` — which sounds like a
 * location feed — has no rows at all.
 *
 * You cannot trace a road from one point. Any line drawn through them would be
 * invented, and an invented line on a map is worse than no map: it looks like
 * evidence.
 *
 * **What can be reconstructed.** `Sales Visit` rows carry `custom_trip` and a
 * check-in time, and each names a Customer or Lead whose verified coordinates
 * are known. So the *places* a rep went, and the order they went in, are real
 * records — TRP-00250 has four stops, TRP-00253 has three. Routing between
 * those gives a **lower bound**: the shortest a person could have driven and
 * still made every stop.
 *
 * That bound is the useful thing. It cannot prove a claim is honest — a rep may
 * legitimately drive far further than the minimum — but a claim far *below* the
 * bound is impossible, and a claim far above it is worth a question.
 */

import type { SalesVisit } from './types';

export interface Point {
  latitude: number;
  longitude: number;
}

/** A place the rep is known to have been, in time order. */
export interface Waypoint extends Point {
  kind: 'start' | 'visit' | 'end' | 'gps';
  label: string;
  /** ISO timestamp, when known. */
  at?: string;
  /** The visit, customer or lead this came from. */
  ref?: string;
}

const EARTH_RADIUS_KM = 6371;

const toRad = (deg: number) => (deg * Math.PI) / 180;

/**
 * Great-circle distance in km.
 *
 * Straight-line, over the ground — never a road distance. Roads are longer,
 * always, so this is a floor beneath the floor.
 */
export function haversineKm(a: Point, b: Point): number {
  const dLat = toRad(b.latitude - a.latitude);
  const dLon = toRad(b.longitude - a.longitude);
  const lat1 = toRad(a.latitude);
  const lat2 = toRad(b.latitude);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.sin(dLon / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2);
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Total straight-line distance along a sequence of points. */
export function pathKm(points: Point[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i += 1) total += haversineKm(points[i - 1], points[i]);
  return Math.round(total * 100) / 100;
}

/**
 * A coordinate pair that is actually usable. `0,0` is the Atlantic, not Kerala.
 *
 * Generic so narrowing keeps whatever else the caller attached — a plain
 * `p is Point` would discard the timestamp on a GPS sample.
 */
export function hasFix<T extends Partial<Point>>(p: T | undefined | null): p is T & Point {
  if (!p) return false;
  const { latitude: lat, longitude: lng } = p;
  if (typeof lat !== 'number' || typeof lng !== 'number') return false;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  if (lat === 0 && lng === 0) return false;
  return Math.abs(lat) <= 90 && Math.abs(lng) <= 180;
}

/**
 * Build the ordered list of places a trip is known to have touched.
 *
 * Order is by time, not by the order rows happen to arrive: a visit list
 * sorted by name would draw a route that zig-zags across the district for no
 * reason and look like erratic driving.
 *
 * The trip's own start and end fixes bracket the visits. They are kept
 * separate from the visits because they mean something different — where the
 * rep punched in and out, rather than a shop they called at.
 */
export function waypointsOf(input: {
  start?: Partial<Point> & { at?: string };
  end?: Partial<Point> & { at?: string };
  visits: Array<{ visit: SalesVisit; place?: Partial<Point>; name: string }>;
  gpsPoints?: Array<Partial<Point> & { at?: string }>;
}): Waypoint[] {
  const out: Waypoint[] = [];

  if (hasFix(input.start)) {
    out.push({
      kind: 'start',
      label: 'Punched in',
      latitude: input.start.latitude,
      longitude: input.start.longitude,
      at: input.start.at,
    });
  }

  const stops = input.visits
    .filter((v) => hasFix(v.place))
    .sort((a, b) => (a.visit.checkIn ?? '').localeCompare(b.visit.checkIn ?? ''))
    .map<Waypoint>((v) => ({
      kind: 'visit',
      label: v.name,
      latitude: (v.place as Point).latitude,
      longitude: (v.place as Point).longitude,
      at: v.visit.checkIn,
      ref: v.visit.id,
    }));
  out.push(...stops);

  /*
   * Recorded GPS samples that are not already represented by the start fix.
   * They are shown because they are real observations, but they are never
   * joined into the route line — two samples hours apart say nothing about
   * the path between them.
   */
  for (const g of input.gpsPoints ?? []) {
    if (!hasFix(g)) continue;
    if (
      hasFix(input.start) &&
      Math.abs(g.latitude - input.start.latitude) < 1e-5 &&
      Math.abs(g.longitude - input.start.longitude) < 1e-5
    ) {
      continue; // the punch-in fix, already plotted
    }
    out.push({
      kind: 'gps',
      label: 'GPS sample',
      latitude: g.latitude,
      longitude: g.longitude,
      at: g.at,
    });
  }

  if (hasFix(input.end)) {
    out.push({
      kind: 'end',
      label: 'Punched out',
      latitude: input.end.latitude,
      longitude: input.end.longitude,
      at: input.end.at,
    });
  }

  return out;
}

/** The points the route line is drawn through — start, stops, end. Not samples. */
export function routeOf(waypoints: Waypoint[]): Waypoint[] {
  return waypoints.filter((w) => w.kind !== 'gps');
}

// ------------------------------------------------------------- the verdict ---

export type DistanceVerdict =
  | 'no_evidence'
  | 'impossible'
  | 'consistent'
  | 'far_above'
  | 'unknown';

export interface DistanceCheck {
  /** What the rep claimed, from the odometer. */
  claimedKm: number;
  /** Shortest road distance through the known stops, when routing succeeded. */
  roadKm?: number;
  /** Straight-line distance through the known stops. Always available. */
  straightKm: number;
  /** How many places the trip can be pinned to. */
  stops: number;
  verdict: DistanceVerdict;
  note: string;
}

/**
 * How a claimed distance stands against what the stops imply.
 *
 * The comparison is deliberately asymmetric, because the evidence is:
 *
 *   - **Below the road minimum** is the only thing that is *impossible*. You
 *     cannot visit those places in less than the shortest route between them.
 *   - **Far above** is a question, not a finding. A rep who doubles back, takes
 *     a diversion, or calls somewhere that generated no visit record will
 *     legitimately exceed the minimum.
 *   - **Fewer than two stops** means there is nothing to compare at all, and
 *     saying so is the honest answer.
 *
 * `IMPLAUSIBLE_RATIO` is where "above the minimum" stops being ordinary. It is
 * a prompt to look, never a verdict on the person.
 */
export const IMPLAUSIBLE_RATIO = 3;

/** Below this, a percentage gap on a short trip is just GPS scatter. */
const SHORT_TRIP_KM = 5;

export function checkDistance(input: {
  claimedKm: number;
  straightKm: number;
  roadKm?: number;
  stops: number;
}): DistanceCheck {
  const { claimedKm, straightKm, roadKm, stops } = input;
  const base = { claimedKm, straightKm, roadKm, stops };

  if (stops < 2) {
    return {
      ...base,
      verdict: 'no_evidence',
      note:
        stops === 0
          ? 'No location was recorded for this trip, so the distance cannot be checked.'
          : 'Only one place was recorded, so there is no route to measure against.',
    };
  }

  const minimum = roadKm ?? straightKm;
  if (minimum <= 0) {
    return { ...base, verdict: 'unknown', note: 'The recorded places give no measurable route.' };
  }

  if (claimedKm <= 0) {
    return {
      ...base,
      verdict: 'unknown',
      note: 'No odometer distance was claimed for this trip.',
    };
  }

  if (claimedKm + SHORT_TRIP_KM < minimum) {
    return {
      ...base,
      verdict: 'impossible',
      note: `The stops are at least ${minimum.toFixed(1)} km apart by road, but ${claimedKm} km was claimed. The rep cannot have reached them all in that distance.`,
    };
  }

  if (claimedKm > minimum * IMPLAUSIBLE_RATIO && claimedKm - minimum > SHORT_TRIP_KM) {
    return {
      ...base,
      verdict: 'far_above',
      note: `${claimedKm} km claimed against a ${minimum.toFixed(1)} km minimum through the recorded stops. That can be legitimate — doubling back, or calls that produced no visit record — but it is worth asking about.`,
    };
  }

  return {
    ...base,
    verdict: 'consistent',
    note: `${claimedKm} km claimed against a ${minimum.toFixed(1)} km minimum through the recorded stops. Consistent with the places visited.`,
  };
}

/** Map bounds that fit every point, for the initial view. */
export function boundsOf(points: Point[]): [[number, number], [number, number]] | null {
  if (!points.length) return null;
  let minLat = points[0].latitude;
  let maxLat = points[0].latitude;
  let minLng = points[0].longitude;
  let maxLng = points[0].longitude;
  for (const p of points) {
    minLat = Math.min(minLat, p.latitude);
    maxLat = Math.max(maxLat, p.latitude);
    minLng = Math.min(minLng, p.longitude);
    maxLng = Math.max(maxLng, p.longitude);
  }
  return [
    [minLat, minLng],
    [maxLat, maxLng],
  ];
}
