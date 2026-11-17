/**
 * Item requests go to the rep's manager before the accountant (12 Nov 2026).
 *
 * `shared/fixtures/item_request_flow.json` states what each stage is called and
 * when the accountant may answer; this file asserts the dashboard obeys it, and
 * `app/test/item_request_flow_test.dart` asserts the phone does.
 */
import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/item_request_flow.json';
import { accountantAnswers, itemRequestLabel, itemRequestsWaitingOn } from '../../api/itemRequests';

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

describe('the Item Requests count: what waits on this login (17 Nov 2026)', () => {
  const rows = [
    { status: 'Pending Manager' as const, canApprove: true },
    { status: 'Pending Manager' as const, canApprove: false },
    { status: 'Pending' as const, canApprove: false },
    { status: 'Pending' as const, canApprove: false },
    { status: 'Done' as const, canApprove: false },
  ];

  it('the accountant is shown what a manager has approved and he has not answered', () => {
    expect(itemRequestsWaitingOn('accounts_staff', rows)).toBe(2);
  });

  it('a manager is shown only what is waiting for their own approval', () => {
    expect(itemRequestsWaitingOn('sales_manager', rows)).toBe(1);
    expect(itemRequestsWaitingOn('general_manager', rows)).toBe(1);
  });

  it('HR only reads the list, so nothing waits on them', () => {
    expect(itemRequestsWaitingOn('hr', rows)).toBe(0);
    expect(itemRequestsWaitingOn(undefined, rows)).toBe(0);
  });
});
