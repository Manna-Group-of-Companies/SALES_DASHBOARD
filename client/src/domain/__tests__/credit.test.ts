/**
 * The outstanding balance, now that SAP sends it in four age buckets.
 *
 * Checked against `shared/fixtures/credit.json`, the same file
 * `app/test/credit_test.dart` reads. A rule that changes on one side turns the
 * other side red — which is the only thing that has actually stopped these two
 * implementations drifting.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/credit.json';
import {
  AGING_TOLERANCE,
  OUTSTANDING_FIELD,
  agingOf,
  bucketsOf,
  hasOverdue,
  overCreditLimit,
  overdueAmount,
} from '../credit';

describe('shared fixture: the field names', () => {
  it('reads the fields the fixture names, and no others', () => {
    // If somebody renames a field on the site, this is the test that says so
    // before a screen quietly starts showing zero.
    expect(OUTSTANDING_FIELD.total).toBe(cases.fields.total);
    expect(OUTSTANDING_FIELD.creditLimit).toBe(cases.fields.credit_limit);
    expect([
      OUTSTANDING_FIELD.d0_30,
      OUTSTANDING_FIELD.d30_60,
      OUTSTANDING_FIELD.d60_90,
      OUTSTANDING_FIELD.d90plus,
    ]).toEqual(cases.fields.buckets);
  });
});

describe('shared fixture: what the total is', () => {
  for (const c of cases.total) {
    it(c.why, () => {
      const a = agingOf(c.customer);
      const e = c.expect as Record<string, number | boolean | undefined>;
      if (e.total != null) expect(a.total).toBeCloseTo(e.total as number, 2);
      if (e.buckets_known != null) expect(a.bucketsKnown).toBe(e.buckets_known);
      if (e.mismatch != null) expect(a.mismatch).toBe(e.mismatch);
    });
  }
});

describe('shared fixture: old debt', () => {
  for (const c of cases.overdue) {
    it(c.why, () => {
      const e = c.expect as Record<string, number | boolean | undefined>;
      if (e.overdue != null) expect(overdueAmount(c.customer)).toBeCloseTo(e.overdue as number, 2);
      if (e.has_overdue != null) expect(hasOverdue(c.customer)).toBe(e.has_overdue);
      if (e.escalates != null) {
        expect(overCreditLimit(c.customer, c.order_total ?? 0)).toBe(e.escalates);
      }
      if (e.blocks_order != null) {
        // The 90+ box is a warning, never a gate. Asserted separately from
        // `escalates` because they are different claims: one is about this
        // order's total, the other about the rule existing at all.
        expect(overCreditLimit(c.customer, 0)).toBe(e.blocks_order);
      }
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('the credit limit stays one figure', () => {
  it('is read whole, never aged', () => {
    // SAP gives a single limit. Splitting it here would invent a number that
    // does not exist anywhere upstream.
    const a = agingOf({ custom_credit_limit: 70000 });
    expect(a.creditLimit).toBe(70000);
    expect(Object.keys(a)).not.toContain('creditLimit0_30');
  });
});

describe('the four boxes', () => {
  it('come out oldest last, with only the last one marked', () => {
    const b = bucketsOf(
      agingOf({
        custom_outstanding_0_30: 1,
        custom_outstanding_30_60: 2,
        custom_outstanding_60_90: 3,
        custom_outstanding_90_plus: 4,
      }),
    );
    expect(b.map((x) => x.amount)).toEqual([1, 2, 3, 4]);
    expect(b.map((x) => x.overdue)).toEqual([false, false, false, true]);
  });

  it('does not mark the oldest box when there is nothing in it', () => {
    // A red box with zero in it trains people to ignore red boxes.
    const b = bucketsOf(agingOf({ custom_outstanding_0_30: 500 }));
    expect(b[3].overdue).toBe(false);
  });
});

describe('the numeric strings Frappe sometimes returns', () => {
  it('are read as money, not as text', () => {
    const a = agingOf({
      custom_outstanding_balance: '19000',
      custom_outstanding_0_30: '19000',
      custom_credit_limit: '25000',
    });
    expect(a.total).toBe(19000);
    expect(a.current).toBe(19000);
    expect(a.creditLimit).toBe(25000);
    expect(a.mismatch).toBe(false);
  });

  it('treat rubbish as zero rather than NaN, which would poison every sum', () => {
    const a = agingOf({ custom_outstanding_balance: 'n/a', custom_outstanding_0_30: null });
    expect(a.total).toBe(0);
    expect(a.sum).toBe(0);
    expect(Number.isNaN(a.total)).toBe(false);
  });
});

describe('the mismatch tolerance', () => {
  it('forgives rounding and nothing more', () => {
    const at = (stored: number) =>
      agingOf({
        custom_outstanding_balance: stored,
        custom_outstanding_0_30: 1000,
      }).mismatch;
    expect(at(1000 + AGING_TOLERANCE)).toBe(false);
    expect(at(1000 + AGING_TOLERANCE + 0.01)).toBe(true);
    expect(at(1000 - AGING_TOLERANCE - 0.01)).toBe(true);
  });

  it('is not raised on a customer nobody has synced', () => {
    // No buckets is not a disagreement. It is silence.
    expect(agingOf({ custom_outstanding_balance: 19000 }).mismatch).toBe(false);
  });
});
