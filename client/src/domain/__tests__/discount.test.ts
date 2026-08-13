/**
 * The manager's per-line discount.
 *
 * Money the customer is quoted, so every rule here is about the figure being
 * reproducible: the same line, the same percentage, the same total, whether it
 * is computed on this screen, on the proforma, or by ERPNext when it rebuilds
 * `amount` from `qty x rate` on save.
 */

import { describe, expect, it } from 'vitest';
import {
  discountEditable,
  discountLine,
  normaliseDiscount,
  orderDiscount,
} from '../discount';

describe('a percentage the site will accept', () => {
  it('clamps rather than refuses', () => {
    // 150 means "as much as I can". Refusing the save teaches nobody anything.
    expect(normaliseDiscount(150)).toBe(100);
    expect(normaliseDiscount(-5)).toBe(0);
  });

  it('allows a full hundred', () => {
    // A free replacement roll is a real thing in this trade, and the only
    // case where a line legitimately reaches zero.
    expect(normaliseDiscount(100)).toBe(100);
    expect(discountLine({ perUnit: 8516.4, qty: 2, percent: 100 }).after).toBe(0);
  });

  it('treats nothing, blank and rubbish as no discount', () => {
    expect(normaliseDiscount(undefined)).toBe(0);
    expect(normaliseDiscount(null)).toBe(0);
    expect(normaliseDiscount(Number.NaN)).toBe(0);
    expect(normaliseDiscount(0)).toBe(0);
  });

  it('keeps two decimals, because 7.5% is a real concession', () => {
    expect(normaliseDiscount(7.5)).toBe(7.5);
    expect(normaliseDiscount(7.456)).toBe(7.46);
  });
});

describe('one line, discounted', () => {
  // The live line: 155 MSR 87, 2 rolls, 56.4 kg, ₹302/kg → ₹8516.40 per roll.
  const LINE = { perUnit: 8516.4, qty: 2 };

  it('leaves an undiscounted line exactly as it was', () => {
    const v = discountLine({ ...LINE, percent: 0 });
    expect(v.before).toBe(17032.8);
    expect(v.after).toBe(17032.8);
    expect(v.saved).toBe(0);
  });

  it('takes the percentage off the RATE, then rebuilds the amount', () => {
    /*
     * Not off the amount. ERPNext stores one qty and one rate and reconciles
     * `amount` against `qty x rate` on every save — discounting the amount
     * alone would be silently reverted by the server.
     */
    const v = discountLine({ ...LINE, percent: 10 });
    expect(v.perUnitBefore).toBe(8516.4);
    expect(v.perUnitAfter).toBe(7664.76);
    expect(v.after).toBeCloseTo(2 * 7664.76, 2);
    expect(v.saved).toBeCloseTo(1703.28, 2);
  });

  it('keeps qty x rate == amount to the paisa', () => {
    for (const pct of [3, 7.5, 12.5, 33.33, 99]) {
      const v = discountLine({ perUnit: 8516.4, qty: 3, percent: pct });
      expect(v.after).toBeCloseTo(Math.round(3 * v.perUnitAfter * 100) / 100, 2);
    }
  });

  it('derives what was taken off from the two rounded rates', () => {
    // Rounding the discount independently would let it disagree with the
    // rates by a paisa, and a proforma that does not add up gets queried.
    const v = discountLine({ perUnit: 100.05, qty: 7, percent: 12.5 });
    expect(v.perUnitOff).toBeCloseTo(v.perUnitBefore - v.perUnitAfter, 2);
    expect(v.saved).toBeCloseTo(v.before - v.after, 2);
  });

  it('cannot invent money from a negative rate or quantity', () => {
    expect(discountLine({ perUnit: -50, qty: 2, percent: 10 }).before).toBe(0);
    expect(discountLine({ perUnit: 50, qty: -2, percent: 10 }).after).toBe(0);
  });
});

describe('the order roll-up', () => {
  it('reports the effective rate, not the average of the lines', () => {
    /*
     * The mistake this guards: 10% off a ₹500 line and nothing off a ₹50,000
     * one is not a 5% order. Averaging the percentages would overstate what
     * was given away by two orders of magnitude.
     */
    const total = orderDiscount([
      { before: 500, after: 450, percent: 10 },
      { before: 50_000, after: 50_000, percent: 0 },
    ]);
    expect(total.saved).toBe(50);
    expect(total.percent).toBe(0.1);
    expect(total.lines).toBe(1);
  });

  it('adds the before and after totals separately', () => {
    const total = orderDiscount([
      { before: 17032.8, after: 15329.52, percent: 10 },
      { before: 13800, after: 13800, percent: 0 },
      { before: 585, after: 526.5, percent: 10 },
    ]);
    expect(total.before).toBe(31417.8);
    expect(total.after).toBe(29656.02);
    expect(total.saved).toBeCloseTo(1761.78, 2);
    expect(total.lines).toBe(2);
  });

  it('is a no-op on an order nobody discounted', () => {
    const total = orderDiscount([{ before: 100, after: 100, percent: 0 }]);
    expect(total).toMatchObject({ saved: 0, percent: 0, lines: 0 });
  });

  it('does not divide by zero on an empty or nil order', () => {
    expect(orderDiscount([]).percent).toBe(0);
    expect(orderDiscount([{ before: 0, after: 0, percent: 50 }]).percent).toBe(0);
  });
});

describe('approval is final', () => {
  it('lets the sales manager set a discount before approval', () => {
    expect(discountEditable('sales_manager', false)).toBe(true);
  });

  it('freezes it once the line is approved', () => {
    // The requirement, stated plainly: after approval the percentage does not
    // move. A discount is a price, and the signed total must stay signed.
    expect(discountEditable('sales_manager', true)).toBe(false);
    expect(discountEditable('sales_rep', true)).toBe(false);
    expect(discountEditable(undefined, true)).toBe(false);
  });

  it('keeps the General Manager override that rates already have', () => {
    // Deliberately the same escape hatch, not a second one. One way to reopen
    // a price, not two.
    expect(discountEditable('general_manager', true)).toBe(true);
  });
});
