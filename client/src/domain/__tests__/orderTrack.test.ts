/**
 * An order's stage track, read from real fields only.
 *
 * `shared/fixtures/order_track.json` states the rule. The phone does not show
 * the track yet; when it does, its test must read the same cases.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/order_track.json';
import windowFixture from '../../../../shared/fixtures/pick_list_window.json';
import {
  orderTrack,
  pickIsOpen,
  pickListIncludes,
  pickListsByOrder,
  pickOpensOn,
  responsibleText,
  type PickFacts,
} from '../orderTrack';

type Raw = Record<string, string | undefined>;

/** A fixture's raw Sales Order, read the way `toTeamOrder` reads one. */
function fromDoc(o: Raw, lists: Raw[] | null, today?: string, since?: string) {
  return {
    placedOn: o.transaction_date,
    deliveryDate: o.delivery_date,
    today,
    pickListsSince: since,
    poStatus: o.custom_po_status,
    gmApprovedBy: o.custom_gm_approved_by,
    gmApprovedOn: o.custom_gm_approved_on,
    mtSalesOrder: o.custom_mt_sales_order,
    mtSyncError: o.custom_mt_sync_error,
    mtInvoice: o.custom_mt_invoice,
    sapSalesOrder: o.custom_sap_sales_order,
    sapSalesOrderStatus: o.custom_sap_sales_order_status,
    sapOrderStatus: o.custom_sap_order_status,
    sapInvoice: o.custom_sap_invoice,
    sapSyncError: o.custom_sap_sync_error,
    pickLists:
      lists === null
        ? null
        : lists.map(
            (l): PickFacts => ({
              name: l.name ?? '',
              status: l.status,
              approvalStatus: l.approval_status,
              sapPickList: l.sap_pick_list,
              hitechInvoice: l.hitech_invoice,
              mtGoodsReceipt: l.mt_goods_receipt,
              mtDelivery: l.mt_delivery,
              sapError: l.sap_sync_error,
            }),
          ),
  };
}

describe('an order track', () => {
  for (const c of fixture.cases) {
    it(c.why, () => {
      const k = c as { today?: string; pick_lists_since?: string };
      const t = orderTrack(fromDoc(c.order as Raw, c.pick_lists as Raw[] | null, k.today, k.pick_lists_since));
      expect(t.stages.map((s) => s.state)).toEqual(c.expect.stages);
      expect(t.sap).toEqual({ mannaTreads: c.expect.sap.manna_treads, hitech: c.expect.sap.hitech });
      expect(t.action.who).toBe(c.expect.who);
      expect(t.outcome).toBe(c.expect.outcome);
      const early = (c.expect as { early_sap?: boolean }).early_sap;
      if (early !== undefined) expect(t.sentBeforeApproval).toBe(early);
    });
  }
});

describe('when a pick list opens (pick_list_window.json, as the phone reads it)', () => {
  for (const c of windowFixture.cases) {
    it(c.why, () => {
      expect(pickOpensOn(c.delivery_date)).toBe(c.opens_on);
      expect(pickIsOpen(c.delivery_date, c.today)).toBe(c.open);
    });
  }
  for (const c of windowFixture.since_cases) {
    it(c.why, () => {
      expect(pickListIncludes(c.order_date, c.since)).toBe(c.included);
    });
  }
});

describe("an order's pick lists from one read", () => {
  for (const c of fixture.pick_lists_by_order) {
    it(c.why, () => {
      const lists = c.lists === null ? null : c.lists.map((salesOrder) => ({ salesOrder }));
      const got = pickListsByOrder(lists, c.orders, c.limit);
      const counts = Object.fromEntries(Object.entries(got).map(([k, v]) => [k, v === null ? null : v.length]));
      expect(counts).toEqual(c.expect);
    });
  }
});

describe('what the screens say', () => {
  it('names both SAPs when both hold the order', () => {
    const t = orderTrack({ poStatus: 'PO Approved - Ready for SAP', mtSalesOrder: '590', sapSalesOrder: '569', pickLists: [] });
    expect(t.sapLine).toBe('Manna Treads SAP SO 590 · Hi-Tech SAP SO 569');
  });

  it('says plainly when no SAP has it', () => {
    expect(orderTrack({ poStatus: 'Pending Approval', pickLists: [] }).sapLine).toBe('Not in SAP yet');
  });

  it("names the GM and the day from the order's stamp", () => {
    const t = orderTrack({
      poStatus: 'PO Approved - Ready for SAP',
      gmApprovedBy: 'Rajiv',
      gmApprovedOn: '2026-11-19 22:06:36',
      pickLists: [],
    });
    expect(t.stages[1].note).toBe('Approved by Rajiv · 19-11-2026');
  });

  it('says how far a pick list has gone, from its own fields', () => {
    const t = orderTrack({
      poStatus: 'PO Approved - Ready for SAP',
      sapSalesOrder: '569',
      pickLists: [{ name: 'PICK-00493', status: 'Submitted', sapPickList: '18' }],
    });
    expect(t.pickList).toBe('PICK-00493 · In SAP · SAP pick list 18');
    expect(t.action.text).toContain('SAP pick list 18');
  });

  it('shows the sync error as the reason the office must act', () => {
    const t = orderTrack({ poStatus: 'PO Approved - Ready for SAP', sapSyncError: 'Item I-1 not found', pickLists: [] });
    expect(t.action.text).toBe('Fix the SAP sync: Item I-1 not found');
  });

  it("names the rep when the next step is theirs", () => {
    expect(responsibleText('rep', 'Amjad Pr')).toBe('Rep (Amjad Pr)');
    expect(responsibleText('rep', '')).toBe('Rep');
    expect(responsibleText('office')).toBe('Office / SAP');
    expect(responsibleText(null)).toBe('');
  });
});
