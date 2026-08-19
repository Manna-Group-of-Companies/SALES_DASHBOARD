/**
 * How much of an order line remains to be dispatched.
 *
 * Checked against `shared/fixtures/dispatch.json`, the same file
 * `app/test/dispatch_test.dart` reads.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/dispatch.json';
import { isFullyDispatched, remainingToDispatch } from '../dispatch';

describe('shared fixture: remaining to dispatch', () => {
  for (const c of cases.remaining) {
    it(c.why, () => {
      const left = remainingToDispatch(c.line);
      expect(left).toEqual({ rolls: c.expect.rolls, looseBelts: c.expect.loose_belts });
    });
  }
});

describe('shared fixture: fully dispatched', () => {
  for (const c of cases.fully_dispatched) {
    it(c.why, () => {
      expect(isFullyDispatched(c.line)).toBe(c.expect);
    });
  }
});
