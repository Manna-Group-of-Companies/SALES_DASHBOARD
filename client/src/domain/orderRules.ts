/**
 * Who may change what, and until when (spec 2.2, 3.2, 3.3).
 *
 * Two hard invariants live here and are enforced nowhere else:
 *
 *   1. Once the Sales Manager finalises a rate it can never move again, for
 *      anyone, at any later stage (2.2).
 *   2. Approval ends editing (`shared/fixtures/order_locked_after_approval.json`).
 *      Until 11 Oct 2026 orders instead froze at 1:00 PM on the delivery date
 *      (3.3); that cutoff is gone, and the status alone decides.
 *
 * Every editable surface asks this module first, so neither rule can be
 * side-stepped by a screen that forgot about it.
 */

import type { Order, OrderItem, Role, User } from './types';

/**
 * The delivery date the order is actually working to.
 *
 * Production may prepone or postpone (3.2); when they have, that revised date
 * is the one the floor and the rep are both looking at.
 */
export function effectiveDeliveryDate(order: Order): string {
  return order.revisedDeliveryDate || order.deliveryDate;
}

// ------------------------------------------------------------ rate lock ---

/**
 * A rate is locked from the moment the Sales Manager approves the order. This
 * is deliberately not role-aware: nobody outranks it (2.2).
 */
export function isRateLocked(item: OrderItem, order: Order): boolean {
  return item.rateLocked || item.finalRate != null || order.approvedAt != null;
}

/** Only the Sales Manager, and only before approval, may set the final rate. */
export function canEditRate(item: OrderItem, order: Order, user: User): boolean {
  if (isRateLocked(item, order)) return false;
  return user.role === 'sales_manager' && order.status === 'pending_approval';
}

// ---------------------------------------------------------- permissions ---

export type EditDenialReason =
  | 'wrong_role'
  | 'terminal_status'
  | null;

export interface EditPermission {
  allowed: boolean;
  reason: EditDenialReason;
  message: string;
}

const ALLOW: EditPermission = { allowed: true, reason: null, message: '' };

function deny(reason: Exclude<EditDenialReason, null>, message: string): EditPermission {
  return { allowed: false, reason, message };
}

/**
 * May this user still change the *items* on this order?
 *
 * Only until it is approved. An approved order is with the factory, and the
 * sync only ever creates a SAP order, so an edit here would never reach it
 * (order_locked_after_approval.json). Reps edit in the field-sales app, not
 * here.
 */
export function canEditItems(order: Order, user: User): EditPermission {
  if (order.status === 'rejected') {
    return deny('terminal_status', 'This order was rejected.');
  }
  if (order.status === 'grouped') {
    return deny('terminal_status', 'This order has been compiled into a weekly group.');
  }
  if (user.role !== 'sales_manager') {
    return deny('wrong_role', 'Only the Sales Manager can change order items.');
  }
  if (order.status !== 'pending_approval') {
    return deny(
      'terminal_status',
      'This order is approved and is with the factory. It cannot be changed here.',
    );
  }
  return ALLOW;
}

/** Production may move the delivery date on a live order at any time (3.3). */
export function canChangeDeliveryDate(order: Order, user: User): EditPermission {
  if (user.role === 'production_manager') {
    if (order.status === 'approved' || order.status === 'in_production') return ALLOW;
    return deny('terminal_status', 'The date can only be moved on a live order.');
  }
  // The Sales Manager owns the requested date on this side, under the same
  // rules that govern the items.
  if (user.role === 'sales_manager') {
    return canEditItems(order, user);
  }
  return deny('wrong_role', 'You cannot change the delivery date.');
}

/**
 * The creation timestamp is the reference point for the whole lifecycle and is
 * never writable — production explicitly may not touch it (3.2).
 */
export function canEditCreatedAt(): EditPermission {
  return deny('wrong_role', "An order's creation date and time can never be changed.");
}

export function canApprove(order: Order, user: User): EditPermission {
  if (user.role !== 'sales_manager') {
    return deny('wrong_role', 'Only the Sales Manager can approve orders.');
  }
  if (order.status !== 'pending_approval') {
    return deny('terminal_status', 'This order is not waiting for approval.');
  }
  return ALLOW;
}

