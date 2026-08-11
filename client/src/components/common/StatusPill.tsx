/**
 * The approval-status pill, and the completion tick.
 *
 * Both appear on every order row in both dashboards, so they live together and
 * are built once. Two rules they exist to enforce:
 *
 *   - **Never show the stored string.** ERPNext speaks in purchase orders —
 *     "PO Approved - Ready for SAP" — and nobody here scans a PO or logs into
 *     SAP. The raw value goes in the `title` for whoever is debugging.
 *   - **Name the state, don't just tick or not.** "Ready" and "In Production"
 *     are both "not complete", and someone chasing an order needs to know
 *     which of the two they are chasing.
 */

import { statusPill, tickState, TICK_LABEL, type TickState } from '@/domain/orderStatus';
import './status.css';

export function StatusPill({ status }: { status?: string | null }) {
  const { text, tone } = statusPill(status);
  return (
    <span className={`spill spill--${tone}`} title={status || 'no status stored'}>
      {text}
    </span>
  );
}

const BOX: Record<TickState, string> = {
  complete: '☑',
  ready: '⊟',
  in_production: '⊟',
  not_started: '☐',
};

/**
 * Derived from the production status and never stored.
 *
 * There is deliberately no `custom_order_complete` field: a stored flag is one
 * more thing that can disagree with the floor — ticked on an order still being
 * made, or left unticked on one long gone.
 *
 * `applicable={false}` renders nothing at all. A lead order is not a Sales
 * Order yet and has no production status; an empty box against one would read
 * as "not finished" rather than "not applicable".
 */
export function CompletionTick({
  productionStatus,
  applicable = true,
}: {
  productionStatus?: string | null;
  applicable?: boolean;
}) {
  if (!applicable) return null;
  const state = tickState(productionStatus);
  return (
    <span className={`tick tick--${state}`}>
      <span aria-hidden="true">{BOX[state]}</span>
      {TICK_LABEL[state]}
    </span>
  );
}
