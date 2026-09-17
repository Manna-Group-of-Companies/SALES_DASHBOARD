/**
 * The stock rules, and what is left of them.
 *
 * WHAT THIS FILE USED TO ASSERT
 *
 * A *pool*: that the minimum-to-hold and the shelf were different numbers and
 * confusing them offered rolls that did not exist; that "below minimum" and
 * "fully booked" were two independent alarms; that a production run was intent
 * rather than stock and must never be added to the shelf; that the pool's
 * `custom_reserved_qty` was a cache which had already drifted on the live site
 * and the reservation rows were the truth. Every one of those was worth
 * pinning while the pool existed.
 *
 * It was removed on 17 September 2026. All 129 pool rows on the site carried a
 * minimum of zero, so nothing built on the minimum had ever fired; the batches
 * were a hand-typed snapshot beating SAP's live figure; and SAP commits stock
 * against its own sales orders, so an ERPNext reservation on top deducted the
 * same roll twice.
 *
 * What survives is what the dashboard and the phone still have to agree on:
 * what is available, how a line divides between the shelf and the plant, and
 * that a missing weight is never reported as a measurement.
 */

import { describe, expect, it } from 'vitest';
import {
  describeSplit,
  modeLabel,
  modeOf,
  modeValue,
  outOfStock,
  poolByItem,
  positionFor,
  servedFrom,
  shelfAvailable,
  splitOf,
} from '../minimumStock';
import type { MinStockLine, OrderLine } from '../types';

const pool = (over: Partial<MinStockLine> = {}): MinStockLine => ({
  itemCode: 'X',
  availableRolls: 0,
  availableBelts: 0,
  beltsPerRoll: 0,
  weightsKnown: true,
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

describe('what is available', () => {
  it('is what SAP reported, with nothing taken off it', () => {
    // SAP has already deducted every quantity committed to an open order,
    // whoever raised it. A second deduction here books the same roll twice.
    const s = pool({ availableRolls: 6, availableBelts: 2 });
    expect(shelfAvailable(s)).toEqual({ rolls: 6, belts: 2 });
    expect(outOfStock(s)).toBe(false);
  });

  it('never reports a negative, however SAP got there', () => {
    // SAP can commit more than it holds. A negative would render as a figure
    // somebody would try to read.
    expect(shelfAvailable(pool({ availableRolls: -3, availableBelts: -1 }))).toEqual({
      rolls: 0,
      belts: 0,
    });
  });

  it('counts loose belts, so belts alone are not "none left"', () => {
    const s = pool({ availableRolls: 0, availableBelts: 4 });
    expect(outOfStock(s)).toBe(false);
  });
});

describe('an item whose weights are not set', () => {
  /*
   * SAP holds these in kilograms and the item master has no weight-per-roll or
   * belts-per-roll, so how many rolls that is cannot be worked out. On
   * instruction they report nothing available while the weights are loaded for
   * the rest of the catalogue.
   *
   * `shared/fixtures/stock_from_kg.json` states the opposite for the
   * *conversion* — a missing weight makes the answer UNKNOWN, never zero — and
   * both hold at once: the conversion still refuses to guess, and the display
   * decision on top of that refusal is to offer nothing. `weightsKnown` is
   * what keeps the two distinguishable.
   */
  it('reports nothing, whatever quantity the payload carried', () => {
    const s = pool({ availableRolls: 30, availableBelts: 5, weightsKnown: false });
    expect(shelfAvailable(s)).toEqual({ rolls: 0, belts: 0 });
  });

  it('stays distinguishable from an item that is genuinely out', () => {
    const unset = pool({ availableRolls: 30, weightsKnown: false });
    const empty = pool({ availableRolls: 0 });
    expect(outOfStock(unset)).toBe(true);
    expect(outOfStock(empty)).toBe(true);
    expect(unset.weightsKnown).toBe(false);
    expect(empty.weightsKnown).toBe(true);
  });
});

describe('an order may exceed what is on the shelf', () => {
  it('caps what comes off the shelf, never the order', () => {
    const s = splitOf(line(15), { rolls: 10, belts: 0 });
    expect(s.ordered.rolls).toBe(15);
    expect(s.fromStock.rolls).toBe(10);
    expect(s.toMake.rolls).toBe(5);
    expect(s.isSplit).toBe(true);
  });

  it('does not call a wholly-made line a split', () => {
    const s = splitOf(line(15), { rolls: 0, belts: 0 });
    expect(s.toMake.rolls).toBe(15);
    expect(s.isSplit).toBe(false);
    expect(s.allMadeToOrder).toBe(true);
    expect(describeSplit(s)).toBe('This whole line will be made to order');
  });

  it('does not call a wholly-covered line a split either', () => {
    const s = splitOf(line(4), { rolls: 10, belts: 0 });
    expect(s.isSplit).toBe(false);
    expect(s.allMadeToOrder).toBe(false);
    expect(describeSplit(s)).toBe('4 rolls from stock');
  });

  it('opens a roll for a belt rather than sending the belt to production', () => {
    // The reported bug, in its smallest form: five rolls and one belt against
    // 48 whole rolls and nothing loose. The belt comes out of a roll.
    const s = splitOf(line(5, 1), { rolls: 48, belts: 0 }, 6);
    expect(s.fromStock).toEqual({ rolls: 5, belts: 1 });
    expect(s.toMake).toEqual({ rolls: 0, belts: 0 });
  });

  it('refuses to cut an item with no belts-per-roll on its master', () => {
    // Not sold in belts, or the master is incomplete. Either way selling belts
    // that cannot be cut is the worse mistake.
    const s = splitOf(line(0, 1), { rolls: 48, belts: 0 });
    expect(s.fromStock.belts).toBe(0);
    expect(s.toMake.belts).toBe(1);
  });
});

describe('the position shown against one line', () => {
  it('reports an item SAP has no record of as not stocked', () => {
    const pos = positionFor('MISSING', poolByItem([pool({ itemCode: 'X' })]));
    expect(pos.stocked).toBe(false);
    expect(pos.available).toEqual({ rolls: 0, belts: 0 });
  });

  it('carries the weights flag through, so the screen can say why it is zero', () => {
    const pos = positionFor('X', poolByItem([pool({ availableRolls: 9, weightsKnown: false })]));
    expect(pos.stocked).toBe(true);
    expect(pos.weightsKnown).toBe(false);
    expect(pos.available).toEqual({ rolls: 0, belts: 0 });
  });

  it('reports what SAP has for a stocked item', () => {
    const pos = positionFor('X', poolByItem([pool({ availableRolls: 7, availableBelts: 3 })]));
    expect(pos).toEqual({
      stocked: true,
      weightsKnown: true,
      available: { rolls: 7, belts: 3 },
    });
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

  it('resolves an unlabelled line to made-to-order rather than undecided', () => {
    // It used to read the reservation rows first, because the field-sales app
    // booked stock without ever writing the field. The field is the only
    // record now, and an empty one means nobody marked the line.
    expect(servedFrom({ itemCode: 'X', fulfilmentMode: '' })).toBe('new_production');
  });

  it('never writes a value the Select would refuse', () => {
    const allowed = ['', 'From Minimum Stock', 'From Production Run', 'New Production'];
    for (const m of ['minimum_stock', 'production_run', 'new_production', 'undecided'] as const) {
      expect(allowed).toContain(modeValue(m));
    }
  });
});
