/**
 * What a minimum-stock pool has in it, and how full it is.
 *
 * This file was the dead-stock feature: age bands, staleness thresholds, a
 * FIFO allocator, "which lot to clear first" sentences, and a priority list of
 * items drifting towards a write-off. **All of it was removed on 21 August
 * 2026.** The business does not want stock decisions made on how long
 * something has sat, and every screen that displayed it is gone.
 *
 * The dated batches themselves are untouched, in ERPNext and in `MinStockItem`
 * — `onHand` is still what they add up to. Nothing here reads their dates any
 * more. If age is ever wanted again it is a new decision, not a revert.
 */

import type { MinStockItem, ProductionOrder } from './types';

/** Free to sell right now — on-hand less anything other reps are holding (1.2). */
export function availableQty(item: MinStockItem): number {
  return Math.max(0, item.onHand - item.reserved);
}

export function isBelowThreshold(item: MinStockItem): boolean {
  return item.onHand < item.threshold;
}

/** 0–1 fill level against the threshold, for the stock meter. */
export function stockLevel(item: MinStockItem): number {
  if (item.threshold <= 0) return 1;
  return Math.min(1, item.onHand / item.threshold);
}

/**
 * Cross-reference production orders against the ledger they came from.
 *
 * `Manna Production Order` stores no item name and `Manna Minimum Stock Item`
 * stores no "replenishment raised" flag (there is nowhere on either live
 * doctype to put one) — both are derived here, once, so every screen reading
 * either list sees the same joined truth instead of re-deriving it, or one
 * screen showing "Replenish" while another still thinks nothing is open.
 */
export function joinProductionOrders(
  items: MinStockItem[],
  orders: ProductionOrder[],
): { items: MinStockItem[]; orders: ProductionOrder[] } {
  const nameByCode = new Map(items.map((i) => [i.itemCode, i.itemName]));
  const openStockItemCodes = new Set(
    orders
      .filter((o) => o.purpose === 'stock' && o.status !== 'received' && o.status !== 'cancelled')
      .map((o) => o.itemCode),
  );

  return {
    items: items.map((i) =>
      openStockItemCodes.has(i.itemCode) ? { ...i, replenishmentRaised: true } : i,
    ),
    orders: orders.map((o) => ({ ...o, itemName: nameByCode.get(o.itemCode) ?? o.itemName })),
  };
}
