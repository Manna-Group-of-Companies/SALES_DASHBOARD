/**
 * Per-line discounts — checked against the **shared** fixture.
 *
 * `shared/fixtures/discount.json` is the same file `app/test/discount_test.dart`
 * reads. Every case in it is a rule both apps implement identically, so
 * changing the rule on either side turns the other side red. That is the whole
 * mechanism: prose did not stop the two implementations disagreeing about the
 * discount cap within a day of each other, and a document is a promise one side
 * makes while a fixture is a test the other side fails.
 *
 * Cases that are *not* in the shared file are below, under their own describe.
 * They are dashboard-side detail — wording, edge cases the phone reaches
 * through its own UI — and they must never contradict a fixture.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/discount.json';
import {
  MAX_DISCOUNT_PERCENT,
  discountFields,
  discountPercentOf,
  discountRefusal,
  discountTotals,
  discountedRate,
  isDiscounted,
  lineAfterDiscount,
  lineBeforeDiscount,
  percentOff,
  rateBeforeDiscount,
  roundMoney,
} from '../discount';
import { orderSignedOff } from '../orderStatus';

describe('shared fixture: applying a discount to a line', () => {
  for (const c of cases.apply) {
    it(c.why, () => {
      const got = discountFields({ item: c.line, percent: c.percent, isLead: false });
      for (const [field, want] of Object.entries(c.expect)) {
        expect(got[field], `${field} — ${c.why}`).toBeCloseTo(want as number, 2);
      }
    });
  }
});

describe('shared fixture: an order totalled both ways', () => {
  for (const c of cases.totals) {
    it(c.why, () => {
      const t = discountTotals(c.lines);
      const e: Record<string, number | boolean | undefined> = c.expect;
      if (e.before != null) expect(t.beforeDiscount).toBeCloseTo(e.before as number, 2);
      if (e.after != null) expect(t.afterDiscount).toBeCloseTo(e.after as number, 2);
      if (e.given != null) expect(t.discount).toBeCloseTo(e.given as number, 2);
      if (e.percent != null) expect(t.discountPercent).toBeCloseTo(e.percent as number, 2);
      if (e.discounted_lines != null) expect(t.discountedLines).toBe(e.discounted_lines);
      if (e.has_discount != null) expect(t.hasDiscount).toBe(e.has_discount);
    });
  }
});

describe('shared fixture: an order that is signed off', () => {
  for (const c of cases.locked) {
    it(c.why, () => {
      const o = c.order as Record<string, unknown>;
      expect(
        orderSignedOff(
          {
            poStatus: o.custom_po_status as string | undefined,
            status: o.status as string | undefined,
            ratesApproved: o.custom_rate_approved === 1,
          },
          c.is_lead,
        ),
      ).toBe(c.expect.signed_off);
    });
  }
});

describe('shared fixture: how much may be taken off', () => {
  it('agrees with the phone about the ceiling', () => {
    expect(MAX_DISCOUNT_PERCENT).toBe(cases.ceiling.max_percent);
  });

  for (const c of cases.ceiling.cases) {
    it(c.why, () => {
      const refusal = discountRefusal(c.percent);
      const e = c.expect as { refused: boolean; message?: string; mentions?: string };
      expect(refusal != null, c.why).toBe(e.refused);
      if (e.message) expect(refusal).toBe(e.message);
      if (e.mentions) expect(refusal).toContain(e.mentions);
    });
  }
});

describe('shared fixture: which spelling each doctype uses', () => {
  for (const c of cases.lead_fields.cases) {
    it(c.why, () => {
      if (c.line) {
        const got = discountFields({ item: c.line, percent: c.percent!, isLead: c.is_lead! });
        for (const [f, want] of Object.entries(c.expect_fields ?? {})) {
          expect(got[f], f).toBeCloseTo(want as number, 2);
        }
        for (const f of c.expect_absent ?? []) expect(got).not.toHaveProperty(f);
      }
      if (c.read) {
        const e = c.expect_read!;
        expect(rateBeforeDiscount(c.read)).toBeCloseTo(e.before_rate, 2);
        expect(discountPercentOf(c.read)).toBeCloseTo(e.percent, 2);
        expect(lineAfterDiscount(c.read) / (c.read.qty as number)).toBeCloseTo(e.after_rate, 2);
      }
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('the refusal is a message, not a silent clamp', () => {
  it('never quietly turns an out-of-range figure into a legal one', () => {
    /*
     * This screen used to clamp 150 to the ceiling on the grounds that it
     * meant "as much as possible". The phone always refused, and the dashboard
     * was brought into line on 13 Aug 2026. Asserted as an absence: there is
     * no longer any function here that takes a percentage and hands back a
     * different one.
     */
    expect(discountRefusal(150)).not.toBeNull();
    expect(discountRefusal(Number.NaN)).toBe('Enter a discount between 0 and 100.');
    // Infinity falls to the "more than 100%" message, matching the Dart's
    // `isNaN` check rather than a stricter `isFinite` one. The wording is what
    // a manager reads, so it is not allowed to differ by device.
    expect(discountRefusal(Number.POSITIVE_INFINITY)).toBe('A discount cannot be more than 100%.');
  });
});

