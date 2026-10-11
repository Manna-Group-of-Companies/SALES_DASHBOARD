/**
 * The rep's commitment and who may decide an over-limit order, read from the
 * shared fixture.
 *
 * `shared/fixtures/credit_commitment.json` states the rule; this asserts the
 * dashboard obeys it and `app/test/credit_commitment_test.dart` asserts the
 * phone does. The phone raises these orders and the dashboard mostly decides
 * them, so a rule that drifted on either side would let an order through the
 * gap between them.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/credit_commitment.json';
import {
  approvalConditionProblem,
  commentAuthorRole,
  mayAddFollowUpNote,
  COMMENT_EMPTY,
  COMMITMENT_MIN_LENGTH,
  COMMITMENT_MISSING,
  COMMITMENT_TOO_SHORT,
  commitmentProblem,
  commitmentRequired,
  CONDITION_REQUIRED,
  conditionRequiredOnApproval,
  defaultConditionDue,
  GM_DOES_NOT_PUSH,
  orderActions,
  SALES_MANAGER_CANNOT_APPROVE,
} from '../creditCommitment';

const MESSAGE: Record<string, string> = {
  missing: COMMITMENT_MISSING,
  too_short: COMMITMENT_TOO_SHORT,
  condition_required: CONDITION_REQUIRED,
};

describe('the words both apps say', () => {
  it('match the fixture word for word', () => {
    expect(COMMITMENT_MISSING).toBe(cases.messages.missing);
    expect(COMMITMENT_TOO_SHORT).toBe(cases.messages.too_short);
    expect(CONDITION_REQUIRED).toBe(cases.messages.condition_required);
    expect(COMMENT_EMPTY).toBe(cases.messages.comment_empty);
    expect(SALES_MANAGER_CANNOT_APPROVE).toBe(cases.messages.sales_manager_cannot_approve);
    expect(GM_DOES_NOT_PUSH).toBe(cases.messages.gm_does_not_push);
    expect(COMMITMENT_MIN_LENGTH).toBe(cases.rules.min_length);
  });
});

describe('when the rep must write a commitment', () => {
  for (const c of cases.required) {
    it(c.why, () => {
      const isLead = 'is_lead' in c ? Boolean(c.is_lead) : false;
      expect(commitmentRequired(c.customer, c.order_total, isLead)).toBe(c.expect);
    });
  }
});

describe('what counts as a commitment', () => {
  for (const c of cases.text) {
    it(c.why, () => {
      const want = c.expect === null ? null : MESSAGE[c.expect];
      expect(commitmentProblem(c.text)).toBe(want);
    });
  }
});

describe('who may do what to an order', () => {
  for (const c of cases.actions) {
    it(c.why, () => {
      const got = orderActions(c.role, c.po_status, c.over_limit);
      expect({
        approve: got.approve,
        gm_approve: got.gmApprove,
        escalate: got.escalate,
        reject: got.reject,
        comment: got.comment,
      }).toEqual(c.expect);
    });
  }

  it('the sales manager cannot approve an over-limit order until the GM has, whatever the status says', () => {
    for (const s of ['', 'No PO Yet', 'Pending Approval', 'Pending Rate Approval', 'Pending GM Approval']) {
      expect(orderActions('sales_manager', s, true).approve).toBe(false);
    }
  });

  it('the GM never pushes to SAP, on any status, over the limit or not', () => {
    // Asked for 24 Sep 2026: the GM approves the credit and the sales manager
    // pushes. `approve` is the push.
    for (const s of ['', 'No PO Yet', 'Pending Approval', 'Pending GM Approval', 'Pending Final Approval', 'Rejected']) {
      expect(orderActions('general_manager', s, true).approve).toBe(false);
      expect(orderActions('general_manager', s, false).approve).toBe(false);
    }
  });
});

describe('the condition the GM approval creates', () => {
  for (const c of cases.approval) {
    it(c.why, () => {
      expect(conditionRequiredOnApproval(c.commitment)).toBe(c.expect.required);
      const want = c.expect.problem === null ? null : MESSAGE[c.expect.problem];
      expect(approvalConditionProblem(c.commitment, c.condition)).toBe(want);
    });
  }
});

describe('the due date the GM starts from', () => {
  for (const c of cases.default_due) {
    it(c.why, () => {
      expect(defaultConditionDue(c.commitment_due, new Date(`${c.today}T09:00:00`))).toBe(
        c.expect,
      );
    });
  }

  it('does not slip a day at midnight in India', () => {
    // toISOString() at IST midnight is still yesterday in UTC.
    expect(defaultConditionDue('', new Date('2026-09-24T00:05:00'))).toBe('2026-10-09');
  });
});

describe('the follow-up after the GM has approved', () => {
  for (const c of cases.follow_up.comment_roles) {
    it(c.why, () => {
      expect(commentAuthorRole(c.role)).toBe(c.expect);
    });
  }
  for (const c of cases.follow_up.note) {
    it(c.why, () => {
      expect(mayAddFollowUpNote(c.role)).toBe(c.expect);
    });
  }
});
