/**
 * If it is on the shelf, it comes off the shelf.
 *
 * The rule the sales manager stated, and the one the dashboard was breaking.
 * Live on 12 Aug 2026, `TREAD RUBBER PRECURED BLACK PEARL 155 MSR 87`:
 *
 *     shelf (MSB-00029)                              4 rolls
 *     held  (MSR-00031, SAL-ORD-2026-00129)          1 roll
 *     the manager raised that line from 1 roll to 2
 *
 * Saving rewrote the Sales Order and nothing else, so the hold stayed at one
 * roll while three sat unbooked. The order read as needing a roll manufactured,
 * and any other rep could have taken the stock in the meantime.
 *
 * `holdPlan` is what decides the new hold. Everything it must never do is a
 * way of promising the same roll twice.
 */

import { describe, expect, it } from 'vitest';
import { holdPlan } from '../minimumStock';

const q = (rolls: number, belts = 0) => ({ rolls, belts });

describe('the live 155 MSR 87 case', () => {
  const plan = holdPlan({
    ordered: q(2),
    held: q(1),
    shelf: q(4),
    reservedTotal: q(1), // only this order holds anything
  });

  it('takes the second roll from the shelf', () => {
    expect(plan.target).toEqual(q(2));
    expect(plan.delta).toEqual(q(1));
    expect(plan.changed).toBe(true);
  });

  it('sends nothing to production', () => {
    expect(plan.short).toEqual(q(0));
  });

  it('leaves the counter reading what the rows now hold', () => {
    expect(plan.counter).toEqual(q(2));
  });
});

describe('the shelf is a ceiling', () => {
  it('holds what it can and sends only the rest to production', () => {
    // 15 ordered against a shelf of 10 is an order for 15: ten come off the
    // shelf and five are made. The order is never refused for exceeding it.
    const plan = holdPlan({ ordered: q(15), held: q(0), shelf: q(10), reservedTotal: q(0) });
    expect(plan.target).toEqual(q(10));
    expect(plan.short).toEqual(q(5));
  });

  it('never takes a roll another order is holding', () => {
    // Shelf 4, three held elsewhere, this order holds none. One is available.
    const plan = holdPlan({ ordered: q(4), held: q(0), shelf: q(4), reservedTotal: q(3) });
    expect(plan.target).toEqual(q(1));
    expect(plan.short).toEqual(q(3));
    expect(plan.counter).toEqual(q(4));
  });

  it('holds nothing when the shelf is empty', () => {
    const plan = holdPlan({ ordered: q(6), held: q(0), shelf: q(0), reservedTotal: q(0) });
    expect(plan.target).toEqual(q(0));
    expect(plan.short).toEqual(q(6));
    expect(plan.changed).toBe(false);
  });
});

describe('giving stock back', () => {
  it('releases the difference when the quantity drops', () => {
    const plan = holdPlan({ ordered: q(1), held: q(3), shelf: q(4), reservedTotal: q(3) });
    expect(plan.target).toEqual(q(1));
    expect(plan.delta).toEqual(q(-2));
    expect(plan.counter).toEqual(q(1));
  });

  it('releases the whole hold when the line is taken off the order', () => {
    const plan = holdPlan({ ordered: q(0), held: q(2), shelf: q(4), reservedTotal: q(2) });
    expect(plan.target).toEqual(q(0));
    expect(plan.counter).toEqual(q(0));
    expect(plan.changed).toBe(true);
  });

  it('does not disturb what other orders hold', () => {
    // This order gives back 2 of the 5 held across the site; 3 stay held.
    const plan = holdPlan({ ordered: q(0), held: q(2), shelf: q(9), reservedTotal: q(5) });
    expect(plan.counter).toEqual(q(3));
  });
});

describe('a counter that has drifted', () => {
  it('is repaired by the same write, not nudged', () => {
    /*
     * The phantom-booking case: `120 AJAX 69` claimed rolls booked with no
     * reservation behind them after a Sales Order was deleted in the Desk.
     * The counter is rebuilt from the row sum, so the drift does not survive.
     * Rows say 1 held in total; this order holds it and now wants 3.
     */
    const plan = holdPlan({ ordered: q(3), held: q(1), shelf: q(4), reservedTotal: q(1) });
    expect(plan.counter).toEqual(q(3));
    expect(plan.short).toEqual(q(0));
  });
});

describe('rolls and belts are planned separately', () => {
  it('does not let free rolls cover a belt shortfall', () => {
    const plan = holdPlan({
      ordered: { rolls: 2, belts: 6 },
      held: { rolls: 0, belts: 0 },
      shelf: { rolls: 9, belts: 2 },
      reservedTotal: { rolls: 0, belts: 0 },
    });
    expect(plan.target).toEqual({ rolls: 2, belts: 2 });
    expect(plan.short).toEqual({ rolls: 0, belts: 4 });
  });
});

describe('nothing to do', () => {
  it('reports no change when the hold already matches', () => {
    const plan = holdPlan({ ordered: q(2), held: q(2), shelf: q(4), reservedTotal: q(2) });
    expect(plan.changed).toBe(false);
    expect(plan.delta).toEqual(q(0));
  });

  it('treats a negative quantity as zero rather than a credit', () => {
    const plan = holdPlan({ ordered: q(-3), held: q(1), shelf: q(4), reservedTotal: q(1) });
    expect(plan.target).toEqual(q(0));
    expect(plan.short).toEqual(q(0));
  });
});
