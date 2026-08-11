/**
 * The Stock Manager's landing page.
 *
 * The undispatched total *is* shown here, deliberately. It is kept off
 * rep-facing screens because a rep who sees stock on the shelf will promise it,
 * and booked stock is still physically there until it ships. A Stock Manager is
 * a different audience: knowing what is on the floor versus what is still free
 * to sell is the whole job.
 *
 * Three numbers, and they mean different things:
 *
 *   - **threshold** — what *should* be on the shelf. A target, not a level.
 *   - **on hand**   — what *is* there, across every dated batch.
 *   - **available** — on hand less everyone's holds; what can still be promised.
 *
 * Restocking adds a batch and never edits the threshold, so on-hand and
 * threshold diverge the moment stock arrives. Reading one for the other is the
 * mistake this page is laid out to prevent.
 *
 * Summarise and navigate, never decide: replenishment is raised on the
 * replenishment screen, in one place.
 */

import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import type { MinStockItem } from '@/domain/types';
import { availableQty, batchAgeDays, oldestBatch, stockLevel } from '@/domain/aging';
import { formatDate, todayIso } from '@/domain/orderRules';
import { useAppSelector } from '@/store/hooks';
import {
  selectAgingList,
  selectLowStockItems,
  selectMinStockItems,
  selectReservations,
  selectUser,
} from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Meter } from '@/components/ui';
import { greeting, qty } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { plural } from './dashboardRules';
import '@/components/layout/layout.css';
import './dashboard.css';

export function StockDashboardPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const items = useAppSelector(selectMinStockItems);
  const low = useAppSelector(selectLowStockItems);
  const aging = useAppSelector(selectAgingList);
  const reservations = useAppSelector(selectReservations);

  /** Worst shortfall first — the list is worked from the top. */
  const shortfalls = useMemo(
    () =>
      [...low]
        .map((i) => ({ item: i, level: stockLevel(i), gap: i.threshold - i.onHand }))
        .sort((a, b) => a.level - b.level),
    [low],
  );

  /** On the shelf across every batch — see the note at the top of the file. */
  const undispatched = useMemo(() => items.reduce((s, i) => s + i.onHand, 0), [items]);
  const heldTotal = useMemo(() => reservations.reduce((s, r) => s + r.qty, 0), [reservations]);

  /** Items nothing can be promised from, even though stock may be on the floor. */
  const nothingFree = useMemo(
    () => items.filter((i) => availableQty(i) <= 0 && i.onHand > 0),
    [items],
  );

  const agedItems = useMemo(() => aging.filter((a) => a.agedQty > 0), [aging]);

  if (!user) return null;

  const awaitingReplenishment = shortfalls.filter((s) => !s.item.replenishmentRaised);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {greeting()}, {user.name.split(' ')[0]}
          </div>
          <div className="page-head__sub">
            {formatDate(todayIso())} · {items.length} {plural(items.length, 'item')} tracked
          </div>
        </div>
      </div>

      {/* --- what cannot wait --------------------------------------------- */}
      <div className="stack gap-3" style={{ marginBottom: 16 }}>
        {awaitingReplenishment.length > 0 && (
          <Alert
            tone="warn"
            title={`${awaitingReplenishment.length} ${plural(
              awaitingReplenishment.length,
              'item',
            )} below threshold with no replenishment raised`}
            actions={
              <Button size="sm" onClick={() => navigate('/stock/replenish')}>
                Open replenishment
              </Button>
            }
          >
            Lowest is {awaitingReplenishment[0]!.item.itemName} at{' '}
            {Math.round(awaitingReplenishment[0]!.level * 100)}% of its threshold.
          </Alert>
        )}
        {nothingFree.length > 0 && (
          <Alert tone="info" title={`${nothingFree.length} fully booked`}>
            These still have stock on the floor, but all of it is held against orders — nothing can
            be promised from them until those ship.
          </Alert>
        )}
      </div>

      {/* --- tiles -------------------------------------------------------- */}
      <div className="tiles">
        <Tile
          label="Below threshold"
          value={String(low.length)}
          tone={low.length ? 'warn' : undefined}
          foot={low.length ? `${awaitingReplenishment.length} not yet raised` : 'All above target'}
          onClick={() => navigate('/stock/replenish')}
        />
        <Tile
          label="Undispatched stock"
          value={String(Math.round(undispatched))}
          // Manager audience — this is the figure kept off rep-facing screens.
          foot="On the floor, across all batches"
          onClick={() => navigate('/stock/min')}
        />
        <Tile
          label="Held against orders"
          value={String(Math.round(heldTotal))}
          foot={`${reservations.length} ${plural(reservations.length, 'booking')}`}
          onClick={() => navigate('/stock/min')}
        />
        <Tile
          label="Aged stock"
          value={String(agedItems.length)}
          tone={agedItems.length ? 'warn' : undefined}
          foot={agedItems.length ? 'Clear these first' : 'Nothing ageing'}
          onClick={() => navigate('/stock/aging')}
        />
      </div>

      <div className="cols cols--sidebar">
        {/* --- the shortfall list ---------------------------------------- */}
        <Card
          title="Furthest below threshold"
          actions={
            <Button size="sm" variant="ghost" onClick={() => navigate('/stock/replenish')}>
              Replenishment →
            </Button>
          }
          flush
        >
          {shortfalls.length === 0 ? (
            <Empty icon="✓" title="Every item is above its threshold">
              Thresholds are what should be on the shelf, not what is — restocking adds a batch and
              leaves the threshold alone.
            </Empty>
          ) : (
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th style={{ width: 110 }}>Level</th>
                  <th className="right">On hand</th>
                  <th className="right">Free</th>
                </tr>
              </thead>
              <tbody>
                {shortfalls.slice(0, 8).map(({ item, level }) => (
                  <tr
                    key={item.itemCode}
                    onClick={() => navigate('/stock/replenish')}
                    style={{ cursor: 'pointer' }}
                  >
                    <td className="small">
                      <div>{item.itemName}</div>
                      <div className="mono tiny dim">{item.itemCode}</div>
                    </td>
                    <td>
                      <Meter
                        value={level}
                        tone={level < 0.34 ? 'danger' : 'warn'}
                        label={`${Math.round(level * 100)}% of threshold`}
                      />
                    </td>
                    <td className="right num">{qty(item.onHand, item.uom)}</td>
                    <td className="right num">{qty(availableQty(item), item.uom)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>

        {/* --- ageing ---------------------------------------------------- */}
        <Card title="Oldest on the shelf">
          {agedItems.length === 0 ? (
            <Empty icon="✓" title="Nothing has aged" />
          ) : (
            <div className="stack gap-2">
              {agedItems.slice(0, 6).map(({ item, agedQty: aged }) => (
                <button
                  key={item.itemCode}
                  className="linkrow"
                  onClick={() => navigate('/stock/aging')}
                >
                  <span className="small">{item.itemName}</span>
                  <span className="small dim">{qty(aged, item.uom)} aged</span>
                  <Badge tone="warn">{ageOf(item)}</Badge>
                </button>
              ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

/** Age of the oldest live batch, for the chip on the ageing list. */
function ageOf(item: MinStockItem): string {
  const oldest = oldestBatch(item);
  return oldest ? `${batchAgeDays(oldest)}d` : '—';
}
