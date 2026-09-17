/**
 * Parity with the field-sales app, checked against records it actually wrote.
 *
 * The mobile source is not on this machine, so these assert against the live
 * ERPNext documents instead — which is stronger evidence anyway: they are the
 * app's own output, not a description of it.
 *
 * Every fixture here is copied verbatim from the site on 8 Aug 2026.
 */

import { describe, expect, it } from 'vitest';
import { orderLineValues } from '../productRules';
import { servedFrom, splitOf } from '../minimumStock';
import type { OrderLine, Product } from '../types';

// ---------------------------------------------------------------- fixtures ---

/** `TREAD RUBBER PRECURED BLACK PEARL 126 MG 134`, from the Item master. */
const MG134: Product = {
  code: 'TREAD RUBBER PRECURED BLACK PEARL 126 MG 134',
  name: 'TREAD RUBBER PRECURED BLACK PEARL 126 MG 134',
  category: 'PCTR',
  weightPerBelt: 4.2,
  beltsPerRoll: 6,
  weightPerRoll: 25.2,
  active: true,
};

/** `TREAD RUBBER PRECURED BLACK PEARL 102 AJAX 60`. */
const AJAX60: Product = {
  code: 'TREAD RUBBER PRECURED BLACK PEARL 102 AJAX 60',
  name: 'TREAD RUBBER PRECURED BLACK PEARL 102 AJAX 60',
  category: 'PCTR',
  weightPerBelt: 2.4,
  beltsPerRoll: 14,
  weightPerRoll: 33.6,
  active: true,
};

/** The line the app wrote on SAL-ORD-2026-00106. */
const LIVE_00106 = {
  item_code: MG134.code,
  custom_rolls: 8,
  custom_loose_belts: 2,
  custom_total_weight: 210,
  custom_rate_per_kg: 25,
  qty: 8.333,
  rate: 630,
  amount: 5249.79,
  custom_packing_note: '8 rolls + 2 loose belts · 210.00 kg (avg)',
  custom_fulfilment_mode: '',
  custom_production_stage: 'Not Started',
};

/** The line the app wrote on SAL-ORD-2026-00104. */
const LIVE_00104 = {
  custom_rolls: 9,
  custom_loose_belts: 0,
  custom_total_weight: 302.4,
  custom_rate_per_kg: 32,
  qty: 9,
  rate: 1075.2,
  amount: 9676.8,
  custom_packing_note: '9 rolls · 302.40 kg (avg)',
};

