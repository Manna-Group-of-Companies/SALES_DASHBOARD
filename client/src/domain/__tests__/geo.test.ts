/**
 * Trip geography, against the real trips on the site.
 *
 * The load-bearing rule: a claim **below** the road minimum is impossible, a
 * claim **above** it is only a question. Getting that asymmetry wrong would
 * either accuse honest reps or wave through impossible claims.
 */

import { describe, expect, it } from 'vitest';
import {
  boundsOf,
  checkDistance,
  hasFix,
  haversineKm,
  pathKm,
  routeOf,
  waypointsOf,
} from '../geo';
import type { SalesVisit } from '../types';

const visit = (id: string, checkIn: string): SalesVisit => ({
  id,
  person: 'Prasad V',
  date: '2026-08-10',
  checkIn,
  durationMinutes: 0,
});

// The two GPS points actually stored on TRP-00253.
const P1 = { latitude: 10.1097561, longitude: 76.4804176 };
const P2 = { latitude: 10.0676128, longitude: 76.3228226 };

describe('distance measurement', () => {
  it('measures the real gap between TRP-00253’s two samples', () => {
    // ~18 km apart, against a 93 km odometer claim.
    const km = haversineKm(P1, P2);
    expect(km).toBeGreaterThan(17);
    expect(km).toBeLessThan(19);
  });

  it('is zero for a point against itself', () => {
    expect(haversineKm(P1, P1)).toBeCloseTo(0, 6);
  });

  it('sums a path and ignores a single point', () => {
    expect(pathKm([P1])).toBe(0);
    expect(pathKm([])).toBe(0);
    expect(pathKm([P1, P2])).toBeCloseTo(haversineKm(P1, P2), 2);
  });
});

describe('a coordinate has to be real', () => {
  it('rejects the null island, which is the Atlantic', () => {
    expect(hasFix({ latitude: 0, longitude: 0 })).toBe(false);
  });

  it('rejects missing, non-finite and out-of-range values', () => {
    expect(hasFix(undefined)).toBe(false);
    expect(hasFix({ latitude: 10 })).toBe(false);
    expect(hasFix({ latitude: NaN, longitude: 76 })).toBe(false);
    expect(hasFix({ latitude: 91, longitude: 76 })).toBe(false);
  });

  it('accepts a Kerala fix and keeps the extra fields', () => {
    const g = { ...P1, at: '2026-08-10 09:48:07' };
    expect(hasFix(g)).toBe(true);
    if (hasFix(g)) expect(g.at).toBe('2026-08-10 09:48:07');
  });
});

describe('waypoints are ordered by time, not by arrival order', () => {
  it('sorts stops by check-in', () => {
    const w = waypointsOf({
      start: { ...P1, at: '2026-08-10 09:48' },
      end: { latitude: 10.107, longitude: 76.488 },
      visits: [
        { visit: visit('late', '2026-08-10 13:20:52'), place: P2, name: 'Goodwill Roadways' },
        { visit: visit('early', '2026-08-10 12:52:38'), place: P1, name: 'Alliance Express' },
      ],
    });
    expect(w.map((x) => x.label)).toEqual([
      'Punched in',
      'Alliance Express',
      'Goodwill Roadways',
      'Punched out',
    ]);
  });

  it('drops stops whose party has no coordinates', () => {
    const w = waypointsOf({
      visits: [
        { visit: visit('a', '10:00'), place: P1, name: 'Has coords' },
        { visit: visit('b', '11:00'), place: undefined, name: 'No coords' },
      ],
    });
    expect(w.map((x) => x.label)).toEqual(['Has coords']);
  });

  it('plots GPS samples but keeps them OUT of the route line', () => {
    const w = waypointsOf({
      start: P1,
      visits: [{ visit: visit('a', '12:00'), place: P2, name: 'A shop' }],
      gpsPoints: [{ latitude: 10.09, longitude: 76.4, at: '11:00' }],
    });
    expect(w.some((x) => x.kind === 'gps')).toBe(true);
    // Two samples hours apart say nothing about the path between them.
    expect(routeOf(w).some((x) => x.kind === 'gps')).toBe(false);
    expect(routeOf(w).map((x) => x.kind)).toEqual(['start', 'visit']);
  });

  it('does not plot the punch-in fix twice when it is also a GPS sample', () => {
    const w = waypointsOf({
      start: P1,
      visits: [],
      gpsPoints: [P1, P2],
    });
    expect(w.filter((x) => x.kind === 'gps')).toHaveLength(1);
  });
});

describe('the verdict is asymmetric, because the evidence is', () => {
  it('calls a claim BELOW the road minimum impossible', () => {
    const c = checkDistance({ claimedKm: 10, straightKm: 18, roadKm: 25, stops: 3 });
    expect(c.verdict).toBe('impossible');
    expect(c.note).toContain('cannot have reached');
  });

  it('calls a claim far above the minimum a question, not a finding', () => {
    const c = checkDistance({ claimedKm: 93, straightKm: 18, roadKm: 25, stops: 3 });
    expect(c.verdict).toBe('far_above');
    // Wording matters: this must not read as an accusation.
    expect(c.note).toContain('can be legitimate');
  });

  it('accepts an ordinary day above the minimum', () => {
    const c = checkDistance({ claimedKm: 40, straightKm: 18, roadKm: 25, stops: 3 });
    expect(c.verdict).toBe('consistent');
  });

  it('says plainly when there is nothing to check against', () => {
    // TRP-00250: 179 km claimed, one GPS point, no usable stops.
    expect(checkDistance({ claimedKm: 179, straightKm: 0, roadKm: undefined, stops: 1 }).verdict)
      .toBe('no_evidence');
    expect(checkDistance({ claimedKm: 179, straightKm: 0, stops: 0 }).verdict).toBe('no_evidence');
  });

  it('does not flag a short trip on rounding alone', () => {
    const c = checkDistance({ claimedKm: 2, straightKm: 3, roadKm: 4, stops: 2 });
    expect(c.verdict).not.toBe('impossible');
  });

  it('falls back to straight-line when routing failed', () => {
    const c = checkDistance({ claimedKm: 5, straightKm: 18, stops: 3 });
    expect(c.verdict).toBe('impossible'); // 5 km cannot cover an 18 km straight line
    expect(c.roadKm).toBeUndefined();
  });

  it('handles a trip with no odometer claim', () => {
    expect(checkDistance({ claimedKm: 0, straightKm: 18, roadKm: 25, stops: 3 }).verdict)
      .toBe('unknown');
  });
});

describe('map bounds', () => {
  it('fits every point', () => {
    const b = boundsOf([P1, P2])!;
    expect(b[0][0]).toBeCloseTo(10.0676128, 5);
    expect(b[1][1]).toBeCloseTo(76.4804176, 5);
  });

  it('is null with nothing to show', () => {
    expect(boundsOf([])).toBeNull();
  });
});
