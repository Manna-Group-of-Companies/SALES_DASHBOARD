/**
 * Minimum stock, as the sales side needs to read it.
 *
 * Deliberately a different screen from the production manager's, because it
 * answers a different question. Production asks *what should we make next*, so
 * theirs is ordered by how badly a pool needs a run. Sales asks *what can I
 * promise*, so this one leads with what is free to sell.
 *
 * It answered "and what should I clear first" too until 21 August 2026, with
 * an Age column, an Aging filter and an oldest-first sort. That was the
 * dead-stock feature and it has been removed — the dated batches still exist
 * in ERPNext and still add up to what is on the shelf, but nobody is asked to
 * make a decision about how old they are. The column that replaced Age is the
 * **minimum** the pool is meant to hold, which is what this screen is for.
 *
 * That minimum is shown here and **not** on the reps' phones. See
 * `app/lib/screens/orders/min_stock_screen.dart`: it is management's figure,
 * and a rep quoting it to a customer describes how the company runs its shelf
 * rather than what they can sell.
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

type Filter = 'sellable' | 'coming' | 'none_left' | 'all';

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
          phantom: s.reservedRolls - actual.rolls,
        };
      }),
    [pool, reservations, reservationsLoaded, now],
  );

  const counts = useMemo(
    () => ({
      sellable: rowsWithTruth.filter((r) => r.free.rolls > 0 || r.free.belts > 0).length,
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
    if (filter === 'coming') list = list.filter((r) => r.s.inProductionRolls > 0);
    if (filter === 'none_left') list = list.filter((r) => fullyBooked(r.s));

    if (quality) list = list.filter((r) => parseItemName(r.s.itemCode).quality === quality);
    if (pattern) list = list.filter((r) => parseItemName(r.s.itemCode).pattern === pattern);

    const q = query.trim().toLowerCase();
    if (q) list = list.filter((r) => r.s.itemCode.toLowerCase().includes(q));

    /*
     * By name, because the reader is looking something up. This sorted oldest
     * first until 21 August 2026, when the dead-stock feature was removed:
     * ordering the list by an age nobody is shown ranks it against a rule the
     * reader cannot see.
     */
    return [...list].sort((a, b) => a.s.itemCode.localeCompare(b.s.itemCode));
  }, [rowsWithTruth, filter, quality, pattern, query]);

  const totals = useMemo(
    () => ({
      free: rowsWithTruth.reduce((n, r) => n + r.free.rolls, 0),
      coming: rowsWithTruth.reduce((n, r) => n + r.s.inProductionRolls, 0),
      minimum: rowsWithTruth.reduce((n, r) => n + r.s.minimumRolls, 0),
    }),
    [rowsWithTruth],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Minimum stock</div>
          <div className="page-head__sub">
            What is free to sell, and what is already spoken for
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
                'Loose belts on the shelf': r.s.shelfBelts,
                'Booked by reps': r.s.reservedRolls,
                'Loose belts booked': r.s.reservedBelts,
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
          label="Minimum held"
          value={String(totals.minimum)}
          foot="Rolls the shelf is meant to hold"
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
                  <th className="right">Minimum</th>
                  <th>Being made</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const p = parseItemName(r.s.itemCode);
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
                      {/*
                        Belts alongside the rolls on both of these, since
                        21 August 2026. "Free to sell" above always carried
                        them and these two did not, so a pool with twelve
                        rolls and twelve belts booked against it read as
                        twelve booked — and the belts were unaccounted for
                        exactly where somebody would go looking for them.
                      */}
                      <td className="right num dim">
                        {r.s.shelfRolls}
                        {r.s.shelfBelts ? ` + ${r.s.shelfBelts} belts` : ''}
                      </td>
                      <td className="right num dim">
                        {r.s.reservedRolls}
                        {r.s.reservedBelts ? ` + ${r.s.reservedBelts} belts` : ''}
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
                      {/*
                        What the shelf is meant to hold. This column was the
                        batch's age until 21 August 2026; the dead-stock
                        feature it belonged to was removed, and the minimum is
                        what this screen is actually for. It is shown here and
                        deliberately NOT on the reps' phones — see
                        app/lib/screens/orders/min_stock_screen.dart.
                      */}
                      <td className="right num dim">{r.s.minimumRolls}</td>
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
          counted as free to sell. “Minimum” is the level this pool is meant to hold, and is not
          shown to reps on their phones.
        </p>
      )}
    </div>
  );
}
