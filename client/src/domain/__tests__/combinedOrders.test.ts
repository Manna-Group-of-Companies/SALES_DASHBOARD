/**
 * The grouping rule, read from the shared fixture.
 *
 * `shared/fixtures/combined_order.json` is the statement of the rule; this
 * file only asserts that the dashboard obeys it. Unusually for `shared/`, the
 * phone does NOT read this fixture — its own weekly combine was deleted rather
 * than converted, so combining happens in exactly one place. That is recorded
 * in `shared/DIVERGENCES.md` so nobody re-adds a second implementation.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/combined_order.json';
import { planCombinedOrders, type CombinableOrder } from '../combinedOrders';

interface FixtureOrder {
  id: string;
  customer: string | null;
  total: number;
  complete: boolean;
  already_combined: boolean;
}

interface FixtureCase {
  why: string;
  orders: FixtureOrder[];
  expect: Array<{ customer: string; orders: string[]; total: number }>;
}

const toInput = (o: FixtureOrder): CombinableOrder => ({
  id: o.id,
  customer: o.customer,
  total: o.total,
  complete: o.complete,
  alreadyCombined: o.already_combined,
});

describe('which of a dispatch’s orders are combined', () => {
  for (const c of cases.plan as FixtureCase[]) {
    it(c.why, () => {
      const got = planCombinedOrders(c.orders.map(toInput));

      // Compared by customer rather than by position: the fixture states which
      // groups exist, not what order a Map happened to yield them in.
      expect([...got].sort((a, b) => a.customer.localeCompare(b.customer))).toEqual(
        [...c.expect].sort((a, b) => a.customer.localeCompare(b.customer)),
      );
    });
  }

  it('never puts one order in two groups', () => {
    // The invariant behind the whole rule: custom_combined_order is a single
    // Link, so a plan that named an order twice could not be written.
    for (const c of cases.plan as FixtureCase[]) {
      const ids = planCombinedOrders(c.orders.map(toInput)).flatMap((g) => g.orders);
      expect(new Set(ids).size).toBe(ids.length);
    }
  });

  it('never groups an order the dispatch did not finish', () => {
    for (const c of cases.plan as FixtureCase[]) {
      const incomplete = new Set(c.orders.filter((o) => !o.complete).map((o) => o.id));
      const grouped = planCombinedOrders(c.orders.map(toInput)).flatMap((g) => g.orders);
      for (const id of grouped) expect(incomplete.has(id)).toBe(false);
    }
  });
});
