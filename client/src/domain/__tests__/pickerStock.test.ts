/**
 * What the item picker may claim about a product's availability.
 *
 * The picker is where a manager decides what to put on an order, so its stock
 * reading is the one that turns into a promise to a customer. The rules that
 * matter are all about *not merging pools that are not the same pool*:
 *
 *   - the shelf is what a batch holds, never the minimum-to-hold figure;
 *   - a production run is a different pool with its own counter and arrives on
 *     a different day, so it never adds to "free now";
 *   - loose belts are stock, so an item with belts but no whole roll is
 *     available, not empty.
 *
 * These are asserted against `shelfAvailable`/`runAvailable` directly, which is
 * what the picker calls.
 */

import { describe, expect, it } from 'vitest';
import { runAvailable, shelfAvailable } from '../minimumStock';
import type { MinStockLine } from '../types';

const line = (over: Partial<MinStockLine> = {}): MinStockLine => ({
  itemCode: 'TREAD RUBBER PRECURED BLACK PEARL 120 IR 66',
  minimumRolls: 8,
  minimumBelts: 0,
  shelfRolls: 5,
  shelfBelts: 0,
  reservedRolls: 0,
  reservedBelts: 0,
  inProductionRolls: 0,
  inProductionBelts: 0,
  reservedInProductionRolls: 0,
  reservedInProductionBelts: 0,
  ...over,
});

const has = (q: { rolls: number; belts: number }) => q.rolls > 0 || q.belts > 0;

describe('what the picker calls "free"', () => {
  it('is the shelf less what is booked — never the minimum', () => {
    // Live shape: minimum 8, shelf 5. Reading the minimum as stock would offer
    // three rolls that do not exist.
    const s = line({ minimumRolls: 8, shelfRolls: 5, reservedRolls: 2 });
    expect(shelfAvailable(s)).toEqual({ rolls: 3, belts: 0 });
  });

  it('counts loose belts as stock', () => {
    // A roll is cut into belts. Four free belts is a sale today; calling it
    // "none free" sends the customer to a production run for nothing.
    const s = line({ shelfRolls: 0, shelfBelts: 4 });
    expect(has(shelfAvailable(s))).toBe(true);
  });

  it('never goes negative when the stored counter has drifted', () => {
    // The counters drift — there are no Server Scripts to keep them honest.
    const s = line({ shelfRolls: 2, reservedRolls: 9 });
    expect(shelfAvailable(s)).toEqual({ rolls: 0, belts: 0 });
  });
});

describe('a production run is not shelf stock', () => {
  it('does not make an empty shelf look available', () => {
    const s = line({ shelfRolls: 0, reservedRolls: 0, inProductionRolls: 20 });
    expect(has(shelfAvailable(s))).toBe(false);
    expect(has(runAvailable(s))).toBe(true);
  });

  it('nets only what reps have already claimed off the run', () => {
    const s = line({ inProductionRolls: 20, reservedInProductionRolls: 20 });
    expect(has(runAvailable(s))).toBe(false);
  });

  it('keeps the two pools on separate counters', () => {
    // Booking the whole shelf must not touch the run, and vice versa.
    const s = line({
      shelfRolls: 5,
      reservedRolls: 5,
      inProductionRolls: 10,
      reservedInProductionRolls: 0,
    });
    expect(shelfAvailable(s)).toEqual({ rolls: 0, belts: 0 });
    expect(runAvailable(s)).toEqual({ rolls: 10, belts: 0 });
  });
});

describe('an item outside the pool', () => {
  it('is made to order, which is not the same as out of stock', () => {
    // The picker shows `undefined` from the pool map as "to make". The
    // distinction matters: out of stock is a wait for a run that exists,
    // made to order is a wait for one that has not been raised.
    const pooledButEmpty = line({ shelfRolls: 0 });
    expect(has(shelfAvailable(pooledButEmpty))).toBe(false);
    expect(has(runAvailable(pooledButEmpty))).toBe(false);
  });
});
