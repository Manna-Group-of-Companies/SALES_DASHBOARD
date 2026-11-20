/**
 * Solution on an order line: counted and priced by the can, held in SAP in
 * litres (20 Nov 2026). SAL-ORD-2026-00162 carried 6 × 30 L of Manna 30 at
 * 5,130 a can — 180 L, 30,780 — and the phone had saved its litres as 0, so
 * the order sync refused the whole order.
 */
import { describe, expect, it } from 'vitest';
import { isSolutionCategory, lineAmountAt, unitRateFor, weightUnit } from '../solutionLine';
import { orderLineValues } from '../productRules';
import type { Product } from '../types';

describe('isSolutionCategory', () => {
  it("reads both the phone's label and the code", () => {
    expect(isSolutionCategory('Vulcanizing Solution')).toBe(true);
    expect(isSolutionCategory('VS')).toBe(true);
    expect(isSolutionCategory('Vulcanising Solution')).toBe(true);
  });
  it('is nothing else', () => {
    for (const c of ['PCTR', 'CTR', 'Bonding Gum', 'BG', '', undefined, null]) {
      expect(isSolutionCategory(c)).toBe(false);
    }
  });
  it('a solution weight reads in litres, everything else in kg', () => {
    expect(weightUnit('Vulcanizing Solution')).toBe('L');
    expect(weightUnit('PCTR')).toBe('kg');
  });
});

describe('unitRateFor — the rate an approval writes', () => {
  it('solution keeps its rate per can, whatever its litres', () => {
    // The tread formula would give 5130 x 180 / 6 = 153,900 a can.
    expect(unitRateFor({ category: 'Vulcanizing Solution', qty: 6, weight: 180, ratePerKg: 5130, fallback: 5130 })).toBe(5130);
  });
  it('tread rubber is still its rate per kg spread over the rolls', () => {
    // 2 rolls, 40.8 kg at 334/kg -> 6,813.60 a roll, as on SAL-ORD-2026-00162.
    expect(unitRateFor({ category: 'PCTR', qty: 2, weight: 40.8, ratePerKg: 334, fallback: 0 })).toBeCloseTo(6813.6, 6);
  });
  it('a line with no weight or no per-kg rate falls back to the rate as stored', () => {
    expect(unitRateFor({ category: 'PCTR', qty: 2, weight: 0, ratePerKg: 334, fallback: 6000 })).toBe(6000);
    expect(unitRateFor({ category: 'VS', qty: 3, weight: 90, ratePerKg: 0, fallback: 195 })).toBe(195);
  });
});

describe('lineAmountAt — the GM and manager previews', () => {
  it('solution: cans x the rate, not litres x the rate', () => {
    expect(lineAmountAt({ category: 'Vulcanizing Solution', qty: 6, totalWeight: 180 }, 5200)).toBe(31200);
  });
  it('tread rubber: kilos x the rate', () => {
    expect(lineAmountAt({ category: 'CTR', qty: 600, totalWeight: 600 }, 313)).toBe(187800);
  });
});

describe('the dashboard and the phone save a solution line alike', () => {
  it('cans as qty, the rate per can, the litres as the weight', () => {
    const product = { code: 'SM030001', name: 'VULCANIZING SOLUTION MANNA 30', category: 'VS', tinSize: 30 } as unknown as Product;
    const v = orderLineValues(product, { tins: 6, ratePerKg: 5130 } as never);
    expect(v.qty).toBe(6);
    expect(v.rate).toBe(5130);
    expect(v.amount).toBe(30780);
    expect(v.totalWeight).toBe(180);
  });
});
