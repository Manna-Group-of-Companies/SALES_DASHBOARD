/**
 * The product list, for adding a line to an order.
 *
 * Sourced from the ERPNext `Item` master — around a thousand sellable items —
 * so it is a search and a set of filters rather than a dropdown. A `<select>`
 * of a thousand options is a scroll, not a choice.
 *
 * Three things a manager needs to narrow by, and each is a different question:
 *
 *   - **Category** — precured, hot rubber, gum, solution. What it *is*.
 *   - **Stock** — is it in the minimum-stock pool, and is any of it free? That
 *     decides whether the customer waits a day or a fortnight, so it is the
 *     filter that changes the answer they get given.
 *   - **Words** — the codes are long and share most of their tokens.
 *
 * Each result shows the packing figures the price depends on: belts per roll,
 * the per-belt average for precured, the exact roll weight for hot rubber.
 * They are on the row rather than a tooltip because they are what tells a
 * manager whether "20 rolls" is 600 kg or 60 kg.
 *
 * An item whose master has no weights cannot be priced — it would bill at
 * `rate x 0` and look ordinary on the proforma — so it is shown, marked, and
 * refused. Hiding it would leave someone searching for something that is there.
 */

import { useMemo, useState } from 'react';
import type { ItemOption, MinStockLine, Product, ProductCategory } from '@/domain/types';
import { CATEGORY_LABEL } from '@/domain/types';
import { isMisconfigured, rollWeight, beltWeight } from '@/domain/productRules';
import { NONE, poolByItem, runAvailable, shelfAvailable, type Qty } from '@/domain/minimumStock';
import { Badge, Empty, Input, Segmented, Select } from '@/components/ui';
import './orders.css';

/**
 * Free on the shelf — what the batch holds, less what is already booked.
 *
 * Loose belts count. An item with no whole roll left but four free belts can
 * still be sold today, and calling it "none free" would send the customer to a
 * production run they do not need to wait for.
 */
function freeOf(s: MinStockLine | undefined): Qty {
  return s ? shelfAvailable(s) : NONE;
}

/** Free on the current run — a separate pool with its own counter. */
function runOf(s: MinStockLine | undefined): Qty {
  return s ? runAvailable(s) : NONE;
}

const has = (q: Qty) => q.rolls > 0 || q.belts > 0;

function qtyLabel(q: Qty): string {
  const parts: string[] = [];
  if (q.rolls) parts.push(`${q.rolls} roll${q.rolls === 1 ? '' : 's'}`);
  if (q.belts) parts.push(`${q.belts} belt${q.belts === 1 ? '' : 's'}`);
  return parts.join(' + ') || '0';
}

/**
 * The pricing rules all speak `Product`, so the picker's `ItemOption` is
 * converted once here rather than at each of the three call sites.
 */
export function asProduct(item: ItemOption): Product {
  return {
    code: item.code,
    name: item.name,
    category: item.category,
    weightPerBelt: item.weightPerBelt,
    beltsPerRoll: item.beltsPerRoll,
    weightPerRoll: item.weightPerRoll,
    tinSize: item.packLitres === 10 || item.packLitres === 30 ? item.packLitres : undefined,
    active: true,
  };
}

function blockedReason(item: ItemOption): string | null {
  return isMisconfigured(asProduct(item));
}

/**
 * The four places a roll can come from, kept apart on purpose.
 *
 * "In minimum stock" and "on a production run" are **different pools with
 * different counters** and they answer different questions: one is on the shelf
 * today, the other arrives when the run is received. Merging them into one
 * "available" figure is how a customer gets promised same-day stock that is
 * still in the press.
 */
type Stock = 'all' | 'pooled' | 'available' | 'run' | 'make';

/** Shown at once. High enough to browse a category, low enough not to stall. */
const PAGE = 80;

