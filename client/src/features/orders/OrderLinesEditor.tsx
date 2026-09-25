/**
 * Add, remove and requantify an order's lines.
 *
 * Lifted out of the order review on 24 September 2026 so the GM's review
 * could use the very same editor: the GM edits escalated orders before
 * deciding them, and two copies of the rolls-and-belts arithmetic would be
 * two places for a quantity to be priced differently.
 *
 * Saving replaces the order's lines. `Api.sales.saveOrderLines` re-checks the
 * order as stored, sends it back for a decision because the money changed,
 * and — since the same date — keeps an order that is with the GM with the GM.
 */

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import type { ItemOption, MinStockLine, OrderDetail } from '@/domain/types';
import { orderLineValues } from '@/domain/productRules';
import { Api, type OrderLineWrite } from '@/api/client';
import { Button, Card, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { ItemPicker, asProduct } from './ItemPicker';

interface Draft {
  id?: string;
  item: ItemOption;
  rolls: number;
  looseBelts: number;
  kg: number;
  tins: number;
  ratePerKg: number;
  fulfilmentMode: string;
  removed: boolean;
}

export function OrderLinesEditor({
  order,
  pool,
  lockedReason,
  openNote,
  disabled,
  onEditingChange,
  onSaved,
  onError,
}: {
  order: OrderDetail;
  /** What SAP has available, for the item picker. */
  pool: MinStockLine[];
  /** Why the lines cannot be changed, or null when they can. */
  lockedReason: ReactNode | null;
  /** Said beside the button when they can. */
  openNote: string;
  /** Another action on the page is running. */
  disabled: boolean;
  /** The page's decision waits while lines are being edited. */
  onEditingChange: (editing: boolean) => void;
  /** Saved; the page reloads, because the returned order carries nothing else that moved. */
  onSaved: () => void;
  onError: (message: string | null) => void;
}) {
  const [items, setItems] = useState<ItemOption[]>([]);
  const [itemsLoading, setItemsLoading] = useState(false);
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);

  // A reload or a decision is a different order on screen; an edit begun
  // against the old one must not be saved over it.
  useEffect(() => {
    setDrafts(null);
    setPicking(false);
  }, [order]);

  const editing = drafts !== null;
  useEffect(() => {
    onEditingChange(editing);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editing]);

  const loadItems = async (): Promise<ItemOption[]> => {
    if (items.length) return items;
    setItemsLoading(true);
    try {
      const list = await Api.sales.listItemOptions();
      setItems(list);
      return list;
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not read the item master.');
      return [];
    } finally {
      setItemsLoading(false);
    }
  };

  const startEditing = async () => {
    const master = await loadItems();
    const byCode = new Map(master.map((i) => [i.code, i]));
    const next: Draft[] = [];
    const orphans: string[] = [];
    for (const l of order.lines) {
      const item = byCode.get(l.itemCode);
      if (!item) {
        orphans.push(l.itemCode);
        continue;
      }
      next.push({
        id: l.id,
        item,
        rolls: l.rolls,
        looseBelts: l.looseBelts,
        kg: item.category === 'BG' ? l.totalWeight : 0,
        tins: item.category === 'VS' ? l.qty : 0,
        ratePerKg: l.ratePerKg,
        fulfilmentMode: l.fulfilmentMode ?? '',
        removed: false,
      });
    }
    if (orphans.length) {
      onError(
        `${orphans.length} line(s) could not be opened for editing because their item is missing or disabled in the master: ${orphans.join(', ')}. Editing here would drop them, so the editor was not opened.`,
      );
      return;
    }
    setDrafts(next);
  };

  const saveLines = async () => {
    if (!drafts) return;
    const kept = drafts.filter((d) => !d.removed);
    if (kept.length === 0) {
      onError('An order needs at least one line. Reject the order instead of emptying it.');
      return;
    }
    setBusy(true);
    onError(null);
    try {
      const lines: OrderLineWrite[] = kept.map((d) => {
        const v = orderLineValues(asProduct(d.item), {
          rolls: d.rolls,
          looseBelts: d.looseBelts,
          kg: d.kg,
          tins: d.tins,
          ratePerKg: d.ratePerKg,
        });
        return {
          id: d.id,
          itemCode: d.item.code,
          category: d.item.category,
          rolls: d.rolls,
          looseBelts: d.looseBelts,
          ratePerKg: d.ratePerKg,
          /*
           * The item's OWN stock UOM, never one derived from its category.
           *
           * `uomFor('VS')` returns "L", which is a fine label for a person but
           * is not a UOM record on this site — the vulcanising solution items
           * carry `stock_uom: "Litre"`. Writing "L" made ERPNext reject the
           * entire save with "Could not find Row #2: UOM: L", so a manager
           * could not change a quantity on any order containing solution.
           *
           * An item's own stock UOM is always valid by construction, so this
           * cannot drift again when a new family is added.
           */
          uom: d.item.uom,
          fulfilmentMode: d.fulfilmentMode,
          ...v,
        };
      });
      await Api.sales.saveOrderLines({ orderId: order.id, lines });
      setDrafts(null);
      onSaved();
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not save the lines.');
    } finally {
      setBusy(false);
    }
  };

  const patch = (idx: number, change: Partial<Draft>) =>
    setDrafts((cur) => cur?.map((d, i) => (i === idx ? { ...d, ...change } : d)) ?? cur);

  const addItem = (item: ItemOption) => {
    setPicking(false);
    setDrafts((cur) => [
      ...(cur ?? []),
      {
        item,
        rolls: item.category === 'PCTR' || item.category === 'CTR' ? 1 : 0,
        looseBelts: 0,
        kg: item.category === 'BG' ? 5 : 0,
        tins: item.category === 'VS' ? 1 : 0,
        ratePerKg: 0,
        fulfilmentMode: '',
        removed: false,
      },
    ]);
  };

  const draftTotal = useMemo(() => {
    if (!drafts) return 0;
    return drafts
      .filter((d) => !d.removed)
      .reduce(
        (sum, d) =>
          sum +
          orderLineValues(asProduct(d.item), {
            rolls: d.rolls,
            looseBelts: d.looseBelts,
            kg: d.kg,
            tins: d.tins,
            ratePerKg: d.ratePerKg,
          }).amount,
        0,
      );
  }, [drafts]);

  if (!drafts) {
    return (
      <div className="line__edit-bar">
        {lockedReason ? (
          <span className="note">{lockedReason}</span>
        ) : (
          <>
            <Button
              size="sm"
              variant="ghost"
              onClick={startEditing}
              loading={itemsLoading}
              disabled={disabled}
            >
              Add / Remove / Requantify
            </Button>
            <span className="note grow">{openNote}</span>
          </>
        )}
      </div>
    );
  }

  return (
    <>
      <Card title="Editing lines" flush>
        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr>
                <th>Item</th>
                <th className="right">Quantity</th>
                <th className="right">Weight</th>
                <th className="right">Rate / kg</th>
                <th className="right">Amount</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {drafts.map((d, i) => {
                const v = orderLineValues(asProduct(d.item), {
                  rolls: d.rolls,
                  looseBelts: d.looseBelts,
                  kg: d.kg,
                  tins: d.tins,
                  ratePerKg: d.ratePerKg,
                });
                return (
                  <tr
                    key={d.id ?? `new-${i}`}
                    className={d.removed ? 'line--removed' : d.id ? '' : 'line--dirty'}
                  >
                    <td>
                      <div>{d.item.name}</div>
                      <div className="mono tiny dim">
                        {d.item.category}
                        {d.item.beltsPerRoll ? ` · ${d.item.beltsPerRoll} belts/roll` : ''}
                        {d.item.weightPerRoll ? ` · ${d.item.weightPerRoll} kg/roll` : ''}
                      </div>
                    </td>
                    <td>
                      <div className="line__qty">
                        {(d.item.category === 'PCTR' || d.item.category === 'CTR') && (
                          <>
                            <label htmlFor={`rolls-${i}`}>Rolls</label>
                            <Input
                              id={`rolls-${i}`}
                              numeric
                              compact
                              type="number"
                              min={0}
                              disabled={d.removed}
                              value={d.rolls}
                              onChange={(e) => patch(i, { rolls: Number(e.target.value) || 0 })}
                            />
                          </>
                        )}
                        {d.item.category === 'PCTR' && (
                          <>
                            <label htmlFor={`belts-${i}`}>Belts</label>
                            <Input
                              id={`belts-${i}`}
                              numeric
                              compact
                              type="number"
                              min={0}
                              disabled={d.removed}
                              value={d.looseBelts}
                              onChange={(e) =>
                                patch(i, { looseBelts: Number(e.target.value) || 0 })
                              }
                            />
                          </>
                        )}
                        {d.item.category === 'BG' && (
                          <>
                            <label htmlFor={`kg-${i}`}>Kg</label>
                            <Input
                              id={`kg-${i}`}
                              numeric
                              compact
                              type="number"
                              min={0}
                              step={5}
                              disabled={d.removed}
                              value={d.kg}
                              onChange={(e) => patch(i, { kg: Number(e.target.value) || 0 })}
                            />
                          </>
                        )}
                        {d.item.category === 'VS' && (
                          <>
                            <label htmlFor={`tins-${i}`}>Tins</label>
                            <Input
                              id={`tins-${i}`}
                              numeric
                              compact
                              type="number"
                              min={0}
                              disabled={d.removed}
                              value={d.tins}
                              onChange={(e) => patch(i, { tins: Number(e.target.value) || 0 })}
                            />
                          </>
                        )}
                      </div>
                    </td>
                    <td className="right num">{v.totalWeight} kg</td>
                    <td className="right">
                      <Input
                        numeric
                        compact
                        type="number"
                        min={0}
                        step="0.01"
                        disabled={d.removed}
                        aria-label={`Rate for ${d.item.name}`}
                        value={d.ratePerKg}
                        onChange={(e) => patch(i, { ratePerKg: Number(e.target.value) || 0 })}
                      />
                    </td>
                    <td className="right num">{money(v.amount, 0)}</td>
                    <td>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => patch(i, { removed: !d.removed })}
                      >
                        {d.removed ? 'Undo' : 'Remove'}
                      </Button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Card>

      {picking && (
        <ItemPicker
          items={items}
          pool={pool}
          loading={itemsLoading}
          onPick={addItem}
          onClose={() => setPicking(false)}
        />
      )}

      <div className="line__edit-bar">
        <Button size="sm" variant="ghost" onClick={() => setPicking((p) => !p)}>
          {picking ? 'Close list' : '+ Add item'}
        </Button>
        <span className="grow" />
        <span className="note">
          New total <b>{money(draftTotal, 0)}</b>, was {money(order.total, 0)}
        </span>
        <Button onClick={saveLines} loading={busy} disabled={disabled || busy}>
          Save lines
        </Button>
        <Button
          variant="ghost"
          onClick={() => {
            setDrafts(null);
            setPicking(false);
          }}
          disabled={disabled || busy}
        >
          Cancel
        </Button>
      </div>
      <p className="note">
        Saving replaces the order's lines — anything marked Remove is deleted. Because the money
        changes, the order goes back for a decision and every rate reopens.
      </p>
    </>
  );
}