export function canAdvanceStage(order: Order, user: User): EditPermission {
  if (user.role !== 'production_manager') {
    return deny('wrong_role', 'Only the Production Manager can move production stages.');
  }
  if (order.status !== 'approved' && order.status !== 'in_production') {
    return deny('terminal_status', 'This order is not in production.');
  }
  return ALLOW;
}

/**
 * Who may see the customer's identity — now everyone.
 *
 * Production was excluded until 19 Aug 2026 (spec 3.1: the floor plans vans,
 * not relationships). Dispatch reversed it: somebody loading a vehicle has to
 * know whose pallet is whose, and a route does not say that when two
 * customers sit on one round.
 *
 * Kept as a function rather than deleted so the reversal is visible to
 * anybody who goes looking for the old rule. The live production screens read
 * `customerName` directly now; only the fixture-era screens still call this.
 */
export function canSeeCustomerIdentity(_user: User): boolean {
  return true;
}

/** What to show for the customer. Falls back to the destination if unnamed. */
export function customerLabelFor(order: Order, user: User): string {
  return canSeeCustomerIdentity(user) ? order.customerName : order.destination;
}

// ------------------------------------------------------- edit alerting ---

/**
 * An item change made after approval has to be pushed to the floor as a
 * must-acknowledge alert, so no change is ever missed mid-run (3.3).
 */
export function isPostApprovalEdit(order: Order): boolean {
  return (
    order.approvedAt != null &&
    (order.status === 'approved' ||
      order.status === 'in_production' ||
      order.status === 'dispatched')
  );
}

/** Post-approval edits production has not yet acknowledged. */
export function unacknowledgedEdits(order: Order) {
  return order.timeline.filter((t) => t.requiresAck && !t.ackedAt);
}

// ------------------------------------------------------------ formatting ---

export function formatDate(iso: string): string {
  if (!iso) return '—';
  const [y, m, d] = iso.split('-').map(Number);
  if (!y || !m || !d) return iso;
  return new Date(y, m - 1, d).toLocaleDateString('en-IN', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });
}

export function formatDateTime(iso: string): string {
  if (!iso) return '—';
  const dt = new Date(iso);
  if (Number.isNaN(dt.getTime())) return iso;
  return dt.toLocaleString('en-IN', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function todayIso(): string {
  const d = new Date();
  return toIsoDate(d);
}

export function toIsoDate(d: Date): string {
  const m = `${d.getMonth() + 1}`.padStart(2, '0');
  const day = `${d.getDate()}`.padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

/** Monday of the week containing `iso`. Used to bucket weekly groups (3.4). */
export function weekStartOf(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(y, (m ?? 1) - 1, d ?? 1);
  const dow = (dt.getDay() + 6) % 7; // Monday = 0
  dt.setDate(dt.getDate() - dow);
  return toIsoDate(dt);
}

export function weekEndOf(iso: string): string {
  const [y, m, d] = weekStartOf(iso).split('-').map(Number);
  const dt = new Date(y, (m ?? 1) - 1, d ?? 1);
  dt.setDate(dt.getDate() + 6);
  return toIsoDate(dt);
}

export function roleCanSee(order: Order, role: Role): boolean {
  switch (role) {
    case 'sales_manager':
      return true;
    // The GM decides escalated orders, so they see the whole book — they are
    // who the credit-limit rule escalates to.
    case 'general_manager':
      return true;
    case 'production_manager':
      // The floor only ever sees orders the Sales Manager has released.
      return order.status === 'approved' || order.status === 'in_production' ||
        order.status === 'dispatched' || order.status === 'grouped';
    case 'stock_manager':
      return false;
    case 'hr':
      // HR has no business in the order book — people data only.
      return false;
    case 'managing_director':
      // The MD's login is the rates screen; orders are not on it.
      return false;
    case 'accountant':
      // His screen reads the finished Hi-Tech orders itself; the order book,
      // and every action on it, is not his.
      return false;
  }
}
