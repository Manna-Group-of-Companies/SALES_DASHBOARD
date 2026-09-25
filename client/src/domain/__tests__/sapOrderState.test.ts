/**
 * SAP's view of an order, turned into something the screens act on.
 *
 * `shared/fixtures/sap_order_state.json` states the rule; this asserts the
 * dashboard obeys it and `app/test/sap_order_state_test.dart` asserts the
 * phone does. Both read the same cases, because a rep and a manager looking
 * at the same order must be told the same thing about it.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/sap_order_state.json';
import {
  cancelledInSap,
  orderBucket,
  orderPill,
  orderProgress,
  ORDER_BUCKET_LABEL,
  lineStatusFromSap,
  orderStatusFromLines,
  productionStatusFromSap,
  reachedSap,
  sapStale,
  sapSummary,
} from '../sapOrderState';

/** A fixture's raw ERPNext document, read the way `toOrderDetail` reads one. */
function fromDoc(o: Record<string, string | undefined>) {
  return {
    salesOrder: o.custom_sap_sales_order,
    salesOrderStatus: o.custom_sap_sales_order_status,
    invoice: o.custom_sap_invoice,
    invoiceDate: o.custom_sap_invoice_date,
  };
}

describe('an order', () => {
  for (const c of cases.order_status) {
    it(c.why, () => {
      expect(productionStatusFromSap({ salesOrder: c.sap_order, invoice: c.invoice })).toBe(c.expect);
    });
  }
});

describe('one line of an order', () => {
  for (const c of cases.line_status) {
    it(c.why, () => {
      expect(lineStatusFromSap({ invoice: c.line_invoice }, { salesOrder: c.order_sap })).toBe(
        c.expect,
      );
    });
  }

  it('without its order, an uninvoiced line cannot claim to be in SAP', () => {
    expect(lineStatusFromSap({})).toBe('Not Started');
  });
});

describe('what an order list shows', () => {
  for (const c of cases.order_progress) {
    it(c.why, () => {
      expect(orderProgress({ salesOrder: c.sap_order, invoice: c.invoice }, c.stored)).toBe(c.expect);
    });
  }

  it('a missing stored status is Not Started', () => {
    expect(orderProgress({}, undefined)).toBe('Not Started');
  });
});

describe('an order rolls up from its lines', () => {
  for (const c of cases.order_rolls_up_from_lines as {
    why: string;
    order_sap: string;
    order_invoice?: string;
    line_invoices: string[];
    expect: string;
  }[]) {
    it(c.why, () => {
      const lines = c.line_invoices.map((invoice) => ({ invoice }));
      expect(
        orderStatusFromLines(lines, { salesOrder: c.order_sap, invoice: c.order_invoice }),
      ).toBe(c.expect);
    });
  }
});

describe('the one line a rep reads', () => {
  for (const c of cases.summary as {
    why: string;
    order: Record<string, string | undefined>;
    expect: string | null;
  }[]) {
    it(c.why, () => {
      expect(sapSummary(fromDoc(c.order))).toBe(c.expect);
    });
  }
});

describe('the mistakes this mapping exists to prevent', () => {
  it("Frappe's string 'null' is not an invoice", () => {
    // An unset field read back through naive interpolation. Treating it as an
    // invoice would mark an order as gone that has not left.
    expect(lineStatusFromSap({ invoice: 'null' }, { salesOrder: '412' })).toBe('Pushed to SAP');
  });

  it('a stale production stage from before 24 Sep 2026 is never read', () => {
    // Fields the type no longer carries cannot reach the derivation at all;
    // this pins that an order carrying one is judged on its invoice alone.
    const doc = { custom_sap_sales_order: '412', custom_sap_production_stage: 'Closed' };
    expect(productionStatusFromSap(fromDoc(doc))).toBe('Pushed to SAP');
  });

  it('not yet in SAP is not the same as failed', () => {
    expect(reachedSap({})).toBe(false);
    expect(reachedSap({ salesOrder: 'SO-1' })).toBe(true);
    expect(reachedSap({ salesOrder: '   ' })).toBe(false);
  });
});

describe('staleness', () => {
  const now = new Date('2026-09-12T10:00:00');

  it('an order SAP never took is not stale, it is waiting', () => {
    expect(sapStale({}, now)).toBe(false);
  });

  it('in SAP but never reconciled is stale', () => {
    expect(sapStale({ salesOrder: 'SO-1' }, now)).toBe(true);
  });

  it('reconciled this morning is not stale', () => {
    expect(sapStale({ salesOrder: 'SO-1', syncedAt: '2026-09-12T08:00:00' }, now)).toBe(false);
  });

  it('reconciled two days ago is stale', () => {
    expect(sapStale({ salesOrder: 'SO-1', syncedAt: '2026-09-10T08:00:00' }, now)).toBe(true);
  });
});

