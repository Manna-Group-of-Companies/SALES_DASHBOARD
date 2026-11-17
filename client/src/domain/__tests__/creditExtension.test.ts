/**
 * Temporary credit extension (16 Nov 2026). `shared/fixtures/credit_extension.json`
 * is shared with the Server Script (app/server/test_credit_extension.py), the
 * phone (app/test/credit_extension_test.dart) and the SAP job
 * (sap-credit-sync/Test-CreditExtensions.ps1).
 */
import { describe, expect, it } from 'vitest';
import fx from '../../../../shared/fixtures/credit_extension.json';
import {
  MANAGER_CAP_COUNT,
  MANAGER_CAP_DAYS,
  MANAGER_MAX_DAYS,
  xtCheckGm,
  xtCheckManager,
  xtManagerRecent,
  xtNextStatus,
  xtOutcome,
  xtPaymentStatus,
  xtRouteStatus,
} from '../creditExtension';
import { toCreditExtension } from '../../api/creditExtensions';

describe('temporary credit extension (shared fixture)', () => {
  it("has the fixture's 10 days", () => expect(fx.limits.manager_max_days).toBe(MANAGER_MAX_DAYS));
  it("has the fixture's default cap", () => {
    expect(fx.limits.manager_cap_count).toBe(MANAGER_CAP_COUNT);
    expect(fx.limits.manager_cap_days).toBe(MANAGER_CAP_DAYS);
  });

  describe('routing', () => {
    for (const c of fx.routing) {
      it(c.why, () => expect(xtRouteStatus(c.missed_before, c.open_extension, c.manager_recent, c.cap)).toBe(c.expect));
    }
  });

  describe('manager cap window', () => {
    for (const c of fx.manager_window) it(c.why, () => expect(xtManagerRecent(c.approvals, c.today, c.days)).toBe(c.expect));
  });

  describe('manager approval', () => {
    for (const c of fx.manager_approval) {
      it(c.why, () =>
        expect(
          xtCheckManager({
            amount: c.amount,
            authority: c.authority,
            approvedOn: c.approved_on,
            commitment: c.commitment,
            reason: c.reason,
            remarks: c.remarks,
          }),
        ).toBe(c.expect),
      );
    }
  });

  describe('GM approval', () => {
    for (const c of fx.gm_approval) {
      it(c.why, () => expect(xtCheckGm({ amount: c.amount, today: c.today, commitment: c.commitment, remarks: c.remarks })).toBe(c.expect));
    }
  });

  describe('transitions', () => {
    for (const c of fx.transitions) it(c.why, () => expect(xtNextStatus(c.action, c.from, c.actor) ?? 'REFUSED').toBe(c.expect));
  });

  describe('payment status', () => {
    for (const c of fx.payment_status) {
      it(c.why, () => expect(xtPaymentStatus(c.amount, c.paid)).toEqual({ status: c.expect, remaining: c.remaining }));
    }
  });

  describe('outcome', () => {
    for (const c of fx.outcome) it(c.why, () => expect(xtOutcome(c.amount, c.paid, c.today, c.commitment)).toBe(c.expect));
  });
});

describe('buttons', () => {
  it("need the server's word and the rule's", () => {
    expect(toCreditExtension({ status: 'Pending GM', actor: 'manager', can_approve: 1 }).canApprove).toBe(false);
    const x = toCreditExtension({ status: 'Pending Manager', actor: 'manager', can_approve: 1, can_escalate: 1 });
    expect(x.canApprove).toBe(true);
    expect(x.canEscalate).toBe(true);
    expect(toCreditExtension({ status: 'Pending Manager', actor: 'manager' }).canApprove).toBe(false);
  });

  it('counts 10 calendar days across a year end', () => {
    const base = { amount: 1, authority: 5, approvedOn: '2026-12-27', reason: 'r', remarks: 'r' };
    expect(xtCheckManager({ ...base, commitment: '2027-01-06' })).toBeNull();
    expect(xtCheckManager({ ...base, commitment: '2027-01-07' })).toBe('too_long');
  });
});
