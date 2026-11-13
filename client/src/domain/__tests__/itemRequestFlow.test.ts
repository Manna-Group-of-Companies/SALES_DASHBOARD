/**
 * Item requests go to the rep's manager before the accountant (12 Nov 2026).
 *
 * `shared/fixtures/item_request_flow.json` states what each stage is called and
 * when the accountant may answer; this file asserts the dashboard obeys it, and
 * `app/test/item_request_flow_test.dart` asserts the phone does.
 */
import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/item_request_flow.json';
import { accountantAnswers, itemRequestLabel } from '../../api/itemRequests';

interface FlowCase {
  why: string;
  status: string;
  label: string;
  accountant_answers: boolean;
}

describe('item request stages (shared fixture)', () => {
  for (const c of fixture.cases as FlowCase[]) {
    it(c.why, () => {
      expect(itemRequestLabel(c.status)).toBe(c.label);
      expect(accountantAnswers(c.status)).toBe(c.accountant_answers);
    });
  }
});
