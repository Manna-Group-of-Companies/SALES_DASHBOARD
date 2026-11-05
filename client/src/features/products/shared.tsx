/**
 * What the three Product Sales pages share (5 Nov 2026): the month, unit and
 * measure (kept in the URL so they survive moving between pages and Back),
 * the data loads, the formatting, and the header with its page tabs. The
 * charts are in charts.tsx.
 *
 *   /product-sales                    Overview
 *   /product-sales/products           Products, best first
 *   /product-sales/products/:code     One product: stock, prices, who sold it
 */

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { NavLink, useSearchParams } from 'react-router-dom';
import { getSoldLines, type SoldLine } from '@/api/productSales';
import { Api } from '@/api/client';
import type { MinStockLine } from '@/domain/types';
import { describeReading, hasStock, stockReading } from '@/domain/stockView';
import { Alert, Button, Icon, Segmented, Select, type BadgeTone } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import type { Measure } from './productSales';
import './products.css';

export const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const pad = (n: number) => String(n).padStart(2, '0');

export type Currency = 'INR' | 'AED';

/** What the unit picker offers; India and the UAE are never added together. */
export const SCOPES: { key: string; label: string; companies: string[]; currency: Currency }[] = [
  { key: 'india', label: 'India — both units', companies: ['Manna Treads', 'Manna Tyre Retreads'], currency: 'INR' },
  { key: 'mt', label: 'Manna Treads', companies: ['Manna Treads'], currency: 'INR' },
  { key: 'mtr', label: 'Manna Tyre Retreads', companies: ['Manna Tyre Retreads'], currency: 'INR' },
  { key: 'uae', label: 'Manna Tyres UAE', companies: ['Manna Tyres UAE'], currency: 'AED' },
];

// ---------------------------------------------------------- formatting ---

export function money(v: number, c: Currency, decimals = 0): string {
  return `${c} ${v.toLocaleString(c === 'AED' ? 'en-AE' : 'en-IN', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`;
}
/** An exact price: paise shown only when there are any. */
export const priceText = (v: number, per: string, c: Currency) => `${money(v, c, Number.isInteger(v) ? 0 : 2)} /${per}`;
export const kgText = (v: number) => `${Math.round(v).toLocaleString('en-IN')} kg`;
/** `2026-11-03` → `03 Nov`. */
export const dm = (iso: string) => `${iso.slice(8, 10)} ${MONTHS[Number(iso.slice(5, 7)) - 1]}`;
export const weekday = (iso: string) =>
  new Date(`${iso}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short' });
export const initials = (name: string) =>
  name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join('') || '—';
export const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`;

// --------------------------------------------------------------- stock ---

/**
 * Whether Hi-Tech still has an item, read the way the GM may read it
 * (domain/stockView.ts, 24 Sep 2026): rolls and belts, never kilograms.
 */
export type StockState = { tone: BadgeTone; label: string; detail: string };
export function stockState(line: MinStockLine | undefined, loaded: boolean): StockState {
  if (!loaded) return { tone: 'neutral', label: '…', detail: 'Reading stock' };
  if (!line) return { tone: 'neutral', label: 'No stock record', detail: 'Not in the SAP stock list' };
  const r = stockReading(line, 'general_manager');
  if (!r) return { tone: 'neutral', label: 'Stock not set up', detail: 'Roll weights not filled in for this item' };
  if (!hasStock(r)) return { tone: 'danger', label: 'Sold out', detail: 'Nothing left to promise' };
  return { tone: 'ok', label: 'In stock', detail: `${describeReading(r)} available` };
}

// ------------------------------------------------------- filters & data ---

/** Month, unit and measure, from the URL (`?m=2026-10&u=india&by=kg`). */
export function useReportFilters() {
  const [params, setParams] = useSearchParams();
  const now = new Date();
  const maxYm = now.getFullYear() * 12 + now.getMonth();
  const m = /^(\d{4})-(\d{2})$/.exec(params.get('m') ?? '');
  const ym = m ? Math.min(Number(m[1]) * 12 + Number(m[2]) - 1, maxYm) : maxYm;
  const year = Math.floor(ym / 12);
  const mi = ym % 12;
  const scope = SCOPES.find((s) => s.key === params.get('u')) ?? SCOPES[0];
  const measure: Measure = params.get('by') === 'kg' ? 'kg' : 'amount';

  const set = (k: string, v: string | null) =>
    setParams(
      (p) => {
        const n = new URLSearchParams(p);
        if (v == null) n.delete(k);
        else n.set(k, v);
        return n;
      },
      { replace: true },
    );

  const from = `${year}-${pad(mi + 1)}-01`;
  const last = `${year}-${pad(mi + 1)}-${pad(new Date(year, mi + 1, 0).getDate())}`;
  const todayIso = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;

  return {
    year,
    mi,
    monthLabel: `${MONTHS[mi]} ${year}`,
    canNext: ym < maxYm,
    setYm: (v: number) => set('m', `${Math.floor(v / 12)}-${pad((v % 12) + 1)}`),
    ym,
    scope,
    setScope: (k: string) => set('u', k === SCOPES[0].key ? null : k),
    measure,
    setMeasure: (v: Measure) => set('by', v === 'amount' ? null : v),
    from,
    // This month runs to today, not to its last day.
    to: last > todayIso ? todayIso : last,
    /** The query string to carry onto links between the pages. */
    query: params.toString() ? `?${params.toString()}` : '',
  };
}

/** The month's order lines in this unit. */
export function useSoldLines(from: string, to: string, companies: string[], tick: number) {
  const [lines, setLines] = useState<SoldLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    getSoldLines(from, to)
      .then((l) => live && setLines(l))
      .catch((e: unknown) => {
        if (!live) return;
        setLines([]);
        setError(e instanceof Error && e.message ? e.message : 'Could not read the orders.');
      })
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [from, to, tick]);
  const key = companies.join('|');
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const inScope = useMemo(() => lines.filter((l) => companies.includes(l.company)), [lines, key]);
  return { lines: inScope, loading, error };
}

