/**
 * What each proforma line puts in each column.
 *
 * Checked against `shared/fixtures/proforma_columns.json`, the same file
 * `app/test/proforma_columns_test.dart` reads. The phone renders a PDF and the
 * dashboard renders HTML, but to a customer they are one document — so a
 * column that differs between them is a customer being sent two versions of
 * the same quote.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/proforma_columns.json';
import { proformaCells, reconcilesOn } from '../proforma';

describe('shared fixture: the columns', () => {
  it('is the set the fixture names, with the old ones gone', () => {
    expect(cases.columns).toEqual(['#', 'Description', 'Rolls', 'Belts', 'Cans', 'Qty', 'MRP', 'Amount']);
    // Named so the removal is a decision on the record, not an omission.
    expect(Object.keys(cases.removed).sort()).toEqual(['gst', 'hsn', 'item_code', 'per']);
  });
});

describe('shared fixture: each line', () => {
  for (const c of cases.lines) {
    it(c.why, () => {
      const got = proformaCells(c.line);
      const e = c.expect as Record<string, unknown>;
      if (e.rolls !== undefined) expect(got.rolls).toBe(e.rolls);
      if (e.belts !== undefined) expect(got.belts).toBe(e.belts);
      if (e.cans !== undefined) expect(got.cans).toBe(e.cans);
      if (e.qty !== undefined) expect(got.qty).toBe(e.qty);
      if (e.mrp !== undefined) expect(got.mrp).toBeCloseTo(e.mrp as number, 2);
      if (e.mrp_unit !== undefined) expect(got.mrpUnit).toBe(e.mrp_unit);
      if (e.amount !== undefined) expect(got.amount).toBeCloseTo(e.amount as number, 2);
      if (e.reconciles_on !== undefined) expect(reconcilesOn(c.line)).toBe(e.reconciles_on);
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('every row multiplies out against something the customer can see', () => {
  it('reconciles on the column its category is billed by', () => {
    for (const c of cases.lines) {
      const cells = proformaCells(c.line);
      const on = reconcilesOn(c.line);
      if (cells.amount === 0) continue;

      const shown =
        on === 'cans'
          ? Number(cells.cans)
          : Number.parseFloat(cells.qty); // "56.4 kg" -> 56.4
      expect(shown * cells.mrp, `${c.why} — ${shown} x ${cells.mrp}`).toBeCloseTo(
        cells.amount,
        1,
      );
    }
  });
});

describe('a packing column never prints a zero', () => {
  it('leaves the cell empty instead', () => {
    // Empty reads as "not applicable"; 0 reads as "none supplied". Hot rubber
    // is not cut into belts at all — that is not the same as a roll that
    // yielded none.
    const ctr = proformaCells({
      custom_product_category: 'CTR',
      custom_rolls: 1,
      custom_loose_belts: 0,
    });
    expect(ctr.belts).toBe('');
    expect(ctr.cans).toBe('');

    const bg = proformaCells({ custom_product_category: 'BG', custom_rolls: 0 });
    expect(bg.rolls).toBe('');
  });
});

describe('the solution row that used not to add up', () => {
  it('bills by the can, not by the litre', () => {
    /*
     * The PDF printed qty 90 against a rate of 195 with an amount of 585 —
     * three numbers that do not reconcile — because it assumed
     * `custom_rate_per_kg` was per kilogram on every line. On solution it is
     * per can.
     */
    const vs = proformaCells({
      custom_product_category: 'VS',
      custom_total_weight: 90,
      custom_rate_per_kg: 195,
      qty: 3,
      rate: 195,
      amount: 585,
    });
    expect(vs.cans).toBe('3');
    expect(vs.qty).toBe('90 L');
    expect(vs.mrpUnit).toBe('per can');
    expect(Number(vs.cans) * vs.mrp).toBeCloseTo(vs.amount, 2);
  });
});

describe('rubbish in a field does not become NaN on a customer document', () => {
  it('reads as nothing instead', () => {
    const cells = proformaCells({
      custom_product_category: 'PCTR',
      custom_rolls: 'x',
      custom_total_weight: null,
      qty: undefined,
      rate: 'abc',
      amount: 0,
    });
    expect(cells.rolls).toBe('');
    expect(Number.isNaN(cells.mrp)).toBe(false);
    expect(cells.amount).toBe(0);
  });
});
