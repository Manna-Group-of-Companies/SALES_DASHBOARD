/**
 * What is in stock, and what can be promised.
 *
 * The only stock screen left. There were four — this one, the production
 * manager's "what should we make next", the stock manager's ledger and their
 * replenishment page — and the other three read the minimum-stock doctypes,
 * removed on 17 September 2026. This one reads SAP.
 *
 * Six columns became two, and the four that went are worth naming so nobody
 * puts them back:
 *
 *   - **On the shelf** and **Booked** were gross stock and what reps had
 *     reserved off it. SAP reports *available to promise* — on hand, less what
 *     it has committed to open orders — so the two are already netted. Showing
 *     a booked figure beside it invites the reader to subtract it twice.
 *   - **Minimum** was the level the shelf was meant to hold. All 129 rows on
 *     the site carried zero, so the column, the "Minimum held" tile and the
 *     alarms built on it had never had anything to say.
 *   - **Being made** was a production run recorded against the pool. Runs are
 *     raised in SAP against a sales order now, and the sync brings the stage
 *     back onto the order's own lines, where the person waiting on it looks.
 *
 * It is read-only, as it always was.
 */

import { useEffect, useMemo, useState } from 'react';
import type { MinStockLine } from '@/domain/types';
import { outOfStock, shelfAvailable } from '@/domain/minimumStock';
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

type Filter = 'sellable' | 'none_left' | 'not_set_up' | 'all';

export function SalesStockPage() {
  const user = useAppSelector(selectUser);

  const [pool, setPool] = useState<MinStockLine[]>([]);
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
      .then((p) => {
        if (live) setPool(p);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read stock.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const now = useMemo(() => serverNow(), [tick]);

  const rowsWithTruth = useMemo(
    () => pool.map((s) => ({ s, free: shelfAvailable(s) })),
    [pool],
  );

  const counts = useMemo(
    () => ({
      sellable: rowsWithTruth.filter((r) => r.free.rolls > 0 || r.free.belts > 0).length,
      noneLeft: rowsWithTruth.filter((r) => r.s.weightsKnown && outOfStock(r.s)).length,
      notSetUp: rowsWithTruth.filter((r) => !r.s.weightsKnown).length,
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
    if (filter === 'none_left') list = list.filter((r) => r.s.weightsKnown && outOfStock(r.s));
    if (filter === 'not_set_up') list = list.filter((r) => !r.s.weightsKnown);

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
    }),
    [rowsWithTruth],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Stock</div>
          <div className="page-head__sub">What SAP has, and what can be promised</div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`stock-${now.toISOString().slice(0, 10)}.xlsx`}
            sheet="Stock"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((r) => ({
                Item: r.s.itemCode,
                'Available (rolls)': r.s.weightsKnown ? r.free.rolls : '',
                'Available (loose belts)': r.s.weightsKnown ? r.free.belts : '',
                'Weights set': r.s.weightsKnown ? 'Yes' : 'No',
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read stock">
          {error}
        </Alert>
      )}

      {/*
        Not a defect and not hidden. SAP holds these items in kilograms and
        nobody has said what a roll weighs, so there is no honest figure to
        print — and the instruction is that they read as nothing available
        until the weights are loaded. Saying how many there are is what stops
        somebody reading the "Nothing left" count as the whole story.
      */}
      {!loading && counts.notSetUp > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title={`${counts.notSetUp} items have no weights set`}>
            SAP holds these in kilograms and their item master has no weight per roll or belts per
            roll, so how many rolls that is cannot be worked out. They report nothing available
            until the weights are loaded.
          </Alert>
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Available to promise"
          value={String(totals.free)}
          tone="ok"
          foot="Rolls, across every item"
        />
        <Tile
          label="Nothing left"
          value={String(counts.noneLeft)}
          tone={counts.noneLeft ? 'warn' : undefined}
          foot="In SAP, none available"
        />
        <Tile
          label="Weights not set"
          value={String(counts.notSetUp)}
          foot="No figure can be given"
        />
      </div>

      <div className="cal__toolbar">
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'sellable', label: `Available (${counts.sellable})` },
            { value: 'none_left', label: `Nothing left (${counts.noneLeft})` },
            { value: 'not_set_up', label: `Weights not set (${counts.notSetUp})` },
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

      {loading && <Empty icon="◔" title="Reading stock…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="—" title="Nothing matches">
          {filter === 'sellable'
            ? 'SAP has nothing available to promise.'
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
                  <th className="right">Available to promise</th>
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
                        {!r.s.weightsKnown ? (
                          <Badge tone="neutral">weights not set</Badge>
                        ) : r.free.rolls > 0 || r.free.belts > 0 ? (
                          <b className="ok">
                            {r.free.rolls}
                            {r.free.belts ? ` + ${r.free.belts} belts` : ''}
                          </b>
                        ) : (
                          <Badge tone="warn">none</Badge>
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
          These figures come from SAP and are <b>already net of every open sales order</b>, whoever
          raised it. They refresh on the five-minute stock sync, so two people can briefly be shown
          the same rolls — SAP decides who gets them.
        </p>
      )}
    </div>
  );
}
