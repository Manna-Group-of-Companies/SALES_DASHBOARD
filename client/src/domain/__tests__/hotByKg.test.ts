// HOT rubber with no roll weight is ordered in kilos (14 Nov 2026). 503 of the
// 507 HOT items on live had no roll weight, and every one was refused as an
// incomplete master. The phone's twin is app/test/hot_by_kg_test.dart.

import { describe, expect, it } from 'vitest';
import { computeLine, isMisconfigured, orderLineValues, soldByKg, validateLine } from '../productRules';
import type { Product } from '../types';

const hot: Product = { code: 'HMD001110', name: 'HOT MANNA DOUBLE BLUE 34 14', category: 'CTR', active: true };
const hotWithRoll: Product = { ...hot, code: 'CTR-1', weightPerRoll: 30.5 };

describe('HOT by the kilo', () => {
  it('a HOT item with no roll weight is sold by the kilo, not refused', () => {
    expect(soldByKg(hot)).toBe(true);
    expect(isMisconfigured(hot)).toBeNull();
  });

  it('kilos x rate per kg is the amount, and the kilos are the weight SAP takes', () => {
    expect(computeLine(hot, { kg: 125.5, rate: 210 })).toMatchObject({ quantity: 125.5, amount: 26355 });
    expect(orderLineValues(hot, { kg: 125.5, ratePerKg: 210 })).toEqual({
      qty: 125.5,
      rate: 210,
      amount: 26355,
      totalWeight: 125.5,
      packingNote: '125.5 kg',
    });
  });

  it('asks for the kilos, not rolls', () => {
    expect(validateLine(hot, { kg: 0, rate: 210 })).toEqual([{ field: 'kg', message: 'Enter the kilos.' }]);
    expect(validateLine(hot, { kg: 40, rate: 210 })).toEqual([]);
  });

  it('a HOT item that has a roll weight is still counted in rolls', () => {
    expect(soldByKg(hotWithRoll)).toBe(false);
    expect(computeLine(hotWithRoll, { rolls: 2, rate: 200 }).quantity).toBe(61);
  });
});
