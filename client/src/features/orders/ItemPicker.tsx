/**
 * The product list, for adding a line to an order.
 *
 * Sourced from the ERPNext `Item` master — 1,092 sellable items — so a search
 * box rather than a dropdown. A `<select>` of a thousand options is a scroll,
 * not a choice.
 *
 * Each result shows the packing figures the price depends on: belts per roll,
 * the per-belt average for precured, the exact roll weight for hot rubber.
 * They are on the row rather than a tooltip because they are what tells a
 * manager whether "20 rolls" is 600 kg or 60 kg, and that is the difference
 * they are actually deciding.
 *
 * An item whose master has no weights cannot be priced — it would bill at
 * `rate x 0` and look ordinary on the proforma — so it is shown, marked, and
 * refused. Hiding it would leave the manager searching for something that is
 * there.
 */

import { useMemo, useState } from 'react';
import type { ItemOption, Product } from '@/domain/types';
import { isMisconfigured, rollWeight, beltWeight } from '@/domain/productRules';
import { Badge, Empty, Input } from '@/components/ui';
import './orders.css';

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

export function ItemPicker({
  items,
  loading,
  onPick,
  onClose,
}: {
  items: ItemOption[];
  loading: boolean;
  onPick: (item: ItemOption) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState('');

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return items.slice(0, 40);
    const words = q.split(/\s+/);
    // Every word has to appear somewhere, so "126 eagle" narrows rather than
    // widening — these codes are long and share most of their words.
    return items
      .filter((i) => {
        const hay = `${i.code} ${i.name} ${i.itemGroup ?? ''} ${i.sapCode ?? ''}`.toLowerCase();
        return words.every((w) => hay.includes(w));
      })
      .slice(0, 60);
  }, [items, query]);

  return (
    <div className="pick">
      <div className="pick__head">
        <Input
          autoFocus
          placeholder="Search the item master — code, name or SAP code…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search items"
          onKeyDown={(e) => e.key === 'Escape' && onClose()}
        />
        <button type="button" className="btn btn--ghost btn--sm" onClick={onClose}>
          Cancel
        </button>
      </div>

      {loading && <Empty icon="◔" title="Reading the item master…" />}

      {!loading && results.length === 0 && (
        <Empty icon="—" title="No item matches">
          {items.length} sellable items were read from ERPNext.
        </Empty>
      )}

      {!loading && results.length > 0 && (
        <div className="pick__list">
          {results.map((i) => {
            const blocked = blockedReason(i);
            const perRoll = rollWeight(asProduct(i));
            const perBelt = beltWeight(asProduct(i));
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
                </span>
                <span className="pick__facts">
                  <Badge tone="neutral">{i.category}</Badge>
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

      {!loading && (
        <p className="note pick__foot">
          Showing {results.length} of {items.length}. An item marked “no weights” has nothing in
          its master to price against — it would bill at zero, so it cannot be added until the
          master is fixed.
        </p>
      )}
    </div>
  );
}
