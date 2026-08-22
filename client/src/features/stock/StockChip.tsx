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
import { availableQty } from '@/domain/stockLevels';

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

  /*
   * The chip carried a dated-batch breakdown in its tooltip and an
   * "Aged stock — clear first" badge beside it until 21 August 2026. Both
   * went with the dead-stock feature. What is free to sell is the whole
   * point of the chip and is unchanged.
   */
  return (
    <span className="stack gap-1" style={{ alignItems: 'flex-start' }}>
      <span className={`stock-chip stock-chip--${tone}`}>
        {tone === 'low' && '⚠ '}
        {label}
      </span>

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
