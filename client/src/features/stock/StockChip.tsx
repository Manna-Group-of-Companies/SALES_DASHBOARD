/**
 * The stock indicator that sits on every product row.
 *
 * Three states, and keeping them apart is the whole job:
 *
 *   - **No stock record.** SAP holds nothing under this code. Reads "No stock
 *     record", never a zero — a zero would be read as "out of stock", which is
 *     a different and much more alarming thing.
 *   - **Weights not set.** SAP holds it in kilograms and the item master has
 *     no weight-per-roll or belts-per-roll, so nobody can say how many rolls
 *     that is. Reported as not set up, on instruction, while the weights are
 *     loaded for the rest of the catalogue.
 *   - **A figure.** What can be promised.
 *
 * `available` is passed in rather than derived when the caller has a better
 * answer — on the order screen the number that matters is what is free to this
 * line, which may differ from the row's own.
 *
 * A "booked by other reps" line sat under the chip until 17 September 2026. It
 * came from ERPNext's own reservation counter, and it is gone with it: SAP has
 * already taken every open order off the figure above, so naming a booked
 * quantity beside it would invite the rep to subtract it twice.
 */

import type { MinStockLine } from '@/domain/types';
import { shelfAvailable } from '@/domain/minimumStock';

export function StockChip({
  item,
  available,
  uom = 'rolls',
}: {
  item?: MinStockLine;
  available?: number;
  uom?: string;
}) {
  if (!item) {
    return <span className="stock-chip stock-chip--none">No stock record</span>;
  }

  if (!item.weightsKnown) {
    return (
      <span className="stock-chip stock-chip--none" title="No weight per roll or belts per roll on the item master">
        Stock not set up
      </span>
    );
  }

  const free = available ?? shelfAvailable(item).rolls;
  const tone = free <= 0 ? 'out' : 'ok';
  const label = free <= 0 ? 'None left' : `${format(free)} ${uom} available`;

  return (
    <span className="stack gap-1" style={{ alignItems: 'flex-start' }}>
      <span className={`stock-chip stock-chip--${tone}`}>{label}</span>
    </span>
  );
}

function format(n: number): string {
  return (Math.round(n * 100) / 100).toLocaleString('en-IN');
}
