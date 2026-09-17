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
