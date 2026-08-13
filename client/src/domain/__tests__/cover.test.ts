/**
 * "To be made" must mean *cannot be met from stock* — nothing weaker.
 *
 * The bug this pins, from the live site on 12 Aug 2026:
 *
 *   TREAD RUBBER PRECURED BLACK PEARL 155 MSR 87
 *     shelf (MSB-00029)                4 rolls
 *     held  (MSR-00031, SAL-ORD-2026-00129, Amjad Pr)   1 roll
 *     the manager raised that line from 1 roll to 2
 *
 * `splitOf` reported `toMake: 1` — correct as "not held" — and the screen
 * printed it as **To be made** while three rolls sat free on the shelf. A
 * production run raised off that reading would have manufactured a roll that
 * was already there, and the manager had no way to see that the roll was one
 * booking away rather than one run away.
 *
 * The cause is that raising a quantity in the dashboard does not extend the
 * reservation the rep's phone took, so the extra rolls are simply unclaimed.
 */

import { describe, expect, it } from 'vitest';
import { coverFor, splitOf } from '../minimumStock';
import type { OrderLine, StockReservationRow } from '../types';

const ITEM = 'TREAD RUBBER PRECURED BLACK PEARL 155 MSR 87';
const ORDER = 'SAL-ORD-2026-00129';

const line = (rolls: number, belts = 0): OrderLine =>
  ({ id: 'x', itemCode: ITEM, rolls, looseBelts: belts }) as OrderLine;

const held = (rolls: number, belts = 0, orderId = ORDER): StockReservationRow[] => [
  {
    id: 'MSR-00031',
    itemCode: ITEM,
    rolls,
    looseBelts: belts,
    salesOrder: orderId,
    status: 'Active',
    source: 'Shelf',
  } as StockReservationRow,
];

describe('the live 155 MSR 87 case', () => {
  const split = splitOf(line(2), held(1), ORDER);
  const cover = coverFor(split, { rolls: 3, belts: 0 }); // shelf 4 − booked 1

  it('still reports one roll as not held', () => {
    expect(split.reserved).toEqual({ rolls: 1, belts: 0 });
    expect(split.toMake).toEqual({ rolls: 1, belts: 0 });
  });

  it('calls that roll free stock, not a production job', () => {
    expect(cover.availableNow).toEqual({ rolls: 1, belts: 0 });
    expect(cover.toMake).toEqual({ rolls: 0, belts: 0 });
    expect(cover.needsProduction).toBe(false);
  });

  it('never offers more than is actually uncovered', () => {
    // Three rolls are free, but this line only needs one of them. Showing 3
    // would read as "three more are yours", and two belong to nobody yet.
    expect(cover.availableNow.rolls).toBeLessThanOrEqual(split.toMake.rolls);
  });
});

describe('when the shelf genuinely cannot cover it', () => {
  it('reports the shortfall as production, not as free stock', () => {
    const split = splitOf(line(10), held(2), ORDER);
    const cover = coverFor(split, { rolls: 3, belts: 0 });
    expect(cover.reserved).toEqual({ rolls: 2, belts: 0 });
    expect(cover.availableNow).toEqual({ rolls: 3, belts: 0 });
    expect(cover.toMake).toEqual({ rolls: 5, belts: 0 });
    expect(cover.needsProduction).toBe(true);
  });

  it('is all production when the shelf is empty', () => {
    const split = splitOf(line(4), [], ORDER);
    const cover = coverFor(split, { rolls: 0, belts: 0 });
    expect(cover.toMake).toEqual({ rolls: 4, belts: 0 });
    expect(cover.needsProduction).toBe(true);
  });
});

describe('the free figure must already be net of other orders', () => {
  it('does not offer a roll another order is holding', () => {
    // `positionFor(...).freeForOthers` is shelf minus EVERY hold, so a second
    // order's booking has already been taken out before it reaches here.
    // Passing the gross shelf instead is the mistake this guards against.
    const split = splitOf(line(5), held(1), ORDER);
    const grossShelf = { rolls: 4, belts: 0 };
    const unbooked = { rolls: 1, belts: 0 }; // 4 on the shelf, 3 held elsewhere
    expect(coverFor(split, grossShelf).toMake.rolls).toBe(0);
    expect(coverFor(split, unbooked).toMake.rolls).toBe(3);
  });
});

describe('belts are covered on their own axis', () => {
  it('does not let free rolls cover a belt shortfall', () => {
    // A roll is not a belt until somebody cuts it. Netting them together
    // would promise belts that do not exist yet.
    const split = splitOf(line(0, 6), [], ORDER);
    const cover = coverFor(split, { rolls: 9, belts: 2 });
    expect(cover.availableNow).toEqual({ rolls: 0, belts: 2 });
    expect(cover.toMake).toEqual({ rolls: 0, belts: 4 });
  });
});

describe('a drifted counter cannot invent stock', () => {
  it('treats a negative free figure as nothing free', () => {
    const split = splitOf(line(3), held(1), ORDER);
    const cover = coverFor(split, { rolls: -5, belts: 0 });
    expect(cover.availableNow).toEqual({ rolls: 0, belts: 0 });
    expect(cover.toMake).toEqual({ rolls: 2, belts: 0 });
  });
});
