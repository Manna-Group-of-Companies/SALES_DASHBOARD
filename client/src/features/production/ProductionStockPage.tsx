/**
 * §4.1 — The production manager's minimum-stock screen.
 *
 * Ordered by how badly a pool needs a run, not by stock age — age is the rep's
 * ordering, because they are clearing old rubber; this reader is deciding what
 * to make next.
 *
 * **Two alarms, and they do not fire together:**
 *
 *   - *Below minimum* — the shelf is under the level to hold. A run is owed.
 *   - *Fully booked* — nothing left to promise. This fires at exactly the
 *     minimum, while the quantity still looks right, and it is the one
 *     describing reps being turned away right now.
 *
 * **The shortfall is measured against the shelf, never against what is left to
 * sell.** Ten on the shelf with eight booked leaves two to sell, but all ten
 * exist and are waiting to go out — ordering eight more builds the same goods
 * twice.
 *
 * **No booking attribution.** Production is never told which customer an order
 * is for, so bookings are counts only.
 */

import { useEffect, useMemo, useState } from 'react';
import type { MinStockLine } from '@/domain/types';
import {
  belowMinimum,
  byUrgency,
  fullyBooked,
  needsRun,
  runAvailable,
  shelfAvailable,
  shortfall,
  shortfallAfterRun,
  urgency,
} from '@/domain/minimumStock';
import { parseItemName, distinctOf, worthOffering } from '@/domain/itemNaming';
import { daysInStock } from '@/domain/minimumStock';
import { serverNow } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { ExportButton } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/features/orders/orders.css';
import './production.css';

type Filter = 'below' | 'booked' | 'needs_run' | 'all';

/**
 * Stages a production run moves through.
 *
 * The run is one batch, so this is the family cycle's making stages — a run is
 * never "picked off the shelf". Placeholder, like every other stage list here:
 * hold it as data.
 */
const RUN_STAGES = [
  'Not Started',
  'Compound Mixing',
  'Extrusion',
  'Curing',
  'Trimming',
  'Quality Check',
  'Packed',
];