describe('an edited line is byte-identical to one the app wrote', () => {
  it('reproduces SAL-ORD-2026-00106 exactly, amount and note included', () => {
    const v = orderLineValues(MG134, {
      rolls: LIVE_00106.custom_rolls,
      looseBelts: LIVE_00106.custom_loose_belts,
      ratePerKg: LIVE_00106.custom_rate_per_kg,
    });
    expect(v.totalWeight).toBe(LIVE_00106.custom_total_weight);
    expect(v.qty).toBe(LIVE_00106.qty);
    expect(v.rate).toBe(LIVE_00106.rate);
    // 8.333 x 630 = 5249.79. The weight form gives 5250.00, and ERPNext would
    // overwrite it on save — the manager's preview would disagree with the
    // stored order by 21 paise and shift rounding_adjustment with it.
    expect(v.amount).toBe(LIVE_00106.amount);
    expect(v.packingNote).toBe(LIVE_00106.custom_packing_note);
  });

  it('reproduces SAL-ORD-2026-00104 exactly', () => {
    const v = orderLineValues(AJAX60, {
      rolls: LIVE_00104.custom_rolls,
      looseBelts: LIVE_00104.custom_loose_belts,
      ratePerKg: LIVE_00104.custom_rate_per_kg,
    });
    expect(v.totalWeight).toBe(LIVE_00104.custom_total_weight);
    expect(v.qty).toBe(LIVE_00104.qty);
    expect(v.rate).toBe(LIVE_00104.rate);
    expect(v.amount).toBe(LIVE_00104.amount);
    expect(v.packingNote).toBe(LIVE_00104.custom_packing_note);
  });

  it('says "loose belts", as the app does', () => {
    const v = orderLineValues(MG134, { rolls: 1, looseBelts: 1, ratePerKg: 25 });
    expect(v.packingNote).toContain('1 loose belt');
    expect(v.packingNote).not.toMatch(/\d belts? ·/);
  });

  it('keeps amount consistent with what ERPNext will recompute', () => {
    // ERPNext recalculates amount = qty x rate server-side, so anything else
    // is overwritten. Assert we already agree with it.
    for (const [rolls, belts] of [[8, 2], [3, 5], [1, 1], [12, 0], [7, 4]]) {
      const v = orderLineValues(MG134, { rolls, looseBelts: belts, ratePerKg: 25 });
      expect(v.amount).toBeCloseTo(Math.round(v.qty * v.rate * 100) / 100, 2);
    }
  });
});
describe('what a line is reported as being served from', () => {
  /*
   * This block was called "the app does not write custom_fulfilment_mode", and
   * that was its point: on SAL-ORD-2026-00106 the field was empty while
   * MSR-00027 held 4 rolls and 2 belts against the line, so trusting the field
   * reported a stocked line as "Made to order" and told the floor to build
   * goods that were already on the shelf. `servedFrom` therefore read the
   * reservation rows first and the field only as a fallback.
   *
   * There are no reservation rows since 17 September 2026, so the field is the
   * only record there is and the fallback is the whole rule. What this now
   * pins is the other half of that decision: an unlabelled line reads as made
   * to order rather than as "undecided", because nobody owes a decision.
   */
  const line: OrderLine = {
    id: 'ajan2f4vlh',
    itemCode: MG134.code,
    itemName: MG134.name,
    qty: 8.333,
    rate: 630,
    amount: 5249.79,
    ratePerKg: 25,
    totalWeight: 210,
    rolls: 8,
    looseBelts: 2,
    rateApproved: true,
    discountPercent: 0,
    priceListRate: 630,
    amountBeforeDiscount: 5249.79,
    amountAfterDiscount: 5249.79,
    fulfilmentMode: LIVE_00106.custom_fulfilment_mode, // ''
    productionStage: 'Not Started',
  };

  it('reads an unlabelled line as made to order, not undecided', () => {
    expect(line.fulfilmentMode).toBe('');
    expect(servedFrom(line)).toBe('new_production');
  });

  it('reads the label the manager set', () => {
    expect(servedFrom({ ...line, fulfilmentMode: 'From Minimum Stock' })).toBe('minimum_stock');
    expect(servedFrom({ ...line, fulfilmentMode: 'New Production' })).toBe('new_production');
  });

  it('splits SAL-ORD-2026-00106 against what SAP has', () => {
    /*
     * The same 8 rolls + 2 belts. It used to split by what MSR-00027 held —
     * 4 + 2 stocked, 4 to make. The split is measured against SAP's available
     * figure now, so six free rolls cover six of the eight and the belts are
     * cut from a seventh.
     */
    const s = splitOf(line, { rolls: 6, belts: 0 }, MG134.beltsPerRoll);
    expect(s.ordered).toEqual({ rolls: 8, belts: 2 });
    expect(s.fromStock).toEqual({ rolls: 6, belts: 0 });
    expect(s.toMake).toEqual({ rolls: 2, belts: 2 });
    expect(s.isSplit).toBe(true);
  });

  it('calls a line the shelf covers entirely no split at all', () => {
    const s = splitOf(line, { rolls: 20, belts: 10 }, MG134.beltsPerRoll);
    expect(s.toMake).toEqual({ rolls: 0, belts: 0 });
    expect(s.isSplit).toBe(false);
    expect(s.allMadeToOrder).toBe(false);
  });
});

/*
 * A "drift across the whole live pool" block stood here.
 *
 * It replayed every `Manna Stock Reservation` row on the site against every
 * pool with a non-zero reserved counter, and asserted that `findDrift` caught
 * exactly the two counters left orphaned when Sales Orders were deleted in the
 * Desk — AJAX69 claiming 3 rolls and 2 belts booked with nothing behind them,
 * and RTS99 claiming one. That was real: the counters were a hand-maintained
 * cache with no Server Script keeping them honest.
 *
 * Both the counter and the rows are gone. SAP reports one figure and nothing
 * in ERPNext caches it, so there is no second copy to drift from.
 */
