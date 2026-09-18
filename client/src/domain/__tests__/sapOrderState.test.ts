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
  ORDER_BUCKET_LABEL,
  lineStatusFromSap,
  orderStatusFromLines,
  productionStatusFromSap,
  reachedSap,
  sapStale,
  sapSummary,
} from '../sapOrderState';

describe('SAP stage to production status', () => {
  for (const c of cases.stage_to_status) {
    it(c.why, () => {
      expect(
        productionStatusFromSap({
          productionStage: c.sap_stage,
          salesOrder: c.sap_order,
          deliveryOrder: c.delivery,
        }),
      ).toBe(c.expect);
    });
  }
});

describe('one line of an order', () => {
  for (const c of cases.line_stage_to_status) {
    it(c.why, () => {
      expect(
        lineStatusFromSap({
          productionStage: c.line_stage,
          deliveryOrder: c.line_delivery,
        }),
      ).toBe(c.expect);
    });
  }
});

describe('an order rolls up from its lines', () => {
  for (const c of cases.order_rolls_up_from_lines) {
    it(c.why, () => {
      const lines = c.line_stages.map((s) => ({
        productionOrder: s ? 'PO-1' : '',
        productionStage: s,
      }));
      expect(orderStatusFromLines(lines, { salesOrder: 'SO-1001' })).toBe(c.expect);
    });
  }

  for (const c of cases.order_rolls_up_from_deliveries) {
    it(c.why, () => {
      const lines = c.line_stages.map((s, i) => ({
        productionOrder: 'PO-1',
        productionStage: s,
        deliveryOrder: c.line_deliveries[i],
      }));
      expect(orderStatusFromLines(lines, { salesOrder: 'SO-1001' })).toBe(c.expect);
    });
  }

  it('a line SAP has not touched does not drag the order back', () => {
    // Lines carrying nothing fall back to the order's own stage, rather than
    // reporting Not Started over the top of a real one.
    expect(
      orderStatusFromLines([{}], { salesOrder: 'SO-1', productionStage: 'Curing' }),
    ).toBe('In Production');
  });

  it('an order-level delivery no longer overrides an unshipped line', () => {
    // The bug this replaced: order 381 had a delivery, so every line read
    // Dispatched - including the one deliberately left off it.
    expect(
      orderStatusFromLines(
        [
          { productionOrder: 'PO-1', productionStage: 'Closed', deliveryOrder: 'DN-1' },
          { productionOrder: 'PO-2', productionStage: 'Planned', deliveryOrder: '' },
        ],
        { salesOrder: 'SO-1', deliveryOrder: 'DN-1' },
      ),
    ).toBe('Not Started');
  });
});

describe('the mistakes this mapping exists to prevent', () => {
  it('an unmapped stage is never Ready', () => {
    // Ready tells a rep the order is made. A stage nobody has mapped means the
    // floor started and we do not know how far.
    for (const stage of ['Zzz', 'Vulcanising', 'Trimming', 'Stage 7', '???']) {
      expect(
        productionStatusFromSap({ salesOrder: 'SO-1', productionStage: stage }),
      ).toBe('In Production');
    }
  });

  it('a delivery order outranks any stage', () => {
    // The delivery is the later fact; a production record can be stale.
    expect(
      productionStatusFromSap({
        salesOrder: 'SO-1',
        productionStage: 'Curing',
        deliveryOrder: 'DN-9',
      }),
    ).toBe('Dispatched');
  });

  it("Frappe's string 'null' is not a delivery order", () => {
    // An unset Link read back through naive interpolation. Treating it as a
    // delivery would mark an unmade order as shipped.
    expect(
      productionStatusFromSap({ salesOrder: 'SO-1', deliveryOrder: 'null' }),
    ).toBe('Not Started');
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

describe('the one line a rep reads', () => {
  it('leads with the delivery once there is one', () => {
    expect(
      sapSummary({
        salesOrder: 'SO-1001',
        productionStage: 'Curing',
        deliveryOrder: 'DN-500',
        deliveryDate: '2026-09-15',
      }),
    ).toBe('Delivery DN-500 · due 2026-09-15 · SAP SO-1001');
  });

  it('falls back to the stage before there is a delivery', () => {
    expect(sapSummary({ salesOrder: 'SO-1001', productionStage: 'Curing' })).toBe(
      'Curing · SAP SO-1001',
    );
  });

  it('says nothing when there is nothing to say', () => {
    expect(sapSummary({})).toBeNull();
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

describe('a line whose production order was cancelled', () => {
  /*
   * `Select-LeastAdvancedPo` skips cancelled production orders, so a line whose
   * only PO was cancelled has nothing covering it. The sync clears the stage;
   * these assert that a cleared stage is what Not Started looks like, which is
   * the half of the rule that lives in the apps.
   */
  it('reads Not Started once the sync has cleared its stage', () => {
    expect(lineStatusFromSap({ productionStage: '', productionOrder: '' })).toBe('Not Started');
  });

  it('is indistinguishable from a line that never had one, which is the point', () => {
    expect(lineStatusFromSap({})).toBe('Not Started');
  });

  it('but a delivered line stays Dispatched, cleared stage or not', () => {
    // A cancelled production order after the goods have gone must not reopen
    // the line; the delivery is the later fact.
    expect(lineStatusFromSap({ productionStage: '', deliveryOrder: 'DN-9' })).toBe('Dispatched');
  });
});