export function ProductionStockPage() {
  const user = useAppSelector(selectUser);

  const [pool, setPool] = useState<MinStockLine[]>([]);
  const [filter, setFilter] = useState<Filter>('below');
  const [quality, setQuality] = useState('');
  const [pattern, setPattern] = useState('');
  const [query, setQuery] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [runRolls, setRunRolls] = useState(0);
  const [runBelts, setRunBelts] = useState(0);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.sales
      .listMinimumStock()
      .then((p) => {
        if (live) setPool(p);
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

  const counts = useMemo(
    () => ({
      below: pool.filter(belowMinimum).length,
      booked: pool.filter(fullyBooked).length,
      needsRun: pool.filter(needsRun).length,
      all: pool.length,
    }),
    [pool],
  );

  const qualities = useMemo(() => distinctOf(pool.map((p) => p.itemCode), (n) => n.quality), [pool]);
  const patterns = useMemo(() => distinctOf(pool.map((p) => p.itemCode), (n) => n.pattern), [pool]);

  const rows = useMemo(() => {
    let list = pool;
    if (filter === 'below') list = list.filter(belowMinimum);
    if (filter === 'booked') list = list.filter(fullyBooked);
    if (filter === 'needs_run') list = list.filter(needsRun);

    // A name that does not parse keeps its row and loses only its place in the
    // dropdowns — filtering out what cannot be classified hides stock from the
    // person whose job is to notice it is missing.
    if (quality) list = list.filter((p) => parseItemName(p.itemCode).quality === quality);
    if (pattern) list = list.filter((p) => parseItemName(p.itemCode).pattern === pattern);

    const q = query.trim().toLowerCase();
    if (q) list = list.filter((p) => p.itemCode.toLowerCase().includes(q));

    return [...list].sort(byUrgency);
  }, [pool, filter, quality, pattern, query]);

  const moveRunStage = async (s: MinStockLine, stage: string) => {
    setBusy(s.itemCode);
    setError(null);
    try {
      const n = await Api.sales.setRunStage({ itemCode: s.itemCode, stage });
      setDone(
        `Run stage set to ${stage}. ${n} order${n === 1 ? '' : 's'} claimed against this run were updated.`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not move the run stage.');
    } finally {
      setBusy(null);
    }
  };

  const receive = async (s: MinStockLine) => {
    setBusy(`recv-${s.itemCode}`);
    setError(null);
    try {
      const r = await Api.sales.receiveRun(s.itemCode);
      setDone(
        `Run received: ${r.movedRolls} rolls of claims moved onto the shelf and ${r.relabelled} reservation(s) re-labelled. The batch quantity itself is a Desk job — book the goods in there.`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not receive the run.');
    } finally {
      setBusy(null);
    }
  };

  const startRun = (s: MinStockLine) => {
    setEditing(s.itemCode);
    setRunRolls(s.inProductionRolls);
    setRunBelts(s.inProductionBelts);
  };

  const saveRun = async (s: MinStockLine) => {
    setBusy(s.itemCode);
    setError(null);
    try {
      await Api.sales.recordProductionRun({
        itemCode: s.itemCode,
        rolls: runRolls,
        belts: runBelts,
        by: user?.name ?? user?.email ?? 'production',
      });
      setEditing(null);
      setDone(
        runRolls === 0 && runBelts === 0
          ? `Run cleared for ${s.itemCode}.`
          : `${runRolls} rolls recorded as being made for ${s.itemCode}.`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not record the run.');
    } finally {
      setBusy(null);
    }
  };

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Minimum stock</div>
          <div className="page-head__sub">
            {counts.all} pools · {counts.needsRun} need a run
          </div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`minimum-stock-${now.toISOString().slice(0, 10)}.xlsx`}
            sheet="Minimum stock"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((s) => ({
                Item: s.itemCode,
                'Minimum to hold': s.minimumRolls,
                'On the shelf': s.shelfRolls,
                'Booked by reps': s.reservedRolls,
                'Left to sell': shelfAvailable(s).rolls,
                Shortfall: shortfall(s),
                'Being made': s.inProductionRolls,
                'Still short after run': shortfallAfterRun(s),
                'Last sold': s.lastSoldOn ?? '',
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Below minimum"
          value={String(counts.below)}
          tone={counts.below ? 'warn' : 'ok'}
          foot="A run is owed"
        />
        <Tile
          label="Fully booked"
          value={String(counts.booked)}
          tone={counts.booked ? 'warn' : 'ok'}
          foot="Turning reps away now"
        />
        <Tile label="Needs a run" value={String(counts.needsRun)} foot="Either alarm" />
        <Tile label="All pools" value={String(counts.all)} foot="On the list" />
      </div>

      <div className="cal__toolbar">
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'below', label: `Below minimum (${counts.below})` },
            { value: 'booked', label: `Fully booked (${counts.booked})` },
            { value: 'needs_run', label: `Needs a run (${counts.needsRun})` },
            { value: 'all', label: `All (${counts.all})` },
          ]}
        />
        {/* Hidden when it would offer only one value — a control that can only
            be set to what it already shows costs a row and says nothing. */}
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
          aria-label="Search minimum stock"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading minimum stock…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="Nothing matches">
          Every pool in this filter is at or above its minimum with stock left to sell.
        </Empty>
      )}

      {!loading && rows.length > 0 && (
        <div className="orders__list">
          {rows.map((s) => {
            const free = shelfAvailable(s);
            const run = runAvailable(s);
            const short = shortfall(s);
            const after = shortfallAfterRun(s);
            const age = daysInStock(s.batchDate, now);
            const u = urgency(s);
            const parsed = parseItemName(s.itemCode);
            return (
              <Card
                key={s.itemCode}
                title={s.itemCode}
                actions={
                  <span className="stock__alarms">
                    {belowMinimum(s) && <Badge tone="warn">BELOW MINIMUM</Badge>}
                    {fullyBooked(s) && <Badge tone="danger">FULLY BOOKED</Badge>}
                    {u === 0 && <Badge tone="ok">healthy</Badge>}
                  </span>
                }
              >
                {parsed.quality && (
                  <div className="tiny dim" style={{ marginBottom: 6 }}>
                    {parsed.quality}
                    {parsed.width ? ` · ${parsed.width}` : ''}
                    {parsed.pattern ? ` · ${parsed.pattern}` : ''}
                  </div>
                )}

                <table className="stockpos">
                  <tbody>
                    <tr>
                      <td>Minimum to hold</td>
                      <td className="num">{s.minimumRolls}</td>
                    </tr>
                    <tr>
                      <td>On the shelf</td>
                      <td className="num">{s.shelfRolls}</td>
                    </tr>
                    <tr>
                      <td>Booked by reps</td>
                      <td className="num">{s.reservedRolls}</td>
                    </tr>
                    <tr className={free.rolls <= 0 ? 'warn' : 'ok'}>
                      <td>Left to sell</td>
                      <td className="num">{free.rolls}</td>
                    </tr>
                    {short > 0 && (
                      <tr className="warn">
                        <td>Short by</td>
                        <td className="num">{short}</td>
                      </tr>
                    )}
                  </tbody>
                </table>

                <div className="stock__movement">
                  {s.lastSoldOn ? `Last sold ${s.lastSoldOn}` : 'Never sold'}
                  {age ? ` · oldest stock ${age} days` : ''}
                </div>

                {/* The run is intent, on its own line, never folded in beside a
                    sellable figure. */}
                {s.inProductionRolls > 0 && (
                  <div className="run__note">
                    🏭 {s.inProductionRolls} rolls being made — not on the shelf yet
                    {run.rolls < s.inProductionRolls
                      ? ` · ${s.inProductionRolls - run.rolls} already claimed`
                      : ''}
                    <div className={after > 0 ? 'warn' : 'ok'}>
                      {after > 0 ? `Still ${after} rolls short after this run` : 'Covers the shortfall'}
                    </div>
                  </div>
                )}

                {editing === s.itemCode ? (
                  <div className="prod__actions">
                    <label className="tiny dim" htmlFor={`rr-${s.itemCode}`}>
                      Rolls
                    </label>
                    <Input
                      id={`rr-${s.itemCode}`}
                      numeric
                      compact
                      type="number"
                      min={0}
                      value={runRolls}
                      onChange={(e) => setRunRolls(Number(e.target.value) || 0)}
                    />
                    <label className="tiny dim" htmlFor={`rb-${s.itemCode}`}>
                      Belts
                    </label>
                    <Input
                      id={`rb-${s.itemCode}`}
                      numeric
                      compact
                      type="number"
                      min={0}
                      value={runBelts}
                      onChange={(e) => setRunBelts(Number(e.target.value) || 0)}
                    />
                    <Button size="sm" onClick={() => saveRun(s)} loading={busy === s.itemCode}>
                      Save
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>
                      Cancel
                    </Button>
                    <span className="note">
                      The run is raised in SAP; this only records it so everyone else knows stock is
                      coming. Set 0 to clear it. It never counts as available.
                    </span>
                  </div>
                ) : (
                  <div className="prod__actions">
                    <Button size="sm" variant="ghost" onClick={() => startRun(s)}>
                      {s.inProductionRolls > 0 ? 'Update run' : 'Record a run'}
                    </Button>

                    {/*
                      One batch is being made, not one job per order. Moving the
                      run's stage writes it down onto every line claimed against
                      it, so the order screens keep working without knowing runs
                      exist.
                    */}
                    {s.inProductionRolls > 0 && (
                      <>
                        <Select
                          compact
                          value={s.runStage ?? ''}
                          disabled={busy === s.itemCode}
                          onChange={(e) => e.target.value && moveRunStage(s, e.target.value)}
                          aria-label={`Run stage for ${s.itemCode}`}
                        >
                          <option value="">Run stage…</option>
                          {RUN_STAGES.map((st) => (
                            <option key={st} value={st}>
                              {st}
                            </option>
                          ))}
                        </Select>
                        <Button
                          size="sm"
                          onClick={() => receive(s)}
                          loading={busy === `recv-${s.itemCode}`}
                          disabled={!!busy}
                          title="The goods have landed: claims move onto the shelf and the run is cleared"
                        >
                          Run received
                        </Button>
                      </>
                    )}

                    {s.runUpdatedOn && (
                      <span className="tiny dim">
                        Set {s.runUpdatedOn.slice(0, 16)}
                        {s.runUpdatedBy ? ` by ${s.runUpdatedBy}` : ''}
                      </span>
                    )}
                  </div>
                )}
              </Card>
            );
          })}
        </div>
      )}

      {!loading && rows.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          The shortfall is measured against the shelf, not against what is left to sell: ten on the
          shelf with eight booked leaves two to sell, but all ten exist and are going out — ordering
          eight more would build the same goods twice.
        </p>
      )}
    </div>
  );
}