describe('an order SAP has cancelled', () => {
  /*
   * The failure this closes, found 18 September 2026: SAP order 399 had been
   * cancelled and the sync had recorded `bost_Cancelled` on the ERPNext order
   * correctly, for days. Nothing read it, so the sales manager's board went on
   * showing the order as approved.
   */
  for (const c of cases.cancelled_orders as {
    why: string;
    order: Record<string, string>;
    expect_cancelled: boolean;
  }[]) {
    it(c.why, () => {
      expect(
        cancelledInSap({ salesOrderStatus: c.order.custom_sap_sales_order_status }),
      ).toBe(c.expect_cancelled);
    });
  }

  it('says CANCELLED IN SAP however the approval status reads', () => {
    const pill = orderPill('PO Approved - Ready for SAP', {
      salesOrderStatus: 'bost_Cancelled',
    });
    expect(pill.text).toBe('CANCELLED IN SAP');
    expect(pill.tone).toBe('danger');
  });

  it('leaves every other order showing its approval status', () => {
    expect(orderPill('PO Approved - Ready for SAP', { salesOrderStatus: 'bost_Open' }).text).toBe(
      'APPROVED',
    );
    expect(orderPill('Pending Approval', {}).text).toBe('WAITING FOR MANAGER APPROVAL');
    // Closed is finished, not cancelled. Conflating them would retire a
    // delivered order as though it had been called off.
    expect(orderPill('PO Approved - Ready for SAP', { salesOrderStatus: 'bost_Close' }).text).toBe(
      'APPROVED',
    );
  });
});

describe('the four buckets a manager filters their team orders by', () => {
  it('an order waiting on the manager is To approve', () => {
    expect(orderBucket({ approved: false, poStatus: 'Pending Approval' })).toBe('to_approve');
  });

  it('one escalated to the GM is still To approve — somebody owes a decision', () => {
    expect(orderBucket({ approved: false, poStatus: 'Pending GM Approval' })).toBe('to_approve');
  });

  it('an approved order is Approved', () => {
    expect(
      orderBucket({ approved: true, poStatus: 'PO Approved - Ready for SAP' }),
    ).toBe('approved');
  });

  it('a rejected order is Rejected, not To approve', () => {
    // awaitingManager() counts Rejected as still owing a decision, which is
    // right for the header count and wrong for this filter: a manager picking
    // "To approve" wants what they can act on now.
    expect(orderBucket({ approved: false, poStatus: 'Rejected' })).toBe('rejected');
  });

  /*
   * The trap this function exists for. A cancelled order still carries
   * custom_po_status = 'PO Approved - Ready for SAP', so testing approval
   * first files it under Approved while its own pill reads CANCELLED IN SAP —
   * two answers to the same question on one screen.
   */
  it('cancellation outranks approval, exactly as the pill does', () => {
    const cancelled = {
      approved: true,
      poStatus: 'PO Approved - Ready for SAP',
      salesOrderStatus: 'bost_Cancelled',
    };
    expect(orderBucket(cancelled)).toBe('cancelled');
    expect(orderPill(cancelled.poStatus, { salesOrderStatus: cancelled.salesOrderStatus }).text).toBe(
      'CANCELLED IN SAP',
    );
  });

  it('cancellation outranks rejection too', () => {
    expect(
      orderBucket({ approved: false, poStatus: 'Rejected', salesOrderStatus: 'bost_Cancelled' }),
    ).toBe('cancelled');
  });

  it('closed is finished, not cancelled — it stays Approved', () => {
    expect(
      orderBucket({
        approved: true,
        poStatus: 'PO Approved - Ready for SAP',
        salesOrderStatus: 'bost_Close',
      }),
    ).toBe('approved');
  });

  it('an order SAP has not seen is bucketed on its approval status alone', () => {
    expect(orderBucket({ approved: true, poStatus: 'PO Approved - Ready for SAP' })).toBe(
      'approved',
    );
    expect(orderBucket({ approved: false })).toBe('to_approve');
  });

  it("a lead order counting as approved lands in Approved, though isApproved would refuse it", () => {
    // Lead Order.status = 'Approved' is not PO_STATUS.approved. The caller
    // resolves that with leadOrderApproved and passes the answer in.
    expect(orderBucket({ approved: true, poStatus: 'Approved' })).toBe('approved');
    expect(orderBucket({ approved: true, poStatus: 'Converted' })).toBe('approved');
  });

  it('every bucket has a label, so a filter can never render undefined', () => {
    for (const b of ['to_approve', 'approved', 'rejected', 'cancelled'] as const) {
      expect(ORDER_BUCKET_LABEL[b]).toBeTruthy();
    }
  });
});
