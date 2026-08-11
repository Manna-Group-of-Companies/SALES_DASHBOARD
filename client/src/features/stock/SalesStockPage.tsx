/**
 * Minimum stock, as the sales side needs to read it.
 *
 * Deliberately a different screen from the production manager's, because it
 * answers a different question. Production asks *what should we make next*, so
 * theirs is ordered by how badly a pool needs a run. Sales asks *what can I
 * promise, and what should I clear first*, so this one leads with what is free
 * to sell and orders by stock age — old rubber goes out before new.
 *
 * It is **read-only**. Recording a run, moving its stage and receiving it are
 * production's decisions, and putting the controls on two screens would be two
 * places to change the same number.
 *
 * The one thing carried over verbatim from the production screen is the rule
 * about runs: a run in flight is **intent, not stock**. It gets its own line
 * and never joins the free figure — two numbers in one sentence, one sellable
 * and one not, is how a rep promises stock nobody has made.
 */

import { useEffect, useMemo, useState } from 'react';
import type { MinStockLine, StockReservationRow } from '@/domain/types';
import {
  daysInStock,
  fullyBooked,
  shelfAvailable,
  trueReserved,
} from '@/domain/minimumStock';
import { parseItemName, distinctOf, worthOffering } from '@/domain/itemNaming';
import { serverNow } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { ExportButton } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/features/orders/orders.css';
import '@/features/production/production.css';

type Filter = 'sellable' | 'aging' | 'coming' | 'none_left' | 'all';

/**
 * Stock sitting this long is worth clearing before newer rubber.
 *
 * A month is the business threshold, not a derived one. Note that every batch
 * on the site currently carries the same import date (2026-06-30), so this
 * filter cannot discriminate between pools yet — the screen says so rather
 * than leaving a filter that looks broken. The oldest-first sort is the part
 * that works today and keeps working once batches differ.
 */
const AGING_DAYS = 30;

