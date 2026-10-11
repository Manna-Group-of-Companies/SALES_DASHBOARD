/**
 * When the rep may hand an order's proforma to the customer.
 *
 * Within the credit limit: straight away, as always. For an order that goes
 * to the GM, once the GM has approved the credit — and there is no separate
 * sales-manager release any more (the user, 26 Sep 2026). Rates come from SAP
 * now and the rep cannot change them, so nobody need check the price on a
 * proforma; what is left is credit, and the GM decides that.
 *
 * **Paired with `app/lib/core/proforma_release.dart`.** Both are pinned by
 * `shared/fixtures/proforma_release.json`, which both test suites read. The
 * phone is where a rep hands a proforma over; the dashboard reads this to say
 * what the GM's approval unlocks.
 */

import { creditEscalates, type CustomerRow } from './credit';
import { PO_STATUS } from './orderStatus';

/** What the rep is told while the proforma is held. */
export const PROFORMA_HELD =
  "This order needs the general manager's credit approval. The proforma " +
  'unlocks once the general manager approves the credit.';

/**
 * The statuses that mean the GM has approved the credit: approved and back
 * with the sales manager, or pushed to SAP after that. The sales manager
 * cannot push an over-limit order without the GM (credit_commitment.json).
 */
const CREDIT_APPROVED: ReadonlySet<string> = new Set([PO_STATUS.finalApproval, PO_STATUS.approved]);

/**
 * Whether the proforma for this order must wait.
 *
 * Held only when the order escalates — the same test as `creditEscalates`, so
 * the orders whose proforma waits are exactly the ones the GM decides — and
 * the GM has not approved it. A proforma a sales manager released under the
 * old rule stays released. `Blocked - Credit`, the old refusal, neither holds
 * nor releases on its own: the GM decides now.
 */
export function proformaHeld(input: {
  customer: CustomerRow;
  orderTotal: number;
  poStatus: unknown;
  proformaStatus: unknown;
}): boolean {
  if (!creditEscalates(input.customer, input.orderTotal)) return false;
  if (String(input.proformaStatus ?? '').trim() === 'Released') return false;
  return !CREDIT_APPROVED.has(String(input.poStatus ?? '').trim());
}
