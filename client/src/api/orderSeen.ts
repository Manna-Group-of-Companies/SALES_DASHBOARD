/**
 * The manager has opened an order waiting for them (10 Nov 2026): the rep's
 * app shows a double tick. The manna_order_seen Server Script decides who may
 * and writes it once, without touching the order's `modified`.
 */
import { callMethod } from './client';

const WAITING = new Set(['Pending Approval', 'PO Uploaded - Pending Approval', 'Pending Rate Approval']);

export function markOrderSeen(orderId: string, poStatus: string | undefined): void {
  if (!orderId || !WAITING.has(poStatus ?? '')) return;
  // Best effort: a missed tick must never stop the manager reading the order.
  callMethod('/api/method/manna_order_seen', { order: orderId }).catch(() => undefined);
}
