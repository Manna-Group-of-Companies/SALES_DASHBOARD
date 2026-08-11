/**
 * The minimum-stock rules, against the real figures on the live site.
 *
 * These are the rules the mobile app and this dashboard must agree on. Where a
 * case is taken from a real record it says so, because a rule verified against
 * live data is worth more than one verified against an example I invented.
 */

import { describe, expect, it } from 'vitest';
import {
  belowMinimum,
  byUrgency,
  describeSplit,
  findDrift,
  fullyBooked,
  heldBy,
  heldFrom,
  modeLabel,
  modeOf,
  modeValue,
  needsRun,
  positionFor,
  poolByItem,
  runAvailable,
  shelfAvailable,
  shortfall,
  shortfallAfterRun,
  splitOf,
  trueReserved,
  urgency,
} from '../minimumStock';
import type { MinStockLine, OrderLine, StockReservationRow } from '../types';

const pool = (over: Partial<MinStockLine> = {}): MinStockLine => ({
  itemCode: 'X',
  minimumRolls: 0,
  minimumBelts: 0,
  shelfRolls: 0,
  shelfBelts: 0,
  reservedRolls: 0,
  reservedBelts: 0,
  inProductionRolls: 0,
  inProductionBelts: 0,
  reservedInProductionRolls: 0,
  reservedInProductionBelts: 0,
  ...over,
});

const line = (rolls: number, belts = 0, over: Partial<OrderLine> = {}): OrderLine => ({
  id: 'L1',
  itemCode: 'X',
  itemName: 'X',
  qty: rolls,
  rate: 0,
  amount: 0,
  ratePerKg: 0,
  totalWeight: 0,
  rolls,
  looseBelts: belts,
  rateApproved: false,
  ...over,
});

const res = (over: Partial<StockReservationRow> = {}): StockReservationRow => ({
  id: 'R1',
  itemCode: 'X',
  rolls: 0,
  looseBelts: 0,
  salesOrder: 'SO1',
  status: 'Active',
  source: 'Shelf',
  ...over,
});

describe('the shelf and the minimum are different numbers', () => {
  // Live: 120 AJAX 69 is minimum 2 with 4 on batch MSB-00057.
  it('is not below minimum when the shelf exceeds the target', () => {
    const s = pool({ minimumRolls: 2, shelfRolls: 4 });
    expect(belowMinimum(s)).toBe(false);
    expect(shortfall(s)).toBe(0);
  });

  // Live: 160 RTS 99 is minimum 10 with 0 on batch MSB-00030.
  it('is below minimum, and fully booked, when the shelf is empty', () => {
    const s = pool({ minimumRolls: 10, shelfRolls: 0 });
    expect(belowMinimum(s)).toBe(true);
    expect(fullyBooked(s)).toBe(true);
    expect(urgency(s)).toBe(3);
    expect(shortfall(s)).toBe(10);
  });
});

describe('the two alarms fire independently', () => {
  it('fires fully-booked at exactly the minimum, while the quantity still looks right', () => {
    const s = pool({ minimumRolls: 10, shelfRolls: 10, reservedRolls: 10 });
    expect(belowMinimum(s)).toBe(false);
    expect(fullyBooked(s)).toBe(true);
    expect(urgency(s)).toBe(2);
  });

  it('fires below-minimum while stock is still sellable', () => {
    const s = pool({ minimumRolls: 10, shelfRolls: 4, reservedRolls: 0 });
    expect(belowMinimum(s)).toBe(true);
    expect(fullyBooked(s)).toBe(false);
    expect(urgency(s)).toBe(1);
    expect(shelfAvailable(s).rolls).toBe(4);
  });

  it('is healthy when neither fires', () => {
    const s = pool({ minimumRolls: 4, shelfRolls: 10, reservedRolls: 2 });
    expect(needsRun(s)).toBe(false);
    expect(urgency(s)).toBe(0);
  });
});

describe('the shortfall is measured against the shelf, not against what is left to sell', () => {
  it('does not ask for goods that already exist and are going out', () => {
    // 10 on the shelf, 8 booked: only 2 to sell, but all 10 exist.
    const s = pool({ minimumRolls: 10, shelfRolls: 10, reservedRolls: 8 });
    expect(shelfAvailable(s).rolls).toBe(2);
    expect(shortfall(s)).toBe(0); // NOT 8 — that would build them twice
  });
});

