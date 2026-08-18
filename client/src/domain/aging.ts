/**
 * Aged-stock tracking for minimum-stock items (spec 1.6).
 *
 * Stock is held in dated batches so a rep can be told, in plain words, which
 * lot to clear first: "8 of 10 from 12 Mar (older) · 2 newly restocked 20 Jul".
 */

import type { MinStockItem, ProductionOrder, StockBatch } from './types';

/** Days past which a batch counts as aged and gets prioritised for sale. */
export const AGED_THRESHOLD_DAYS = 60;
/** Days past which it is genuinely stale and shouted about. */
export const STALE_THRESHOLD_DAYS = 120;

export type AgeBand = 'fresh' | 'aging' | 'aged' | 'stale';

export const AGE_BAND_LABEL: Record<AgeBand, string> = {
  fresh: 'Fresh',
  aging: 'Aging',
  aged: 'Aged',
  stale: 'Stale',
};

export function batchAgeDays(batch: StockBatch, now: Date = new Date()): number {
  const [y, m, d] = batch.stockedOn.split('-').map(Number);
  const stocked = new Date(y, (m ?? 1) - 1, d ?? 1);
  const ms = now.getTime() - stocked.getTime();
  return Math.max(0, Math.floor(ms / 86_400_000));
}

export function ageBand(batch: StockBatch, now: Date = new Date()): AgeBand {
  const days = batchAgeDays(batch, now);
  if (days >= STALE_THRESHOLD_DAYS) return 'stale';
  if (days >= AGED_THRESHOLD_DAYS) return 'aged';
  if (days >= AGED_THRESHOLD_DAYS / 2) return 'aging';
  return 'fresh';
}

export function isAged(batch: StockBatch, now: Date = new Date()): boolean {
  const band = ageBand(batch, now);
  return band === 'aged' || band === 'stale';
}

/** Oldest batch first — the order stock should be cleared in. */
export function sortedByAge(batches: StockBatch[]): StockBatch[] {
  return [...batches]
    .filter((b) => b.remaining > 0)
    .sort((a, b) => a.stockedOn.localeCompare(b.stockedOn));
}

export function oldestBatch(item: MinStockItem): StockBatch | undefined {
  return sortedByAge(item.batches)[0];
}

export function agedQty(item: MinStockItem, now: Date = new Date()): number {
  return item.batches
    .filter((b) => isAged(b, now))
    .reduce((sum, b) => sum + b.remaining, 0);
}

export function hasAgedStock(item: MinStockItem, now: Date = new Date()): boolean {
  return agedQty(item, now) > 0;
}

/**
 * The sentence the spec asks for (1.6): "8/10 from an older date, 2 newly
 * restocked". Built from the real batches so it stays true as stock moves.
 */
export function describeBatches(item: MinStockItem, now: Date = new Date()): string {
  const live = sortedByAge(item.batches);
  if (!live.length) return 'No stock on hand';
  return live
    .map((b) => {
      const days = batchAgeDays(b, now);
      const when = formatShort(b.stockedOn);
      if (days <= 7) return `${b.remaining} newly restocked ${when}`;
      return `${b.remaining}/${b.original} from ${when} (${days}d old)`;
    })
    .join(' · ');
}

/**
 * FIFO allocation across dated batches — what the floor should actually pick.
 * Returns the draw per batch plus anything that could not be covered.
 */
export interface Allocation {
  picks: Array<{ batchId: string; stockedOn: string; qty: number; ageDays: number }>;
  shortfall: number;
}

export function allocateFifo(
  item: MinStockItem,
  qty: number,
  now: Date = new Date(),
): Allocation {
  let left = qty;
  const picks: Allocation['picks'] = [];
  for (const b of sortedByAge(item.batches)) {
    if (left <= 0) break;
    const take = Math.min(left, b.remaining);
    if (take > 0) {
      picks.push({ batchId: b.id, stockedOn: b.stockedOn, qty: take, ageDays: batchAgeDays(b, now) });
      left -= take;
    }
  }
  return { picks, shortfall: Math.max(0, left) };
}

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
 * Items a rep should be nudged to push, worst-aged first. Powers the aging
 * list on the order screen and the panel in the manager's review (1.6, 2.1).
 */
export function agingPriorityList(
  items: MinStockItem[],
  now: Date = new Date(),
): Array<{ item: MinStockItem; agedQty: number; oldestDays: number }> {
  return items
    .map((item) => {
      const oldest = oldestBatch(item);
      return {
        item,
        agedQty: agedQty(item, now),
        oldestDays: oldest ? batchAgeDays(oldest, now) : 0,
      };
    })
    .filter((r) => r.agedQty > 0)
    .sort((a, b) => b.oldestDays - a.oldestDays);
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

function formatShort(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  if (!y || !m || !d) return iso;
  return new Date(y, m - 1, d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' });
}
