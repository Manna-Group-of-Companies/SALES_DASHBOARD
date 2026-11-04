/**
 * How far a rep is towards a monthly target, read from the shared fixture.
 *
 * `shared/fixtures/sales_target_progress.json` is also read by the phone's
 * `app/test/sales_target_test.dart`. What counts as achieved (invoiced lines
 * only) is the server's; this pins what both apps make of its totals.
 */
import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/sales_target_progress.json';
import { achieved, fraction, hasInvoices, hasTarget, toTargetMonth, toTargetRow } from '../salesTarget';

describe('shared/fixtures/sales_target_progress.json', () => {
  for (const c of fixture.cases) {
    it(c.why, () => {
      const r = toTargetRow(c.row as Record<string, unknown>);
      expect(hasTarget(r)).toBe(c.has_target);
      expect(hasInvoices(r)).toBe(c.has_invoices);
      expect(achieved(r)).toBeCloseTo(c.achieved, 9);
      expect(fraction(r)).toBeCloseTo(c.fraction, 9);
    });
  }
});

describe('the Server Script reply', () => {
  it('reads rows, invoiced lines and edit rights', () => {
    const m = toTargetMonth({
      month: 'Nov',
      year: 2026,
      is_gm: 0,
      can_edit: ['Amjad Pr'],
      rows: [
        {
          sales_person: 'Amjad Pr',
          team: 'Pareeth',
          currency: 'INR',
          target_name: 'TGT-00007',
          target_amount: 100000,
          target_unit: 'Currency',
          invoiced_amount: 18000,
          invoiced_kg: 72,
          lines: [
            {
              order: 'SAL-ORD-2026-00156',
              customer_name: 'A Tyres',
              item_name: 'PCTR 10x16',
              invoice: '41234',
              invoice_date: '2026-11-02',
              amount: 18000,
              kg: 72,
            },
          ],
        },
      ],
    });
    expect(m.canEdit).toEqual(['Amjad Pr']);
    const r = m.rows[0];
    expect(r.lines[0].invoice).toBe('41234');
    expect(hasInvoices(r)).toBe(true);
    expect(fraction(r)).toBeCloseTo(0.18, 9);
  });
});
