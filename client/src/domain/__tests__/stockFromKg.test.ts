/**
 * Kilos to rolls and belts.
 *
 * `shared/fixtures/stock_from_kg.json` states the rule; this asserts the
 * dashboard obeys it and `app/test/stock_from_kg_test.dart` asserts the phone
 * does. Both read the same cases, because the same shelf must not read
 * differently on a phone and on a dashboard.
 *
 * The cases that matter most are the ones with no weights. Frappe has no null
 * for an Int or a Float, so an item nobody has weighed is indistinguishable
 * from one weighing nothing — and 288 items are about to receive real SAP
 * stock in exactly that state.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/stock_from_kg.json';
import { stockFromKg, weightPerBelt } from '../stockFromKg';

describe('kilos to rolls and belts', () => {
  for (const c of cases.cases) {
    it(c.why, () => {
      const got = stockFromKg({
        kg: c.kg,
        weightPerRoll: c.weight_per_roll,
        beltsPerRoll: c.belts_per_roll,
      });
      expect(got.known).toBe(c.expect.known);
      if (got.known && c.expect.known) {
        expect(got.rolls).toBeCloseTo(c.expect.rolls as number, 3);
        expect(got.belts).toBeCloseTo(c.expect.belts as number, 3);
        expect(got.weightPerBelt).toBeCloseTo(c.expect.weight_per_belt as number, 3);
      }
    });
  }
});

describe('the mistakes this rule exists to prevent', () => {
  it('never yields Infinity, whatever the zero', () => {
    // kg / 0 is Infinity in JavaScript, and Infinity on an order screen is an
    // order for an unbounded quantity.
    for (const [w, b] of [
      [0, 6],
      [38.4, 0],
      [0, 0],
    ]) {
      const got = stockFromKg({ kg: 500, weightPerRoll: w, beltsPerRoll: b });
      expect(got.known).toBe(false);
      expect(JSON.stringify(got)).not.toContain('null');
      expect(Object.values(got).some((v) => v === Infinity)).toBe(false);
    }
  });

  it('an unweighed item is never reported as zero rolls', () => {
    // Zero reads as "out of stock". The truth is "we cannot convert this".
    const got = stockFromKg({ kg: 512.5, weightPerRoll: 0, beltsPerRoll: 0 });
    expect(got.known).toBe(false);
    expect(got).not.toHaveProperty('rolls');
    if (!got.known) expect(got.kg).toBe(512.5);
  });

  it('an empty shelf with good weights is a KNOWN zero', () => {
    // The distinction the whole file turns on: nothing on the shelf is an
    // answer; no weights is the absence of one.
    const got = stockFromKg({ kg: 0, weightPerRoll: 38.4, beltsPerRoll: 6 });
    expect(got.known).toBe(true);
    if (got.known) expect(got.rolls).toBe(0);
  });

  it('Nos and Litre items are not asked the question at all', () => {
    const got = stockFromKg({ kg: 40, weightPerRoll: 38.4, beltsPerRoll: 6, isWeighed: false });
    expect(got.known).toBe(false);
    if (!got.known) expect(got.reason).toBe('not_weighed');
  });

  it('belts come from the unrounded roll count', () => {
    // Rounding rolls first multiplies the error by belts-per-roll, up to 20x.
    const got = stockFromKg({ kg: 149.2, weightPerRoll: 38.4, beltsPerRoll: 6 });
    if (got.known) {
      expect(got.belts).toBeCloseTo(23.313, 3);
      expect(got.belts).not.toBe(Math.round(got.rolls) * 6);
    }
  });
});

describe('weight per belt, when the master left it at zero', () => {
  it('derives it from the roll, exactly, for the real imported values', () => {
    expect(weightPerBelt({ weightPerRoll: 38.4, beltsPerRoll: 6 })).toBe(6.4);
    expect(weightPerBelt({ weightPerRoll: 35.0, beltsPerRoll: 14 })).toBe(2.5);
    expect(weightPerBelt({ weightPerRoll: 34.0, beltsPerRoll: 20 })).toBe(1.7);
  });

  it('a stored value wins over the derivation', () => {
    // Somebody typed it. This only fills a hole, it does not overrule a human.
    expect(
      weightPerBelt({ storedWeightPerBelt: 6.5, weightPerRoll: 38.4, beltsPerRoll: 6 }),
    ).toBe(6.5);
  });

  it('is null rather than zero when it cannot be derived', () => {
    expect(weightPerBelt({ weightPerRoll: 0, beltsPerRoll: 6 })).toBeNull();
    expect(weightPerBelt({ weightPerRoll: 38.4, beltsPerRoll: 0 })).toBeNull();
  });
});