export function ItemPicker({
  items,
  pool,
  loading,
  onPick,
  onClose,
}: {
  items: ItemOption[];
  /** The minimum-stock pool, for the stock filter. Empty is treated as unknown. */
  pool?: MinStockLine[];
  loading: boolean;
  onPick: (item: ItemOption) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState<ProductCategory | ''>('');
  const [stock, setStock] = useState<Stock>('all');
  const [shown, setShown] = useState(PAGE);

  const byItem = useMemo(() => poolByItem(pool ?? []), [pool]);
  const knowStock = (pool?.length ?? 0) > 0;

  /** How many items sit in each category, so the dropdown shows the shape. */
  const perCategory = useMemo(() => {
    const m = new Map<string, number>();
    for (const i of items) m.set(i.category, (m.get(i.category) ?? 0) + 1);
    return m;
  }, [items]);

  const counts = useMemo(() => {
    let pooled = 0;
    let available = 0;
    let run = 0;
    for (const i of items) {
      const s = byItem.get(i.code);
      if (!s) continue;
      pooled += 1;
      if (has(freeOf(s))) available += 1;
      if (has(runOf(s))) run += 1;
    }
    return { pooled, available, run, make: items.length - pooled };
  }, [items, byItem]);

  const results = useMemo(() => {
    let list = items;

    if (category) list = list.filter((i) => i.category === category);

    if (knowStock && stock !== 'all') {
      list = list.filter((i) => {
        const s = byItem.get(i.code);
        if (stock === 'make') return !s;
        if (!s) return false;
        if (stock === 'available') return has(freeOf(s));
        if (stock === 'run') return has(runOf(s));
        return true;
      });
    }

    const q = query.trim().toLowerCase();
    if (q) {
      // Every word must appear somewhere, so "126 eagle" narrows rather than
      // widening — these codes are long and share most of their words.
      const words = q.split(/\s+/);
      list = list.filter((i) => {
        const hay = `${i.code} ${i.name} ${i.itemGroup ?? ''} ${i.sapCode ?? ''}`.toLowerCase();
        return words.every((w) => hay.includes(w));
      });
    }
    return list;
  }, [items, category, stock, knowStock, byItem, query]);

  /** Reset paging whenever the filters change, or page 3 of nothing shows. */
  const visible = useMemo(() => results.slice(0, shown), [results, shown]);
  const narrow = (fn: () => void) => {
    fn();
    setShown(PAGE);
  };

  return (
    <div className="pick">
      <div className="pick__head">
        <Input
          autoFocus
          placeholder="Search the item master — code, name or SAP code…"
          value={query}
          onChange={(e) => narrow(() => setQuery(e.target.value))}
          aria-label="Search items"
          onKeyDown={(e) => e.key === 'Escape' && onClose()}
        />
        <button type="button" className="btn btn--ghost btn--sm" onClick={onClose}>
          Cancel
        </button>
      </div>

      <div className="pick__filters">
        <Select
          compact
          value={category}
          onChange={(e) => narrow(() => setCategory(e.target.value as ProductCategory | ''))}
          aria-label="Category"
        >
          <option value="">All categories ({items.length})</option>
          {(Object.keys(CATEGORY_LABEL) as ProductCategory[])
            .filter((c) => perCategory.get(c))
            .map((c) => (
              <option key={c} value={c}>
                {CATEGORY_LABEL[c]} ({perCategory.get(c)})
              </option>
            ))}
        </Select>

        {/*
          Only offered when the pool was actually read. With no pool loaded,
          "made to order" would label every item on the site — a filter that
          lies is worse than one that is missing.
        */}
        {knowStock && (
          <Segmented
            ariaLabel="Stock"
            value={stock}
            onChange={(v) => narrow(() => setStock(v))}
            options={[
              { value: 'all', label: `All (${items.length})` },
              { value: 'available', label: `Free on shelf (${counts.available})` },
              { value: 'pooled', label: `In minimum stock (${counts.pooled})` },
              { value: 'run', label: `On a production run (${counts.run})` },
              { value: 'make', label: `Made to order (${counts.make})` },
            ]}
          />
        )}
      </div>

      {loading && <Empty icon="◔" title="Reading the item master…" />}

      {!loading && results.length === 0 && (
        <Empty icon="—" title="No item matches">
          {items.length} sellable items were read from ERPNext. Clear the filters or the search.
        </Empty>
      )}

      {!loading && results.length > 0 && (
        <div className="pick__list">
          {visible.map((i) => {
            const blocked = blockedReason(i);
            const perRoll = rollWeight(asProduct(i));
            const perBelt = beltWeight(asProduct(i));
            const s = byItem.get(i.code);
            const free = freeOf(s);
            const run = runOf(s);
            return (
              <button
                type="button"
                key={i.code}
                className="pick__row"
                disabled={!!blocked}
                title={blocked ?? `Add ${i.name} to this order`}
                onClick={() => !blocked && onPick(i)}
              >
                <span className="pick__name">
                  <span>{i.name}</span>
                  <span className="tiny dim mono">
                    {i.itemGroup ?? '—'}
                    {i.sapCode ? ` · SAP ${i.sapCode}` : ''}
                  </span>

                  {/*
                    The stock position, spelled out rather than left to a badge.
                    This is what decides whether the customer is told "tomorrow"
                    or "next fortnight", so the manager should not have to open
                    the stock screen in another tab to find it.

                    Read from the pool's stored counters. The line's own view,
                    once the item is on the order, reconciles those counters
                    against the live reservation rows — this is a browse, and a
                    stored counter over-books at worst, never under-books.
                  */}
                  {knowStock && s && (
                    <span className="tiny dim num pick__stock">
                      shelf {qtyLabel({ rolls: s.shelfRolls, belts: s.shelfBelts })} · booked{' '}
                      {qtyLabel({ rolls: s.reservedRolls, belts: s.reservedBelts })} · minimum{' '}
                      {s.minimumRolls}
                      {has(run) ? ` · on a run ${qtyLabel(run)}` : ''}
                    </span>
                  )}
                </span>
                <span className="pick__facts">
                  <Badge tone="neutral">{i.category}</Badge>

                  {/* Where it would come from, at the moment of choosing. */}
                  {knowStock &&
                    (s ? (
                      <Badge
                        tone={has(free) ? 'ok' : has(run) ? 'info' : 'warn'}
                        title={
                          has(free)
                            ? `${qtyLabel(free)} free on the shelf, ready to reserve now`
                            : has(run)
                              ? `Nothing free on the shelf. ${qtyLabel(run)} on the current production run — available when the run is received.`
                              : 'In the minimum-stock pool, but every roll on the shelf is already booked'
                        }
                      >
                        {has(free)
                          ? `${qtyLabel(free)} free`
                          : has(run)
                            ? 'on a run'
                            : 'none free'}
                      </Badge>
                    ) : (
                      <Badge tone="neutral" title="Not stocked — this line would be made to order">
                        to make
                      </Badge>
                    ))}

                  {blocked ? (
                    <Badge tone="warn" title={blocked}>
                      no weights
                    </Badge>
                  ) : i.category === 'VS' ? (
                    <span className="tiny dim">{i.packLitres} L tin</span>
                  ) : i.category === 'BG' ? (
                    <span className="tiny dim">by the kg</span>
                  ) : (
                    <span className="tiny dim num">
                      {i.beltsPerRoll ? `${i.beltsPerRoll} belts/roll · ` : ''}
                      {perRoll ? `${perRoll} kg/roll` : ''}
                      {perBelt && i.category === 'PCTR' ? ` · ${perBelt} kg/belt (avg)` : ''}
                    </span>
                  )}
                </span>
              </button>
            );
          })}
        </div>
      )}

      {!loading && results.length > visible.length && (
        <button
          type="button"
          className="btn btn--ghost btn--sm pick__more"
          onClick={() => setShown((n) => n + PAGE)}
        >
          Show {Math.min(PAGE, results.length - visible.length)} more — {visible.length} of{' '}
          {results.length}
        </button>
      )}

      {!loading && results.length > 0 && (
        <p className="note pick__foot">
          Showing {visible.length} of {results.length} matching, from {items.length} sellable items.
          An item marked “no weights” has nothing in its master to price against — it would bill at
          zero, so it cannot be added until the master is fixed.
        </p>
      )}
    </div>
  );
}
