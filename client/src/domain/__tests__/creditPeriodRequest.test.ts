/**
 * Credit-period requests (16 Nov 2026): up to 30 days the manager decides and
 * pushes; 31 to 40 the GM does, after the manager escalates.
 *
 * `shared/fixtures/credit_period_request.json` is shared with the Server
 * Script (app/server/test_credit_period_request.py), the phone
 * (app/test/credit_period_request_test.dart) and the credit sync
 * (sap-credit-sync/Test-CreditPeriodPush.ps1).
 */
import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/credit_period_request.json';
import {
  GM_MAX_DAYS,
  MANAGER_MAX_DAYS,
  cprBand,
  cprLabel,
  cprNextStatus,
  cprOfferedTerms,
  cprSubmitStatus,
} from '../creditPeriodRequest';
import { toCreditPeriodRequest } from '../../api/creditPeriodRequests';

describe('credit-period requests (shared fixture)', () => {
  it('has the fixture\'s limits', () => {
    expect(fixture.limits).toEqual({ manager_max_days: MANAGER_MAX_DAYS, gm_max_days: GM_MAX_DAYS });
  });

  describe('transitions', () => {
    for (const c of fixture.transitions) {
      it(c.why, () => {
        expect(cprNextStatus(c.action, c.from, c.days, c.actor) ?? 'REFUSED').toBe(c.expect);
      });
    }
  });

  describe('submit', () => {
    for (const c of fixture.submit) {
      it(c.why, () => expect(cprSubmitStatus(c.days) ?? 'REFUSED').toBe(c.expect));
    }
  });

  describe('bands', () => {
    for (const c of fixture.bands) {
      it(c.why, () => expect(cprBand(c.days)).toBe(c.band));
    }
  });

  describe('labels', () => {
    for (const c of fixture.labels) {
      it(`"${c.status}" reads as ${c.label}`, () => expect(cprLabel(c.status)).toBe(c.label));
    }
  });

  it(fixture.offered.why, () => {
    expect(cprOfferedTerms(fixture.offered.terms, fixture.offered.current_code).map((t) => t.code)).toEqual(
      fixture.offered.expect_codes,
    );
  });
});

describe('buttons', () => {
  it("needs the server's word and the rule's", () => {
    const r = toCreditPeriodRequest({
      status: 'With Manager', requested_days: 35, actor: 'manager', can_approve: 1, can_escalate: 1, can_reject: 1,
    });
    // A server that offered a manager approval on 35 days is out of date.
    expect(r.canApprove).toBe(false);
    expect(r.canEscalate).toBe(true);
    expect(r.canReject).toBe(true);
    expect(r.needsGm).toBe(true);
  });

  it("offers nothing without the server's word", () => {
    const r = toCreditPeriodRequest({ status: 'Approved', requested_days: 20, actor: 'manager' });
    expect(r.canPush).toBe(false);
  });

  it('reads a request with no status as with the manager and offers nothing', () => {
    const r = toCreditPeriodRequest({ name: 'CPR-00001', can_approve: 1, actor: 'gm' });
    expect(r.label).toBe('With Manager');
    expect(r.canApprove).toBe(false);
  });
});
