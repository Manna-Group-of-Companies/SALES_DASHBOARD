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
import { servedFrom, splitOf, findDrift, trueReserved } from '../minimumStock';
import type { MinStockLine, OrderLine, Product, StockReservationRow } from '../types';

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

describe('the app does not write custom_fulfilment_mode', () => {
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

  /** MSR-00027, exactly as stored. */
  const msr27: StockReservationRow = {
    id: 'MSR-00027',
    itemCode: MG134.code,
    rolls: 4,
    looseBelts: 2,
    salesOrder: 'SAL-ORD-2026-00106',
    salesPerson: 'Sirajudheen Kasim',
    status: 'Active',
    source: 'Shelf',
  };

  it('would report a stocked line as "made to order" if the field were trusted', () => {
    // The bug this guards: the field is empty, but 4 rolls + 2 belts ARE held.
    expect(line.fulfilmentMode).toBe('');
    expect(servedFrom(line, [msr27], 'SAL-ORD-2026-00106')).toBe('minimum_stock');
  });

  it('reports made-to-order only when nothing is actually held', () => {
    expect(servedFrom(line, [], 'SAL-ORD-2026-00106')).toBe('new_production');
  });

  it('reports a run claim from the reservation source', () => {
    const claim = { ...msr27, source: 'Production Run' };
    expect(servedFrom(line, [claim], 'SAL-ORD-2026-00106')).toBe('production_run');
  });

  it('falls back to the stored field when the rows could not be read', () => {
    const labelled = { ...line, fulfilmentMode: 'From Minimum Stock' };
    expect(servedFrom(labelled, [], 'SAL-ORD-2026-00106', false)).toBe('minimum_stock');
  });

  it('splits SAL-ORD-2026-00106 as 8+2 ordered, 4+2 stocked, 4 to make', () => {
    const s = splitOf(line, [msr27], 'SAL-ORD-2026-00106');
    expect(s.ordered).toEqual({ rolls: 8, belts: 2 });
    expect(s.reserved).toEqual({ rolls: 4, belts: 2 });
    expect(s.toMake).toEqual({ rolls: 4, belts: 0 });
    expect(s.isSplit).toBe(true);
  });
});

describe('drift across the whole live pool', () => {
  /** Every reservation on the site, verbatim. */
  const reservations: StockReservationRow[] = [
    { id: 'MSR-00021', itemCode: 'EAGLE134', rolls: 0, looseBelts: 0, salesOrder: 'SAL-ORD-2026-00096', status: 'Released', source: 'Shelf' },
    { id: 'MSR-00022', itemCode: 'EAGLE134', rolls: 2, looseBelts: 0, salesOrder: 'SAL-ORD-2026-00096', status: 'Active', source: 'Shelf' },
    { id: 'MSR-00023', itemCode: 'EA60', rolls: 0, looseBelts: 0, salesOrder: 'SAL-ORD-2026-00105', status: 'Released', source: 'Shelf' },
    { id: 'MSR-00024', itemCode: 'IR66', rolls: 0, looseBelts: 0, salesOrder: 'SAL-ORD-2026-00105', status: 'Released', source: 'Shelf' },
    { id: 'MSR-00025', itemCode: 'EA60', rolls: 0, looseBelts: 0, salesOrder: 'SAL-ORD-2026-00105', status: 'Released', source: 'Shelf' },
    { id: 'MSR-00026', itemCode: 'IR66', rolls: 2, looseBelts: 2, salesOrder: 'SAL-ORD-2026-00105', status: 'Active', source: 'Shelf' },
    { id: 'MSR-00027', itemCode: 'MG134', rolls: 4, looseBelts: 2, salesOrder: 'SAL-ORD-2026-00106', status: 'Active', source: 'Shelf' },
  ];

  /** Every pool with a non-zero reserved counter, verbatim. */
  const pools: MinStockLine[] = (
    [
      ['AJAX69', 2, 3, 2],
      ['IR66', 8, 2, 2],
      ['EAGLE134', 5, 2, 0],
      ['MG134', 8, 4, 2],
      ['RTS99', 10, 1, 0],
    ] as const
  ).map(([itemCode, minimumRolls, reservedRolls, reservedBelts]) => ({
    itemCode,
    minimumRolls,
    minimumBelts: 0,
    shelfRolls: 0,
    shelfBelts: 0,
    reservedRolls,
    reservedBelts,
    inProductionRolls: 0,
    inProductionBelts: 0,
    reservedInProductionRolls: 0,
    reservedInProductionBelts: 0,
  }));

  it('finds exactly the two orphaned counters and no false positives', () => {
    const drift = findDrift(pools, reservations);
    expect(drift.map((d) => d.itemCode).sort()).toEqual(['AJAX69', 'RTS99']);
  });

  it('confirms the three genuine bookings reconcile', () => {
    expect(trueReserved(reservations, 'IR66')).toEqual({ rolls: 2, belts: 2 });
    expect(trueReserved(reservations, 'EAGLE134')).toEqual({ rolls: 2, belts: 0 });
    expect(trueReserved(reservations, 'MG134')).toEqual({ rolls: 4, belts: 2 });
  });

  it('reports the phantom quantities the user spotted', () => {
    const ajax = findDrift(pools, reservations).find((d) => d.itemCode === 'AJAX69')!;
    expect([ajax.storedRolls, ajax.storedBelts]).toEqual([3, 2]);
    expect([ajax.actualRolls, ajax.actualBelts]).toEqual([0, 0]);
  });

  it('ignores Released rows, which the app zeroes on release', () => {
    // MSR-00023/24/25 are all Released with qty 0.
    expect(trueReserved(reservations, 'EA60')).toEqual({ rolls: 0, belts: 0 });
  });
});
