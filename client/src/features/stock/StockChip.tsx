/**
 * The minimum-stock indicator that sits on every product row (1.2).
 *
 * The spec is explicit that a product *not* on the minimum-stock list must read
 * "No minimum stock" rather than a zero — a zero would be read as "out of
 * stock", which is a different and much more alarming thing.
 *
 * `available` and `reservedByOthers` are passed in rather than derived from the
 * item, because on the order screen the number that matters is what is free to
 * *this* rep — which includes the quantity they are holding themselves.
 */

import type { MinStockItem } from '@/domain/types';
import { availableQty, describeBatches, hasAgedStock } from '@/domain/aging';
import { Tooltip } from '@/components/ui';

export function StockChip({
  item,
  available,
  reservedByOthers,
}: {
  item?: MinStockItem;
  available?: number;
  reservedByOthers?: number;
}) {
  if (!item) {
    return <span className="stock-chip stock-chip--none">No minimum stock</span>;
  }

  const free = available ?? availableQty(item);
  const heldElsewhere = reservedByOthers ?? item.reserved;
  const tone = free <= 0 ? 'out' : item.onHand < item.threshold ? 'low' : 'ok';
  const label = free <= 0 ? 'Fully booked' : `${format(free)} ${item.uom} available`;

  return (
    <span className="stack gap-1" style={{ alignItems: 'flex-start' }}>
      <Tooltip text={describeBatches(item)}>
        <span className={`stock-chip stock-chip--${tone}`}>
          {tone === 'low' && '⚠ '}
          {label}
        </span>
      </Tooltip>

      {/* Aged stock is worth pushing before it goes stale (1.6). */}
      {hasAgedStock(item) && free > 0 && (
        <Tooltip text={describeBatches(item)}>
          <span className="stock-chip stock-chip--aged">🕰 Aged stock — clear first</span>
        </Tooltip>
      )}

      {heldElsewhere > 0 && (
        <span className="reserved-note">
          {format(heldElsewhere)} {item.uom} booked by other reps
        </span>
      )}
    </span>
  );
}

function format(n: number): string {
  return (Math.round(n * 100) / 100).toLocaleString('en-IN');
}