/** Today's stock by item code. Best-effort: the report stands without it. */
export function useStock(tick: number) {
  const [stock, setStock] = useState<Map<string, MinStockLine>>(new Map());
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    setLoaded(false);
    Api.sales
      .listMinimumStock()
      .then((s) => {
        if (!live) return;
        setStock(new Map(s.map((x) => [x.itemCode, x])));
        setFailed(false);
      })
      .catch(() => live && setFailed(true))
      .finally(() => live && setLoaded(true));
    return () => {
      live = false;
    };
  }, [tick]);
  return { stock, loaded, failed };
}

// -------------------------------------------------------------- header ---

/** Title, one plain sentence, the month, unit and measure, and the page tabs. */
export function ReportHead({
  f,
  title,
  sub,
  loading,
  onRefresh,
  error,
  back,
}: {
  f: ReturnType<typeof useReportFilters>;
  title: ReactNode;
  sub: ReactNode;
  loading: boolean;
  onRefresh: () => void;
  error: string | null;
  /** A product page shows a way back to the list instead of the tabs. */
  back?: ReactNode;
}) {
  return (
    <>
      <div className="page-head">
        <div className="grow" style={{ minWidth: 0 }}>
          <h1 className="page-head__title ps-h1">{title}</h1>
          <div className="ps-finding">{sub}</div>
        </div>
        <div className="ps-month">
          <Button size="sm" onClick={() => f.setYm(f.ym - 1)} aria-label="Previous month">
            <Icon name="chevronLeft" size={14} />
          </Button>
          <strong>{f.monthLabel}</strong>
          <Button size="sm" onClick={() => f.setYm(f.ym + 1)} disabled={!f.canNext} aria-label="Next month">
            <Icon name="chevronRight" size={14} />
          </Button>
        </div>
        <RefreshButton onClick={onRefresh} loading={loading} />
      </div>

      <div className="ps-bar-row">
        {back ?? (
          <nav className="ps-tabs" aria-label="Product Sales pages">
            <NavLink end to={`/product-sales${f.query}`} className={({ isActive }) => `ps-tab${isActive ? ' is-on' : ''}`}>
              Overview
            </NavLink>
            <NavLink to={`/product-sales/products${f.query}`} className={({ isActive }) => `ps-tab${isActive ? ' is-on' : ''}`}>
              Products
            </NavLink>
          </nav>
        )}
        <div className="ps-bar-row__right">
          <div style={{ width: 200 }}>
            <Select value={f.scope.key} onChange={(e) => f.setScope(e.target.value)} aria-label="Unit">
              {SCOPES.map((s) => (
                <option key={s.key} value={s.key}>
                  {s.label}
                </option>
              ))}
            </Select>
          </div>
          <Segmented<Measure>
            ariaLabel="Rank by"
            value={f.measure}
            onChange={f.setMeasure}
            options={[
              { value: 'amount', label: `Value (${f.scope.currency})` },
              { value: 'kg', label: 'Weight' },
            ]}
          />
        </div>
      </div>

      {error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="danger" title="Could not load the sales">
            {error}
          </Alert>
        </div>
      )}
    </>
  );
}

/** One figure: a label, the value, one line under it. */
export function Stat({ label, value, children, name }: { label: string; value: ReactNode; children?: ReactNode; name?: boolean }) {
  return (
    <div className="ps-stat">
      <div className="ps-stat__l">{label}</div>
      <div className={`ps-stat__v${name ? ' ps-stat__name' : ''}`}>{value}</div>
      {children != null && <div className="ps-stat__s">{children}</div>}
    </div>
  );
}