describe('a production run is intent, never availability', () => {
  it('never adds the run to the shelf', () => {
    const s = pool({ minimumRolls: 20, shelfRolls: 0, inProductionRolls: 20 });
    expect(shelfAvailable(s).rolls).toBe(0); // an empty shelf sells nothing
    expect(runAvailable(s).rolls).toBe(20);
  });

  it('nets the run off the ASK so a pool is not ordered twice', () => {
    const s = pool({ minimumRolls: 20, shelfRolls: 0, inProductionRolls: 20 });
    expect(shortfall(s)).toBe(20);
    expect(shortfallAfterRun(s)).toBe(0);
  });

  it('still reports the remainder when the run only part-covers it', () => {
    expect(shortfallAfterRun(pool({ minimumRolls: 20, inProductionRolls: 15 }))).toBe(5);
  });

  it('counts claims against the run separately from the shelf', () => {
    const s = pool({ inProductionRolls: 20, reservedInProductionRolls: 8 });
    expect(runAvailable(s).rolls).toBe(12);
    expect(shelfAvailable(s).rolls).toBe(0);
  });
});

describe('an order may exceed the pool', () => {
  it('caps the reservation, not the order', () => {
    const s = splitOf(line(15), [res({ rolls: 10 })], 'SO1');
    expect(s.ordered.rolls).toBe(15);
    expect(s.reserved.rolls).toBe(10);
    expect(s.toMake.rolls).toBe(5);
    expect(s.isSplit).toBe(true);
  });

  it('does not call a wholly-made line a split', () => {
    const s = splitOf(line(15), [], 'SO1');
    expect(s.toMake.rolls).toBe(15);
    expect(s.isSplit).toBe(false);
    expect(s.allMadeToOrder).toBe(true);
    expect(describeSplit(s)).toBe('This whole line will be made to order');
  });

  // The order the addendum names as the bug worth not repeating.
  it('reproduces SAL-ORD-2026-00106: 8+2 ordered, 4+2 from stock, 4 to make', () => {
    const s = splitOf(line(8, 2), [res({ rolls: 4, looseBelts: 2 })], 'SO1');
    expect(s.ordered).toEqual({ rolls: 8, belts: 2 });
    expect(s.reserved).toEqual({ rolls: 4, belts: 2 });
    expect(s.toMake).toEqual({ rolls: 4, belts: 0 });
  });

  it('ignores another order’s reservation when splitting this one', () => {
    const s = splitOf(line(8), [res({ rolls: 4, salesOrder: 'SO-OTHER' })], 'SO1');
    expect(s.reserved.rolls).toBe(0);
    expect(s.toMake.rolls).toBe(8);
  });

  it('ignores Released rows', () => {
    const s = splitOf(line(8), [res({ rolls: 4, status: 'Released' })], 'SO1');
    expect(s.reserved.rolls).toBe(0);
  });
});

describe('the counter is a cache and the reservation rows are the truth', () => {
  // Live on 8 Aug 2026: two pools claimed bookings with no rows behind them.
  it('detects the phantom bookings left by an order deleted in the Desk', () => {
    const pools = [
      pool({ itemCode: 'AJAX', shelfRolls: 4, reservedRolls: 3, reservedBelts: 2 }),
      pool({ itemCode: 'EAGLE', shelfRolls: 5, reservedRolls: 2 }),
      pool({ itemCode: 'RTS', shelfRolls: 0, reservedRolls: 1 }),
    ];
    const rows = [res({ id: 'MSR-00022', itemCode: 'EAGLE', rolls: 2 })];
    const drift = findDrift(pools, rows);
    expect(drift.map((d) => d.itemCode)).toEqual(['AJAX', 'RTS']);
    expect(drift[0].storedRolls).toBe(3);
    expect(drift[0].actualRolls).toBe(0);
  });

  it('frees stock the counter was wrongly blocking', () => {
    const idx = poolByItem([pool({ itemCode: 'AJAX', shelfRolls: 4, reservedRolls: 3 })]);
    const p = positionFor('AJAX', idx, [], 'SO1');
    expect(p.freeForOthers.rolls).toBe(4);
    expect(p.drift).toBe(3);
  });

  it('leaves a genuine booking alone', () => {
    const idx = poolByItem([pool({ itemCode: 'EAGLE', shelfRolls: 5, reservedRolls: 2 })]);
    const rows = [res({ itemCode: 'EAGLE', rolls: 2, salesOrder: 'SO-OTHER' })];
    const p = positionFor('EAGLE', idx, rows, 'SO1');
    expect(p.heldByOthers.rolls).toBe(2);
    expect(p.freeForOthers.rolls).toBe(3);
    expect(p.drift).toBe(0);
  });

  it('FAILSAFE: falls back to the counter when the rows could not be read', () => {
    const idx = poolByItem([pool({ itemCode: 'EAGLE', shelfRolls: 5, reservedRolls: 2 })]);
    // Not loaded: an empty array must not be read as "nothing is reserved".
    expect(positionFor('EAGLE', idx, [], 'SO1', false).freeForOthers.rolls).toBe(3);
    // Trusting it blindly would have freed the whole shelf.
    expect(positionFor('EAGLE', idx, [], 'SO1', true).freeForOthers.rolls).toBe(5);
  });

  it('does not count a production-run claim as a shelf booking', () => {
    const rows = [res({ rolls: 5, source: 'Production Run' }), res({ id: 'R2', rolls: 2 })];
    expect(trueReserved(rows, 'X')).toEqual({ rolls: 2, belts: 0 });
  });
});

