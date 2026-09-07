/**
 * The credit condition state machine, read from the shared fixture.
 *
 * `shared/fixtures/credit_condition.json` states the rule; this asserts the
 * dashboard obeys it and `app/test/credit_condition_test.dart` asserts the
 * phone does. Both read the same cases, because both apps move these records
 * and the one rule that matters — a rep cannot close their own obligation —
 * is worth nothing if either side forgets it.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/credit_condition.json';
import {
  canMoveCondition,
  conditionOverdue,
  nextConditionStatus,
  type ConditionAction,
} from '../creditCondition';

describe('who may move a condition', () => {
  for (const c of cases.transitions) {
    it(c.why, () => {
      const got = nextConditionStatus(c.from, c.action as ConditionAction, c.actor);
      if (c.expect === 'REFUSED') {
        expect(got).toBeNull();
        expect(canMoveCondition(c.from, c.action as ConditionAction, c.actor)).toBe(false);
      } else {
        expect(got).toBe(c.expect);
      }
    });
  }
});

describe('when a condition is overdue', () => {
  for (const c of cases.overdue) {
    it(c.why, () => {
      expect(conditionOverdue(c.status, c.due, new Date(`${c.today}T09:00:00`))).toBe(
        c.expect,
      );
    });
  }
});

describe('the rule the whole feature exists for', () => {
  it('nobody but the GM can close, whatever role they claim', () => {
    for (const actor of ['rep', 'sales_manager', 'production_manager', 'hr', '', 'admin']) {
      expect(canMoveCondition('Awaiting Review', 'close', actor)).toBe(false);
    }
    expect(canMoveCondition('Awaiting Review', 'close', 'gm')).toBe(true);
  });

  it('an unknown action is refused rather than guessed at', () => {
    expect(canMoveCondition('Open', 'delete' as ConditionAction, 'gm')).toBe(false);
  });
});
