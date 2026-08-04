/**
 * Aged minimum stock, offered as a substitution (1.6, 2.1).
 *
 * The bar under each item is the dated-batch split the spec asks to be visible:
 * a rep can see at a glance that most of an item is old stock and, after
 * checking with the customer, swap the requested product for it.
 */

import type { MinStockItem, StockBatch } from '@/domain/types';
import {
  AGE_BAND_LABEL,
  ageBand,
  agingPriorityList,
  batchAgeDays,
  describeBatches,
  sortedByAge,
} from '@/domain/aging';
import { Badge, Button, Empty } from '@/components/ui';

export function BatchBar({ batches }: { batches: StockBatch[] }) {
  const live = sortedByAge(batches);
  const total = live.reduce((s, b) => s + b.remaining, 0);
  if (total <= 0) return null;

  return (
    <div className="batch-bar" aria-hidden>
      {live.map((b) => (
        <div
          key={b.id}
          className={`batch-bar__seg batch-bar__seg--${ageBand(b)}`}
          style={{ width: `${(b.remaining / total) * 100}%` }}
          title={`${b.remaining} from ${b.stockedOn} — ${batchAgeDays(b)} days old`}
        />
      ))}
    </div>
  );
}

export function AgingPanel({
  items,
  onSubstitute,
  title = 'Aged stock — offer these first',
  emptyHint = 'Nothing has been sitting long enough to prioritise.',
}: {
  items: MinStockItem[];
  /** Omit to render the list read-only. */
  onSubstitute?: (item: MinStockItem) => void;
  title?: string;
  emptyHint?: string;
}) {
  const priority = agingPriorityList(items);

  if (!priority.length) {
    return <Empty icon="🕰" title="No aged stock" children={emptyHint} />;
  }

  return (
    <div>
      <p className="small muted" style={{ marginBottom: 10 }}>
        {title}
      </p>
      {priority.map(({ item, agedQty, oldestDays }) => {
        const oldest = sortedByAge(item.batches)[0];
        return (
          <div key={item.itemCode} className="aging-item">
            <div className="row gap-2">
              <span className="aging-item__name grow">{item.itemName}</span>
              <Badge tone={oldestDays >= 120 ? 'danger' : 'warn'}>
                {AGE_BAND_LABEL[oldest ? ageBand(oldest) : 'fresh']} · {oldestDays}d
              </Badge>
            </div>

            <div className="aging-item__batches">{describeBatches(item)}</div>
            <BatchBar batches={item.batches} />

            <div className="row gap-2" style={{ marginTop: 8 }}>
              <span className="tiny dim grow">
                {round(agedQty)} {item.uom} aged of {round(item.onHand)} {item.uom} on hand
              </span>
              {onSubstitute && (
                <Button size="sm" onClick={() => onSubstitute(item)}>
                  Offer instead
                </Button>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
