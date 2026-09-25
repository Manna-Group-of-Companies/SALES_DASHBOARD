/**
 * What the production manager's queue holds, and how each order reads on it.
 *
 * DECIDED 24 SEPTEMBER 2026
 *
 * **An order is in the queue once SAP has it, and not before.** SAP is where
 * the factory works from; an order approved in ERPNext that has not reached
 * SAP is not work the floor can see yet, and showing it made the queue a list
 * of intentions rather than jobs. The test is the SAP sales-order number the
 * sync writes back (`reachedSap`), not the approval status: approval is what
 * *sends* an order to SAP, and the two differ for exactly as long as the push
 * takes — or for ever, when a push fails.
 *
 * **An order SAP cancels stays in the queue, marked Cancelled in SAP.** It
 * does not vanish. A production manager who planned for it needs to see that
 * it has gone, and a row that silently disappears reads as a glitch.
 *
 * The states are SAP's, via `sapOrderState.ts` (pinned by
 * `shared/fixtures/sap_order_state.json`): cancelled outranks everything, then
 * an invoice means Dispatched, and otherwise the order is Pushed to SAP. This
 * file adds no rule of its own about money, approval or stock — only which
 * rows one dashboard screen lists.
 */

import { cancelledInSap, orderProgress, reachedSap, type SapOrderState } from './sapOrderState';

export type QueueState = 'in_sap' | 'dispatched' | 'cancelled';

export const QUEUE_STATE_LABEL: Record<QueueState, string> = {
  in_sap: 'Pushed to SAP',
  dispatched: 'Dispatched',
  cancelled: 'Cancelled in SAP',
};

/** Filter order: the live work first, the finished and the dead after. */
export const QUEUE_STATES: QueueState[] = ['in_sap', 'dispatched', 'cancelled'];

/** Whether an order belongs in the production queue at all. */
export function inProductionQueue(sap: SapOrderState): boolean {
  return reachedSap(sap);
}

/**
 * How an order in the queue reads.
 *
 * Cancellation first, as `orderPill` does: it is the later fact and the
 * terminal one, and a cancelled order may still carry fields from before.
 * Then `orderProgress`, the same reading the sales lists give the same order,
 * so a manager and the floor cannot disagree about whether it has gone.
 */
export function queueState(sap: SapOrderState): QueueState {
  if (cancelledInSap(sap)) return 'cancelled';
  return orderProgress(sap) === 'Dispatched' ? 'dispatched' : 'in_sap';
}
