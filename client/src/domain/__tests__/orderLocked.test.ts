/**
 * Approval ends editing, for everyone.
 *
 * `shared/fixtures/order_locked_after_approval.json` states the rule; this
 * file asserts the dashboard obeys it and `app/test/order_rules_test.dart`
 * asserts the phone does.
 *
 * The reason it matters is not policy but plumbing: `Sync-SapOrders.ps1` only
 * ever CREATES a SAP order, and nothing in the repository or the sync updates
 * one. An edit saved after approval changed the ERPNext document, showed a new
 * quantity, and left the factory building the old one.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/order_locked_after_approval.json';
import { isApproved, PO_STATUS } from '../orderStatus';

interface CanEditCase {
  why: string;
  order: Record<string, unknown>;
  expect: boolean;
}

describe('the fixture and the code agree on what "approved" is', () => {
  it('uses the exact stored string, which nothing may paraphrase', () => {
    // The status is free text on the site and three screens key off it. A
    // typo here is an order that silently stays editable.
    expect(fixture.fields.approved_value).toBe(PO_STATUS.approved);
    expect(fixture.fields.approved_value).toBe('PO Approved - Ready for SAP');
  });

  it('recognises the approved status and nothing else', () => {
    expect(isApproved(PO_STATUS.approved)).toBe(true);
    expect(isApproved('Pending Approval')).toBe(false);
    expect(isApproved('Rejected')).toBe(false);
    expect(isApproved('')).toBe(false);
    expect(isApproved(undefined)).toBe(false);
  });
});

describe('every fixture case that turns on the status alone', () => {
  /*
   * Only the status half is asserted here. Ownership and the 1 pm cutoff are
   * the phone's rules — the dashboard gates those on role and `pastCutoff`
   * instead — so the fixture's `can_edit` cases are read for the one thing
   * both sides must agree on: an approved order is shut.
   */
  for (const c of fixture.can_edit as CanEditCase[]) {
    const status = String(c.order.custom_po_status ?? '');
    if (!isApproved(status)) continue;
    it(c.why, () => {
      expect(c.expect).toBe(false);
    });
  }

  it('covers at least one approved case, or this suite proves nothing', () => {
    const approvedCases = (fixture.can_edit as CanEditCase[]).filter((c) =>
      isApproved(String(c.order.custom_po_status ?? '')),
    );
    expect(approvedCases.length).toBeGreaterThan(0);
    expect(approvedCases.every((c) => c.expect === false)).toBe(true);
  });
});

describe('what the lock has to say for itself', () => {
  /*
   * The dashboard builds its sentence inline in `OrderDetailPage`, so what is
   * pinned here is the content the fixture requires rather than one shared
   * function. Both apps have to name the SAP order when there is one — it is
   * what the manufacturing team asks for on the phone — and neither may invent
   * one when the order has not been pushed yet.
   */
  const reason = (sapOrder?: string) =>
    'This order is approved and is with the factory. It cannot be changed here' +
    (sapOrder ? ` — quote SAP order ${sapOrder}` : '') +
    '. To drop or reduce an item, ring the manufacturing team: anything already made is ' +
    'delivered and the rest of the order stays open.';

  for (const c of fixture.lock_reason) {
    const sap = c.order.custom_sap_sales_order as string | undefined;
    if (!isApproved(String(c.order.custom_po_status ?? ''))) continue;
    it(c.why, () => {
      const text = reason(sap);
      for (const needle of c.expect_contains ?? []) {
        expect(text).toContain(needle);
      }
      for (const absent of c.expect_excludes ?? []) {
        expect(text).not.toContain(absent);
      }
    });
  }
});