describe('reading a line whichever doctype it came from', () => {
  it('prefers the standard field, then the lead spelling, then the net rate', () => {
    expect(rateBeforeDiscount({ price_list_rate: 500, custom_price_list_rate: 9, rate: 450 })).toBe(500);
    expect(rateBeforeDiscount({ custom_price_list_rate: 500, rate: 450 })).toBe(500);
    // An order raised before discounts existed has neither, and is full price.
    expect(rateBeforeDiscount({ rate: 450 })).toBe(450);
  });

  it('reads the percentage from either spelling', () => {
    expect(discountPercentOf({ discount_percentage: 10 })).toBe(10);
    expect(discountPercentOf({ custom_discount_percentage: 10 })).toBe(10);
    expect(discountPercentOf({})).toBe(0);
  });

  it('copes with the numeric strings Frappe sometimes returns', () => {
    expect(discountPercentOf({ discount_percentage: '12.5' })).toBe(12.5);
    expect(rateBeforeDiscount({ price_list_rate: '500' })).toBe(500);
    expect(lineBeforeDiscount({ qty: '2', price_list_rate: '500' })).toBe(1000);
  });

  it('writes the lead spelling for a lead order and never the standard one', () => {
    const f = discountFields({ item: { qty: 2, rate: 500 }, percent: 10, isLead: true });
    expect(f).toHaveProperty('custom_price_list_rate', 500);
    expect(f).toHaveProperty('custom_discount_percentage', 10);
    expect(f).not.toHaveProperty('price_list_rate');
    // `Lead Order Item` has no discount_amount field; writing one would 417.
    expect(f).not.toHaveProperty('discount_amount');
    expect(f.rate).toBe(450);
    expect(f.amount).toBe(900);
  });
});

describe('a line total', () => {
  it('prefers the stored amount, because that is what gets printed', () => {
    expect(lineAfterDiscount({ qty: 2, rate: 450, amount: 900 })).toBe(900);
  });

  it('falls back to qty x rate rather than showing a nil line', () => {
    // Lead orders written before the app sent `amount` have it as zero, and a
    // manager must never see a nil order against rates a rep entered right.
    expect(lineAfterDiscount({ qty: 2, rate: 450, amount: 0 })).toBe(900);
  });

  it('knows an undiscounted line from a discounted one', () => {
    expect(isDiscounted({ discount_percentage: 0 })).toBe(false);
    expect(isDiscounted({ discount_percentage: 5 })).toBe(true);
  });
});

describe('the inverse', () => {
  it('reads a price RISE as no discount, not as a negative one', () => {
    // "−8% discount" reads as a discount rather than as its opposite.
    expect(percentOff(100, 108)).toBe(0);
    expect(percentOff(100, 100)).toBe(0);
    expect(percentOff(0, 0)).toBe(0);
    expect(percentOff(100, 90)).toBe(10);
  });

  it('round-trips against discountedRate', () => {
    for (const pct of [5, 12.5, 33.33, 50]) {
      const net = discountedRate(1000, pct);
      expect(percentOff(1000, net)).toBeCloseTo(pct, 1);
    }
  });
});

describe('money is held to paise', () => {
  it('rounds at every step so the lines add up to the total beneath them', () => {
    expect(roundMoney(666.666)).toBe(666.67);
    expect(roundMoney(0.005)).toBeCloseTo(0.01, 2);
  });

  it('does not produce a figure from nothing', () => {
    expect(roundMoney(Number.NaN)).toBe(0);
    expect(discountTotals([]).beforeDiscount).toBe(0);
  });
});
