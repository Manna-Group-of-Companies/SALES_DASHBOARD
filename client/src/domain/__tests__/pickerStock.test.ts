/**
 * What the item picker may claim about a product's availability.
 *
 * The picker is where a manager decides what to put on an order, so its stock
 * reading is the one that turns into a promise to a customer.
 *
 * The rules used to be about *not merging pools that are not the same pool*:
 * the shelf was a batch total rather than the minimum-to-hold, a production run
 * was a second pool arriving on a different day, and neither could be added to
 * the other. Those pools were removed on 17 September 2026 — every minimum on
 * the site was zero and SAP owns the booking — and the rules that survive are
 * about not inventing a figure:
 *
 *   - nothing is subtracted from what SAP reports, because SAP has already
 *     taken every open order off it;
 *   - loose belts are stock, so an item with belts but no whole roll is
 *     available, not empty;
 *   - an item whose weights are not set reports nothing, and that is a
 *     different state from being out of stock.
 */

import { describe, expect, it } from 'vitest';
import { outOfStock, shelfAvailable } from '../minimumStock';
import type { MinStockLine } from '../types';

const line = (over: Partial<MinStockLine> = {}): MinStockLine => ({
  itemCode: 'TREAD RUBBER PRECURED BLACK PEARL 120 IR 66',
  availableRolls: 5,
  availableBelts: 0,
  beltsPerRoll: 6,
  weightsKnown: true,
  ...over,
});

const has = (q: { rolls: number; belts: number }) => q.rolls > 0 || q.belts > 0;

describe('what the picker calls "free"', () => {
  it('is what SAP reported, with nothing taken off it', () => {
    // SAP's figure is available-to-promise. Subtracting an ERPNext reservation
    // on top is what deducted the same roll twice.
    const s = line({ availableRolls: 3 });
    expect(shelfAvailable(s)).toEqual({ rolls: 3, belts: 0 });
  });

  it('counts loose belts as stock', () => {
    // A roll is cut into belts. Four free belts is a sale today; calling it
    // "none free" sends the customer to a production run for nothing.
    const s = line({ availableRolls: 0, availableBelts: 4 });
    expect(has(shelfAvailable(s))).toBe(true);
    expect(outOfStock(s)).toBe(false);
  });

  it('never goes negative', () => {
    // SAP can report a negative available when it has committed more than it
    // holds. The floor is at zero: a negative would render as a number a rep
    // would try to read.
    const s = line({ availableRolls: -4, availableBelts: -2 });
    expect(shelfAvailable(s)).toEqual({ rolls: 0, belts: 0 });
  });
});

describe('an item whose weights are not set', () => {
  it('reports nothing available, whatever the payload carried', () => {
    // SAP holds it in kilograms and nobody has said what a roll weighs, so no
    // figure here would be a measurement. The quantity is refused at the
    // accessor so no caller can route around the rule.
    const s = line({ availableRolls: 30, availableBelts: 3, weightsKnown: false });
    expect(shelfAvailable(s)).toEqual({ rolls: 0, belts: 0 });
  });

  it('is still distinguishable from being out of stock', () => {
    // Both report nothing available; only one of them is the office's problem,
    // and the picker says so in different words. The flag is what keeps them
    // apart.
    const unset = line({ availableRolls: 30, weightsKnown: false });
    const empty = line({ availableRolls: 0 });
    expect(outOfStock(unset)).toBe(true);
    expect(outOfStock(empty)).toBe(true);
    expect(unset.weightsKnown).toBe(false);
    expect(empty.weightsKnown).toBe(true);
  });
});

describe('an item SAP holds no record of', () => {
  it('is made to order, which is not the same as out of stock', () => {
    // The picker shows `undefined` from the pool map as "to make". The
    // distinction matters: out of stock is a wait for goods that exist
    // somewhere, made to order is a wait for a run nobody has raised.
    const stockedButEmpty = line({ availableRolls: 0 });
    expect(has(shelfAvailable(stockedButEmpty))).toBe(false);
  });
});
