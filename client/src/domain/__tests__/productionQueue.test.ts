/**
 * The production manager's queue: what is in it, and how it reads.
 *
 * Decided 24 September 2026 — an order is in the queue once SAP has it; one
 * SAP cancels stays, marked. See `domain/productionQueue.ts`.
 */

import { describe, expect, it } from 'vitest';
import { inProductionQueue, queueState } from '../productionQueue';

describe('what the queue holds', () => {
  it('an approved order SAP has not received is not in it', () => {
    // Approval sends the order to SAP; it is not the same as SAP having it.
    expect(inProductionQueue({ salesOrder: '' })).toBe(false);
    expect(inProductionQueue({})).toBe(false);
  });

  it("an unset link read back as the string 'null' is not a SAP number", () => {
    expect(inProductionQueue({ salesOrder: 'null' })).toBe(false);
  });

  it('an order with a SAP number is in it', () => {
    expect(inProductionQueue({ salesOrder: '379', salesOrderStatus: 'bost_Open' })).toBe(true);
  });

  it('an order SAP cancelled stays in it — it does not vanish', () => {
    expect(inProductionQueue({ salesOrder: '412', salesOrderStatus: 'bost_Cancelled' })).toBe(true);
  });
});

describe('how an order in the queue reads', () => {
  it('reads Pushed to SAP while SAP has it and it is not invoiced', () => {
    expect(queueState({ salesOrder: '379', salesOrderStatus: 'bost_Open' })).toBe('in_sap');
  });

  it('a delivery alone is not dispatch — a closed, uninvoiced order still reads Pushed to SAP', () => {
    // SAP order 381 was closed after a partial delivery and never invoiced.
    expect(queueState({ salesOrder: '381', salesOrderStatus: 'bost_Close' })).toBe('in_sap');
  });

  it('reads Dispatched once the order is invoiced', () => {
    expect(queueState({ salesOrder: '379', salesOrderStatus: 'bost_Close', invoice: '5021' })).toBe(
      'dispatched',
    );
  });

  it('reads Cancelled in SAP, whatever else the order carries', () => {
    expect(queueState({ salesOrder: '412', salesOrderStatus: 'bost_Cancelled' })).toBe('cancelled');
    expect(queueState({ salesOrder: '412', salesOrderStatus: 'bost_Cancelled', invoice: '9' })).toBe(
      'cancelled',
    );
  });
});
