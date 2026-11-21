/**
 * The 10-day payment commitment ladder (17 Nov 2026). `shared/fixtures/payment_commitment.json`
 * is shared with the phone (app/test/payment_commitment_test.dart) and the Server Scripts
 * (app/server/test_payment_commitment.py).
 */
import { describe, expect, it } from 'vitest';
import fx from '../../../../shared/fixtures/payment_commitment.json';
import {
  PC_MAX_DAYS,
  PC_OVERDUE_DAYS,
  pcCheckApproval,
  pcGmLock,
  pcNeeds,
  pcOrderStage,
  pcRoute,
  pcTrack,
} from '../paymentCommitment';
import { OVERDUE_TOLERANCE } from '../credit';

describe('payment commitment ladder (shared fixture)', () => {
  it("has the fixture's limits", () => {
    expect(fx.limits.max_days).toBe(PC_MAX_DAYS);
    expect(fx.limits.overdue_days_trigger).toBe(PC_OVERDUE_DAYS);
    expect(fx.limits.overdue_rounding).toBe(OVERDUE_TOLERANCE);
  });

  describe('what an order needs', () => {
    for (const c of fx.needs) {
      it(c.why, () => expect(pcNeeds(c.customer as Record<string, unknown>, c.order_total)).toEqual({
        overdue30: c.expect.overdue30,
        overLimit: c.expect.over_limit,
        excess: c.expect.excess,
        needs: c.expect.needs,
      }));
    }
  });

  describe('where it goes', () => {
    for (const c of fx.route) {
      it(c.why, () =>
        expect(
          pcRoute({
            needs: c.needs,
            overLimit: c.over_limit,
            excess: c.excess,
            authority: c.authority,
            gmLock: c.gm_lock,
            capReached: c.cap_reached,
          }),
        ).toBe(c.expect),
      );
    }
  });

  describe('the GM lock', () => {
    for (const c of fx.gm_lock) it(c.why, () => expect(pcGmLock(c.commitments)).toBe(c.expect));
  });

  describe('an approval', () => {
    for (const c of fx.approval) {
      it(c.why, () => expect(pcCheckApproval({ approvedOn: c.approved_on, commitment: c.commitment, remarks: c.remarks })).toBe(c.expect));
    }
  });

  describe('tracking', () => {
    for (const c of fx.track) {
      it(c.why, () =>
        expect(
          pcTrack({
            status: c.status,
            approvedOn: c.approved_on,
            commitment: c.commitment,
            today: c.today,
            overdueNow: c.overdue_now,
            syncedAt: c.synced_at,
          }),
        ).toBe(c.expect),
      );
    }
  });

  describe('order stage', () => {
    for (const c of fx.order_status) {
      it(c.why, () => expect(pcOrderStage({ poStatus: c.po_status, pushed: c.pushed, commitment: c.commitment })).toBe(c.expect));
    }
  });
});
