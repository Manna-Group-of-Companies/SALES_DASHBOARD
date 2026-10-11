/**
 * Re-raising a finished Hi-Tech order in Manna Treads, against the shared
 * fixture `sap-order-sync/Test-MannaTreadsReorder.ps1` reads too. The sync
 * writes SAP from the same rule, so a case passing here and failing there is
 * the accountant approving one invoice and SAP raising another.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/manna_treads_reorder.json';
import {
  assessOrder,
  GST_PERCENT,
  groupByCustomer,
  mayRequest,
  roundTo,
  viewOf,
  type MtBillableLine,
  type MtOrderInput,
} from '../mannaTreadsReorder';

interface Expected {
  state: string;
  basis?: string;
  lines?: MtBillableLine[];
  total?: number;
}

describe('shared/fixtures/manna_treads_reorder.json', () => {
  it('prices net of the same GST the fixture states', () => {
    expect(GST_PERCENT).toBe(fixture.gst_percent);
  });

  for (const c of fixture.cases) {
    it(c.why, () => {
      const got = assessOrder(c.order as MtOrderInput);
      const want = c.expect as Expected;
      expect(got.state).toBe(want.state);
      if (want.basis !== undefined) expect(got.basis).toBe(want.basis);
      if (want.lines !== undefined) expect(got.lines).toEqual(want.lines);
      if (want.total !== undefined) expect(got.total).toBe(want.total);
    });
  }
});

describe('what the accountant may ask for', () => {
  it('only a ready order, or a failed one asked for again', () => {
    expect(mayRequest('ready')).toBe(true);
    expect(mayRequest('failed')).toBe(true);
    for (const s of ['queued', 'created', 'blocked', 'at_hitech', 'nothing_delivered', 'cancelled', 'not_in_sap'] as const) {
      expect(mayRequest(s)).toBe(false);
    }
  });

  it('an order not in SAP is on none of his filters', () => {
    expect(viewOf('not_in_sap')).toBeNull();
    expect(viewOf('queued')).toBe('sent');
    expect(viewOf('failed')).toBe('sent');
    expect(viewOf('blocked')).toBe('not_billable');
  });
});

describe('rounding a line amount', () => {
  it('rounds half up from the decimal sum, not from its binary noise', () => {
    // 55.555 × 199 is 11055.445 on paper and 11055.444999999998 as a double.
    expect(roundTo(55.555 * 199, 2)).toBe(11055.45);
    expect(roundTo(60.125 * 199, 2)).toBe(11964.88);
    expect(roundTo(34.2 * 170, 2)).toBe(5814);
  });
});

describe('grouping ready orders by customer', () => {
  const row = (name: string, customer: string, customerName: string, total: number) => ({
    name,
    customer,
    customerName,
    mtCode: `MT-${customer}`,
    total,
  });

  it("puts one customer's orders together and totals them", () => {
    const groups = groupByCustomer([
      row('SO-1', 'C-A', 'Alpha Tyres', 11940),
      row('SO-2', 'C-B', 'Beta Retreads', 5814),
      row('SO-3', 'C-A', 'Alpha Tyres', 11044.5),
    ]);
    expect(groups.map((g) => g.customer)).toEqual(['C-A', 'C-B']);
    expect(groups[0].orders.map((o) => o.name)).toEqual(['SO-1', 'SO-3']);
    expect(groups[0].total).toBe(22984.5);
    expect(groups[0].mtCode).toBe('MT-C-A');
  });

  it('sorts customers by name, whatever order they arrive in', () => {
    const groups = groupByCustomer([
      row('SO-1', 'C-2', 'Zeta Motors', 1),
      row('SO-2', 'C-1', 'Alpha Tyres', 1),
    ]);
    expect(groups.map((g) => g.customerName)).toEqual(['Alpha Tyres', 'Zeta Motors']);
  });

  it('keeps two customers apart even when their names are the same', () => {
    const groups = groupByCustomer([
      row('SO-1', 'C-1', 'Sree Tyres', 100),
      row('SO-2', 'C-2', 'Sree Tyres', 200),
    ]);
    expect(groups).toHaveLength(2);
    expect(groups.map((g) => g.total)).toEqual([100, 200]);
  });

  it('adds totals without drifting a paisa', () => {
    const groups = groupByCustomer([row('SO-1', 'C-1', 'A', 0.1), row('SO-2', 'C-1', 'A', 0.2)]);
    expect(groups[0].total).toBe(0.3);
  });

  it('nothing ready is no groups', () => {
    expect(groupByCustomer([])).toEqual([]);
  });
});
