/**
 * The FG import of 10 September 2026 left `custom_avg_weight_per_roll` at 0 on
 * all 153 items it gave belt data to, breaking the site's invariant
 * (weight-per-belt x belts-per-roll = weight-per-roll).
 *
 * These assert the app already survives that, using the real imported values.
 * `normaliseWeights` treats 0 as absent and derives the belt weight from the
 * other two, which is exactly the correction the broken master needs.
 */

import { describe, expect, it } from 'vitest';
import { beltWeight, normaliseWeights, rollWeight } from '../productRules';
import type { Product } from '../types';

const asProduct = (w: ReturnType<typeof normaliseWeights>): Product =>
  ({ code: 'X', name: 'X', category: 'PCTR', active: true, ...w }) as Product;

describe('the broken invariant on the 153 imported items', () => {
  // item code, kg/roll, belts/roll, the belt weight that must come out
  const REAL: [string, number, number, number][] = [
    ['I-11672', 38.4, 6, 6.4],
    ['I-11674', 35.0, 14, 2.5],
    ['I-11675', 34.0, 20, 1.7],
  ];

  for (const [code, perRoll, belts, expected] of REAL) {
    it(`${code}: belt weight is derived, not read from the zero field`, () => {
      // Exactly what the live master returns: the belt field is 0, not absent.
      const w = normaliseWeights({
        weightPerBelt: 0,
        beltsPerRoll: belts,
        weightPerRoll: perRoll,
      });
      expect(w.weightPerBelt).toBe(expected);
      expect(w.weightPerRoll).toBe(perRoll);
      expect(beltWeight(asProduct(w))).toBe(expected);
      expect(rollWeight(asProduct(w))).toBe(perRoll);
    });
  }

  it('a zero belts-per-roll still derives nothing, rather than dividing', () => {
    // The 288 items about to receive SAP stock with no belt data.
    const w = normaliseWeights({ weightPerBelt: 0, beltsPerRoll: 0, weightPerRoll: 0 });
    expect(w.weightPerBelt).toBeUndefined();
    expect(w.weightPerRoll).toBeUndefined();
    expect(w.beltsPerRoll).toBeUndefined();
    expect(beltWeight(asProduct(w))).toBe(0);
  });
});