describe('which pool a booking came from', () => {
  it('reports the shelf', () => {
    expect(heldFrom([res({ rolls: 2 })], 'X', 'SO1')).toBe('shelf');
  });
  it('reports the run', () => {
    expect(heldFrom([res({ rolls: 2, source: 'Production Run' })], 'X', 'SO1')).toBe('run');
  });
  it('reports none', () => {
    expect(heldFrom([], 'X', 'SO1')).toBe('none');
  });
  it('sums only this order’s Active rows', () => {
    const rows = [
      res({ id: 'a', rolls: 2 }),
      res({ id: 'b', rolls: 3 }),
      res({ id: 'c', rolls: 9, salesOrder: 'SO-OTHER' }),
      res({ id: 'd', rolls: 9, status: 'Released' }),
    ];
    expect(heldBy(rows, 'X', 'SO1')).toEqual({ rolls: 5, belts: 0 });
  });
});

describe('fulfilment mode is reported, not chosen', () => {
  it('round-trips the three stored values', () => {
    expect(modeOf({ fulfilmentMode: 'From Minimum Stock' })).toBe('minimum_stock');
    expect(modeOf({ fulfilmentMode: 'From Production Run' })).toBe('production_run');
    expect(modeOf({ fulfilmentMode: 'New Production' })).toBe('new_production');
    expect(modeValue('production_run')).toBe('From Production Run');
  });

  it('reads an unset mode as made to order, not as an outstanding decision', () => {
    expect(modeOf({ fulfilmentMode: '' })).toBe('undecided');
    expect(modeLabel('undecided')).toBe('Made to order');
  });

  it('never writes a value the Select would refuse', () => {
    const allowed = ['', 'From Minimum Stock', 'From Production Run', 'New Production'];
    for (const m of ['minimum_stock', 'production_run', 'new_production', 'undecided'] as const) {
      expect(allowed).toContain(modeValue(m));
    }
  });
});

describe('urgency ordering', () => {
  it('puts both-alarms first, then fully booked, then below minimum', () => {
    const both = pool({ itemCode: 'both', minimumRolls: 10, shelfRolls: 0 });
    const booked = pool({ itemCode: 'booked', minimumRolls: 5, shelfRolls: 10, reservedRolls: 10 });
    const low = pool({ itemCode: 'low', minimumRolls: 10, shelfRolls: 4 });
    const fine = pool({ itemCode: 'fine', minimumRolls: 2, shelfRolls: 10 });
    const sorted = [fine, low, booked, both].sort(byUrgency).map((s) => s.itemCode);
    expect(sorted).toEqual(['both', 'booked', 'low', 'fine']);
  });

  it('breaks ties on the biggest shortfall', () => {
    const small = pool({ itemCode: 'small', minimumRolls: 6, shelfRolls: 4 });
    const big = pool({ itemCode: 'big', minimumRolls: 20, shelfRolls: 4 });
    expect([small, big].sort(byUrgency).map((s) => s.itemCode)).toEqual(['big', 'small']);
  });
});
