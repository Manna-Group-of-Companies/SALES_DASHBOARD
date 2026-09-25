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
 * WHO SEES WHAT (24 September 2026)
 *
 * An item with both weight UDFs reads as rolls and belts to everyone. An item
 * missing either reads in kilograms to a sales manager and is left off this
 * page for every other role — see `domain/stockView.ts` for why. The manager
 * is also the one who can get the UDFs filled in, so the page tells them how
 * many items their reps cannot see.
 *
 * It is read-only apart from "Reload from SAP", which only asks the office
 * server to fetch; it writes no stock itself.
 */

import { useEffect, useMemo, useState } from 'react';
import type { MinStockLine } from '@/domain/types';
import { parseItemName, distinctOf, worthOffering } from '@/domain/itemNaming';
import { describeReading, hasStock, seesUnweighedStock, stockReading, type StockReading } from '@/domain/stockView';
import { serverNow } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { SapRefreshPanel, type SapRefreshTarget } from '@/components/common/SapRefreshPanel';
import { ExportButton } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/features/orders/orders.css';
import '@/features/production/production.css';

type Filter = 'sellable' | 'none_left' | 'by_weight' | 'all';

interface Row {
  s: MinStockLine;
  r: StockReading;
  /** The item name when it has one; quality and pattern are parsed from it. */
  label: string;
}

export function SalesStockPage() {
  const user = useAppSelector(selectUser);
  const managerView = seesUnweighedStock(user?.role);

  const [pool, setPool] = useState<MinStockLine[]>([]);
  const [filter, setFilter] = useState<Filter>('sellable');
  const [quality, setQuality] = useState('');
  const [pattern, setPattern] = useState('');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  /*
   * Memoised, and it has to be: the panel's polling loop depends on
   * `onSynced`, and a new function every render would restart — and so stop —
   * that loop once a second.
   */
  const stockSync = useMemo<SapRefreshTarget>(
    () => ({
      title: 'Stock from SAP',
      getStatus: Api.sales.getStockSyncStatus,
      request: Api.sales.requestStockSync,
      noun: 'item',
      busyNote: 'Fetching finished-goods stock from SAP — usually under half a minute.',
      onSynced: () => setTick((t) => t + 1),
    }),
    [],
  );

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

  /** Every row this viewer may see. The rest never reach a filter or a count. */
  const visible = useMemo<Row[]>(() => {
    const out: Row[] = [];
    for (const s of pool) {
      const r = stockReading(s, user?.role);
      if (r) out.push({ s, r, label: s.itemName || s.itemCode });
    }
    return out;
  }, [pool, user?.role]);

  const counts = useMemo(
    () => ({
      sellable: visible.filter((x) => hasStock(x.r)).length,
      noneLeft: visible.filter((x) => !hasStock(x.r)).length,
      byWeight: visible.filter((x) => x.r.kind === 'weight').length,
      all: visible.length,
    }),
    [visible],
  );

  const qualities = useMemo(
    () => distinctOf(visible.map((x) => x.label), (n) => n.quality),
    [visible],
  );
  const patterns = useMemo(
    () => distinctOf(visible.map((x) => x.label), (n) => n.pattern),
    [visible],
  );

  const rows = useMemo(() => {
    let list = visible;
    if (filter === 'sellable') list = list.filter((x) => hasStock(x.r));
    if (filter === 'none_left') list = list.filter((x) => !hasStock(x.r));
    if (filter === 'by_weight') list = list.filter((x) => x.r.kind === 'weight');

    if (quality) list = list.filter((x) => parseItemName(x.label).quality === quality);
    if (pattern) list = list.filter((x) => parseItemName(x.label).pattern === pattern);

    const q = query.trim().toLowerCase();
    if (q) list = list.filter((x) => `${x.label} ${x.s.itemCode}`.toLowerCase().includes(q));

    /*
     * By name, because the reader is looking something up. This sorted oldest
     * first until 21 August 2026, when the dead-stock feature was removed:
     * ordering the list by an age nobody is shown ranks it against a rule the
     * reader cannot see.
     */
    return [...list].sort((a, b) => a.label.localeCompare(b.label));
  }, [visible, filter, quality, pattern, query]);

  const totals = useMemo(() => {
    let rolls = 0;
    let kg = 0;
    for (const x of visible) {
      if (x.r.kind === 'rolls') rolls += x.r.rolls;
      else if (x.r.uom === 'kg') kg += x.r.qty;
    }
    return { rolls, kg };
  }, [visible]);

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
              rows.map((x) => ({
                Item: x.label,
                Code: x.s.itemCode,
                'Available (rolls)': x.r.kind === 'rolls' ? x.r.rolls : '',
                'Available (loose belts)': x.r.kind === 'rolls' ? x.r.belts : '',
                ...(managerView
                  ? {
                      'Available (by weight)': x.r.kind === 'weight' ? x.r.qty : '',
                      Unit: x.r.kind === 'weight' ? x.r.uom : '',
                    }
                  : {}),
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <SapRefreshPanel target={stockSync} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read stock">
          {error}
        </Alert>
      )}

      {/*
        Only the sales manager is told, because only the sales manager is shown
        these rows — and saying who cannot see them is what stops the manager
        assuming a rep has the same list in front of them.
      */}
      {managerView && !loading && counts.byWeight > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title={`${counts.byWeight} items are shown by weight only`}>
            SAP has no belts per roll or weight per roll on these items, so their stock cannot be
            counted in rolls. You see them in kilograms; reps and the stock and production screens
            do not see them at all until both UDFs are filled in on the SAP item.
          </Alert>
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Available to promise"
          value={String(totals.rolls)}
          tone="ok"
          foot="Rolls, across every item with weights"
        />
        <Tile
          label="Nothing left"
          value={String(counts.noneLeft)}
          tone={counts.noneLeft ? 'warn' : undefined}
          foot="In SAP, none available"
        />
        {managerView && (
          <Tile
            label="By weight only"
            value={`${Math.round(totals.kg).toLocaleString('en-IN')} kg`}
            foot={`${counts.byWeight} items with no roll weight`}
          />
        )}
      </div>

      <div className="cal__toolbar">
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'sellable', label: `Available (${counts.sellable})` },
            { value: 'none_left', label: `Nothing left (${counts.noneLeft})` },
            ...(managerView
              ? [{ value: 'by_weight' as const, label: `By weight only (${counts.byWeight})` }]
              : []),
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
                {rows.map((x) => {
                  const p = parseItemName(x.label);
                  return (
                    <tr key={x.s.itemCode}>
                      <td>
                        <div>{x.label}</div>
                        <div className="tiny dim">
                          {x.s.itemCode}
                          {p.quality ? ` · ${p.quality}` : ''}
                          {p.width ? ` · ${p.width}` : ''}
                          {p.pattern ? ` · ${p.pattern}` : ''}
                        </div>
                      </td>
                      <td className="right num">
                        {!hasStock(x.r) ? (
                          <Badge tone="warn">none</Badge>
                        ) : x.r.kind === 'weight' ? (
                          <span className="stack gap-1" style={{ alignItems: 'flex-end' }}>
                            <b>{describeReading(x.r)}</b>
                            <span className="tiny dim">no roll weight in SAP</span>
                          </span>
                        ) : (
                          <b className="ok">{describeReading(x.r)}</b>
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
          raised it. Two people can briefly be shown the same rolls between syncs — SAP decides who
          gets them.
        </p>
      )}
    </div>
  );
}