export function SalesStockPage() {
  const user = useAppSelector(selectUser);

  const [pool, setPool] = useState<MinStockLine[]>([]);
  const [reservations, setReservations] = useState<StockReservationRow[]>([]);
  const [reservationsLoaded, setReservationsLoaded] = useState(true);
  const [filter, setFilter] = useState<Filter>('sellable');
  const [quality, setQuality] = useState('');
  const [pattern, setPattern] = useState('');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.sales
      .listMinimumStock()
      .then(async (p) => {
        if (!live) return;
        setPool(p);
        try {
          const res = await Api.sales.listReservations();
          if (!live) return;
          setReservations(res);
          setReservationsLoaded(true);
        } catch {
          // Fall back to the stored counters rather than reading "no rows" as
          // "nothing is booked" and over-promising the whole shelf.
          if (live) setReservationsLoaded(false);
        }
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read minimum stock.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const now = useMemo(() => serverNow(), [tick]);

  /**
   * Each pool with its booked figure reconciled against the reservation rows.
   *
   * The stored counter has been proven wrong on this site — an order deleted
   * in the Desk left two pools claiming bookings with nothing behind them — so
   * the rows win where they are available.
   */
  const rowsWithTruth = useMemo(
    () =>
      pool.map((s) => {
        const actual = reservationsLoaded
          ? trueReserved(reservations, s.itemCode)
          : { rolls: s.reservedRolls, belts: s.reservedBelts };
        const reconciled: MinStockLine = {
          ...s,
          reservedRolls: actual.rolls,
          reservedBelts: actual.belts,
        };
        return {
          s: reconciled,
          free: shelfAvailable(reconciled),
          age: daysInStock(s.batchDate, now),
          phantom: s.reservedRolls - actual.rolls,
        };
      }),
    [pool, reservations, reservationsLoaded, now],
  );

  const counts = useMemo(
    () => ({
      sellable: rowsWithTruth.filter((r) => r.free.rolls > 0 || r.free.belts > 0).length,
      aging: rowsWithTruth.filter((r) => (r.age ?? 0) >= AGING_DAYS && r.free.rolls > 0).length,
      coming: rowsWithTruth.filter((r) => r.s.inProductionRolls > 0).length,
      noneLeft: rowsWithTruth.filter((r) => fullyBooked(r.s)).length,
      all: rowsWithTruth.length,
    }),
    [rowsWithTruth],
  );

  const qualities = useMemo(
    () => distinctOf(pool.map((p) => p.itemCode), (n) => n.quality),
    [pool],
  );
  const patterns = useMemo(
    () => distinctOf(pool.map((p) => p.itemCode), (n) => n.pattern),
    [pool],
  );

  const rows = useMemo(() => {
    let list = rowsWithTruth;
    if (filter === 'sellable') list = list.filter((r) => r.free.rolls > 0 || r.free.belts > 0);
    if (filter === 'aging') list = list.filter((r) => (r.age ?? 0) >= AGING_DAYS && r.free.rolls > 0);
    if (filter === 'coming') list = list.filter((r) => r.s.inProductionRolls > 0);
    if (filter === 'none_left') list = list.filter((r) => fullyBooked(r.s));

    if (quality) list = list.filter((r) => parseItemName(r.s.itemCode).quality === quality);
    if (pattern) list = list.filter((r) => parseItemName(r.s.itemCode).pattern === pattern);

    const q = query.trim().toLowerCase();
    if (q) list = list.filter((r) => r.s.itemCode.toLowerCase().includes(q));

    /*
     * Oldest first — this is the rep's ordering. Production sorts by urgency
     * because they are deciding what to make; sales sorts by age because they
     * are deciding what to shift. Pools with no batch date sort last: an
     * unknown age is not an old one.
     */
    return [...list].sort((a, b) => {
      const ax = a.age ?? -1;
      const bx = b.age ?? -1;
      if (ax !== bx) return bx - ax;
      return a.s.itemCode.localeCompare(b.s.itemCode);
    });
  }, [rowsWithTruth, filter, quality, pattern, query]);

  const totals = useMemo(
    () => ({
      free: rowsWithTruth.reduce((n, r) => n + r.free.rolls, 0),
      coming: rowsWithTruth.reduce((n, r) => n + r.s.inProductionRolls, 0),
    }),
    [rowsWithTruth],
  );

  /**
   * Whether every pool shares one batch date.
   *
   * True today: all 164 batches were imported on 2026-06-30, so every pool is
   * the same age and the aging filter cannot separate them. Saying so is
   * better than letting the filter look broken — it is the data that has not
   * moved yet, not the screen.
   */
  const uniformAge = useMemo(() => {
    const dates = new Set(pool.map((s) => s.batchDate).filter(Boolean));
    return dates.size === 1 && pool.length > 1;
  }, [pool]);

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Minimum stock</div>
          <div className="page-head__sub">
            What is free to sell, oldest stock first
          </div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`stock-${now.toISOString().slice(0, 10)}.xlsx`}
            sheet="Minimum stock"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((r) => ({
                Item: r.s.itemCode,
                'Free to sell': r.free.rolls,
                'Loose belts free': r.free.belts,
                'On the shelf': r.s.shelfRolls,
                'Booked by reps': r.s.reservedRolls,
                'Days in stock': r.age ?? '',
                'Being made': r.s.inProductionRolls,
                'Last sold': r.s.lastSoldOn ?? '',
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read minimum stock">
          {error}
        </Alert>
      )}

      {!reservationsLoaded && !loading && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title="Bookings could not be read">
            The figures below use ERPNext's stored booked counts, which have been wrong before.
            Treat “free to sell” as the lowest it could be, not the highest.
          </Alert>
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Free to sell" value={String(totals.free)} tone="ok" foot="Rolls, across all pools" />
        <Tile
          label="Aging"
          value={String(counts.aging)}
          tone={counts.aging ? 'warn' : undefined}
          foot={`Sellable, ${AGING_DAYS}+ days old`}
        />
        <Tile
          label="Nothing left"
          value={String(counts.noneLeft)}
          tone={counts.noneLeft ? 'warn' : undefined}
          foot="Fully booked"
        />
        <Tile label="Being made" value={String(totals.coming)} foot="Rolls on a run" />
      </div>

      <div className="cal__toolbar">
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'sellable', label: `Free to sell (${counts.sellable})` },
            { value: 'aging', label: `Aging (${counts.aging})` },
            { value: 'coming', label: `Being made (${counts.coming})` },
            { value: 'none_left', label: `Nothing left (${counts.noneLeft})` },
            { value: 'all', label: `All (${counts.all})` },
          ]}
        />
        {worthOffering(qualities) && (
          <Select value={quality} onChange={(e) => setQuality(e.target.value)} aria-label="Quality">
            <option value="">All qualities</option>
            {qualities.map((q) => (
              <option key={q} value={q}>
                {q}
              </option>
            ))}
          </Select>
        )}
        {worthOffering(patterns) && (
          <Select value={pattern} onChange={(e) => setPattern(e.target.value)} aria-label="Pattern">
            <option value="">All patterns</option>
            {patterns.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </Select>
        )}
        <Input
          placeholder="Search item…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search stock"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading minimum stock…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="—" title="Nothing matches">
          {filter === 'sellable'
            ? 'Every pool is fully booked or empty.'
            : 'Try another filter, or clear the search.'}
        </Empty>
      )}

      {!loading && rows.length > 0 && (
        <Card flush>
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="right">Free to sell</th>
                  <th className="right">On the shelf</th>
                  <th className="right">Booked</th>
                  <th>Age</th>
                  <th>Being made</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const p = parseItemName(r.s.itemCode);
                  const old = (r.age ?? 0) >= AGING_DAYS;
                  return (
                    <tr key={r.s.itemCode}>
                      <td>
                        <div>{r.s.itemCode}</div>
                        {p.quality && (
                          <div className="tiny dim">
                            {p.quality}
                            {p.width ? ` · ${p.width}` : ''}
                            {p.pattern ? ` · ${p.pattern}` : ''}
                          </div>
                        )}
                      </td>
                      <td className="right num">
                        {r.free.rolls > 0 || r.free.belts > 0 ? (
                          <b className="ok">
                            {r.free.rolls}
                            {r.free.belts ? ` + ${r.free.belts} belts` : ''}
                          </b>
                        ) : (
                          <Badge tone="warn">none</Badge>
                        )}
                      </td>
                      <td className="right num dim">{r.s.shelfRolls}</td>
                      <td className="right num dim">
                        {r.s.reservedRolls}
                        {/* A counter claiming more booked than any reservation
                            supports means an order was deleted without
                            releasing its hold. The stock is really free. */}
                        {r.phantom > 0 && (
                          <div
                            className="tiny danger"
                            title="ERPNext still counts these as booked with no reservation behind them. The free figure ignores it."
                          >
                            ⚠ {r.phantom} phantom
                          </div>
                        )}
                      </td>
                      <td className="small">
                        {r.age == null ? (
                          <span className="dim">—</span>
                        ) : old ? (
                          <Badge tone="warn" title="Clear this before newer stock">
                            {r.age} days
                          </Badge>
                        ) : (
                          <span className="dim">{r.age} days</span>
                        )}
                      </td>
                      <td className="small">
                        {r.s.inProductionRolls > 0 ? (
                          /* Its own column, never added to "free to sell". */
                          <span className="run__note">🏭 {r.s.inProductionRolls} coming</span>
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      {!loading && rows.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          “Being made” is a production run raised in SAP — it is <b>not on the shelf</b> and is never
          counted as free to sell. Oldest stock is listed first so it clears before newer rubber.
          {uniformAge && (
            <>
              {' '}
              Every pool currently shares one batch date, so all stock is the same age and the Aging
              filter cannot separate them yet — it will once goods are booked in on different dates.
            </>
          )}
        </p>
      )}
    </div>
  );
}
