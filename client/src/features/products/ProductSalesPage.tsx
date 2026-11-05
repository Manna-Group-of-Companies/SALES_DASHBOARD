/**
 * Product Sales — Overview, the GM's first page of the report (5 Nov 2026).
 *
 * The month in six figures — total, best and lowest product, the highest
 * price anything sold at and who sold it, the highest and lowest day — the
 * day chart, and the top five products, each a link to its own page.
 * Products lists them all; a product's page has its stock, prices and sales.
 *
 * "Sold" means ordered: orders raised in the month, less cancelled and
 * rejected (api/productSales.ts). Money is before GST; India and the UAE are
 * never added together. Read-only, like every GM screen.
 */

import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Card, Empty, Skeleton } from '@/components/ui';
import { bestAndSlowest, byDay, byProduct, mostExpensiveSale, priceOf } from './productSales';
import { MONTHS, ReportHead, Stat, dm, kgText, money, plural, priceText, useReportFilters, useSoldLines, weekday } from './shared';
import { DailySalesChart, TopProductsChart } from './charts';
import '@/components/layout/layout.css';

export function ProductSalesPage() {
  const f = useReportFilters();
  const navigate = useNavigate();
  const [tick, setTick] = useState(0);
  const { lines, loading, error } = useSoldLines(f.from, f.to, f.scope.companies, tick);
  const c = f.scope.currency;
  const m = f.measure;

  const products = useMemo(() => byProduct(lines, m), [lines, m]);
  const days = useMemo(() => byDay(lines, f.from, f.to), [lines, f.from, f.to]);
  const picks = useMemo(() => bestAndSlowest(days, m), [days, m]);
  const dearest = useMemo(() => mostExpensiveSale(lines), [lines]);
  const orders = useMemo(() => new Set(lines.map((l) => l.order)).size, [lines]);
  const sum = lines.reduce((n, l) => n + l[m], 0);

  const fmt = (v: number) => (m === 'amount' ? money(v, c) : kgText(v));
  const pct = (v: number) => (sum > 0 ? (v / sum) * 100 : 0);
  const pctText = (v: number) => (v > 0 && Math.round(pct(v)) === 0 ? '<1%' : `${Math.round(pct(v))}%`);
  const top = products[0];
  const low = products.length > 1 ? products[products.length - 1] : undefined;
  const oneDay = picks != null && picks.best.date === picks.slowest.date;
  const link = (code: string) => `/product-sales/products/${encodeURIComponent(code)}${f.query}`;
  const dash = loading ? '…' : '—';

  return (
    <div>
      <ReportHead
        f={f}
        title="Product Sales"
        sub={
          !loading && top
            ? `${top.itemName} sold most in ${MONTHS[f.mi]}: ${pctText(top[m])} of ${fmt(sum)}.`
            : 'What sold, at what price and by whom. Orders raised in the month, before GST.'
        }
        loading={loading}
        onRefresh={() => setTick((t) => t + 1)}
        error={error}
      />

      <Card flush>
        <div className="ps-stats">
          <Stat label="Total sold" value={loading ? '…' : fmt(sum)}>
            {!loading && `${plural(orders, 'order')} · ${plural(products.length, 'product')}`}
          </Stat>
          <Stat
            label="Best-selling product"
            name
            value={top ? <Link to={link(top.itemCode)}>{top.itemName}</Link> : dash}
          >
            {top && `${fmt(top[m])} · ${pctText(top[m])}`}
          </Stat>
          <Stat
            label="Lowest-selling product"
            name
            value={low ? <Link to={link(low.itemCode)}>{low.itemName}</Link> : dash}
          >
            {low && `${fmt(low[m])} · ${pctText(low[m])}`}
          </Stat>
          <Stat
            label="Highest price sold"
            value={dearest ? priceText(priceOf(dearest).value, priceOf(dearest).per, c) : dash}
          >
            {dearest && (
              <>
                {dearest.rep || 'No rep'} · <Link to={link(dearest.itemCode)}>{dearest.itemName}</Link>
              </>
            )}
          </Stat>
          <Stat label="Highest sales day" value={picks ? `${weekday(picks.best.date)} ${dm(picks.best.date)}` : dash}>
            {picks && `${fmt(picks.best[m])} · ${plural(picks.best.orders, 'order')}`}
          </Stat>
          <Stat
            label="Lowest sales day"
            value={picks && !oneDay ? `${weekday(picks.slowest.date)} ${dm(picks.slowest.date)}` : dash}
          >
            {oneDay ? 'Orders on one day only' : picks && `${fmt(picks.slowest[m])} · ${plural(picks.slowest.orders, 'order')}`}
          </Stat>
        </div>
      </Card>

      <div className="ps-two">
        <Card flush>
          <div className="ps-tools">
            <h2 className="ps-h2">Sales by day</h2>
          </div>
          <div style={{ padding: '8px 16px' }}>
            {loading ? (
              <Skeleton height={180} />
            ) : orders === 0 ? (
              <Empty icon="—" title={`No orders in ${f.scope.label}, ${f.monthLabel}`} />
            ) : (
              <DailySalesChart
                days={days}
                measure={m}
                currency={c}
                best={picks?.best.date}
                slowest={oneDay ? undefined : picks?.slowest.date}
              />
            )}
          </div>
        </Card>

        <Card flush>
          <div className="ps-tools">
            <h2 className="ps-h2">Top products</h2>
            <Link className="ps-more" to={`/product-sales/products${f.query}`}>
              All {products.length || ''} products
            </Link>
          </div>
          {loading ? (
            <div style={{ padding: 16 }}>
              <Skeleton height={160} />
            </div>
          ) : products.length === 0 ? (
            <div className="ps-empty">Nothing sold this month.</div>
          ) : (
            <div style={{ padding: '8px 12px' }}>
              <TopProductsChart products={products} measure={m} currency={c} onPick={(code) => navigate(link(code))} />
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
