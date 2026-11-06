/**
 * The Product Sales charts (5 Nov 2026), on components/charts/chart.tsx.
 * One hue, the app's accent, on every data mark; one y-axis per chart.
 *
 *   DailySalesChart   a column a day, the month's average as a dashed line,
 *                     the highest and lowest days marked
 *   TopProductsChart  the best sellers as horizontal bars; a bar opens the product
 *   PriceChart        every sale of one product at its price, by date, with the
 *                     average price as a dashed line
 *   RepsChart         who sold one product, as horizontal bars
 */

import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  LabelList,
  ReferenceLine,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
  ZAxis,
} from 'recharts';
import type { SoldLine } from '@/api/productSales';
import { ChartContainer, ChartTip, axis, compact, grid, type ChartConfig } from '@/components/charts/chart';
import { priceOf, type DayTotal, type Measure, type ProductTotal, type RepShare } from './productSales';
import { dm, kgText, money, plural, priceText, weekday, type Currency } from './shared';

const ACCENT = 'var(--accent)';

/** A category tick on one line, cut with an ellipsis; Recharts would wrap it. */
function NameTick({ x, y, payload, max }: { x?: number; y?: number; payload?: { value: string }; max: number }) {
  const v = payload?.value ?? '';
  const t = v.length > max ? `${v.slice(0, max - 1)}…` : v;
  return (
    <text x={x} y={y} dy={4} textAnchor="end" fontSize={12} fill="var(--text)">
      <title>{v}</title>
      {t}
    </text>
  );
}

/** A value at the end of a horizontal bar, on one line. */
function EndLabel({ x = 0, y = 0, width = 0, height = 0, value, fmt }: { x?: number; y?: number; width?: number; height?: number; value?: number; fmt: (v: number) => string }) {
  return (
    <text x={Number(x) + Number(width) + 6} y={Number(y) + Number(height) / 2} dy={4} fontSize={11} fill="var(--text-2)">
      {value != null ? fmt(value) : ''}
    </text>
  );
}
const config: ChartConfig = { sales: { label: 'Sales', color: ACCENT } };

const fmtFor = (measure: Measure, c: Currency) => (v: number) => (measure === 'amount' ? money(v, c) : kgText(v));
const axisFor = (measure: Measure, c: Currency) => (v: number) => compact(v, measure === 'amount' ? c : 'kg');

// ------------------------------------------------------------ by day ---

export function DailySalesChart({
  days,
  measure,
  currency,
  best,
  slowest,
}: {
  days: DayTotal[];
  measure: Measure;
  currency: Currency;
  best?: string;
  slowest?: string;
}) {
  const fmt = fmtFor(measure, currency);
  const withSales = days.filter((d) => d[measure] > 0);
  const avg = withSales.length ? withSales.reduce((n, d) => n + d[measure], 0) / withSales.length : 0;
  const data = days.map((d) => ({ ...d, v: d[measure], day: d.date.slice(8, 10) }));

  return (
    <ChartContainer config={config} height={250}>
      <BarChart data={data} margin={{ top: 18, right: 8, left: 0, bottom: 0 }}>
        <CartesianGrid {...grid} />
        <XAxis dataKey="day" {...axis} interval="preserveStartEnd" minTickGap={8} />
        <YAxis {...axis} width={48} tickFormatter={axisFor(measure, currency)} />
        {avg > 0 && (
          <ReferenceLine
            y={avg}
            stroke="var(--text-3)"
            strokeDasharray="4 4"
            label={{ value: `avg ${axisFor(measure, currency)(avg)}`, position: 'insideTopRight', fill: 'var(--text-3)', fontSize: 11 }}
          />
        )}
        <Tooltip
          cursor={{ fill: 'var(--surface-3)', opacity: 0.6 }}
          content={({ active, payload }) => {
            const d = active && payload?.[0]?.payload;
            if (!d) return null;
            return (
              <ChartTip
                title={`${weekday(d.date)} ${dm(d.date)}`}
                rows={[{ label: 'Sales', value: d.v > 0 ? fmt(d.v) : 'No orders', color: ACCENT }]}
                foot={
                  d.date === best ? 'Highest day of the month' : d.date === slowest ? 'Lowest day with orders' : d.orders ? plural(d.orders, 'order') : undefined
                }
              />
            );
          }}
        />
        <Bar dataKey="v" radius={[4, 4, 0, 0]} maxBarSize={28}>
          {data.map((d) => (
            <Cell key={d.date} fill="var(--color-sales)" fillOpacity={d.date === best ? 1 : d.date === slowest ? 0.4 : 0.75} />
          ))}
        </Bar>
      </BarChart>
    </ChartContainer>
  );
}

// ------------------------------------------------------- top products ---

export function TopProductsChart({
  products,
  measure,
  currency,
  onPick,
  limit = 8,
}: {
  products: ProductTotal[];
  measure: Measure;
  currency: Currency;
  onPick: (itemCode: string) => void;
  limit?: number;
}) {
  const fmt = fmtFor(measure, currency);
  const data = products.slice(0, limit).map((p) => ({
    code: p.itemCode,
    name: p.itemName,
    full: p.itemName,
    v: p[measure],
    orders: p.orders,
  }));

  return (
    <ChartContainer config={config} height={Math.max(160, data.length * 40 + 20)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 86, left: 12, bottom: 4 }}>
        <XAxis type="number" hide />
        <YAxis type="category" dataKey="name" {...axis} width={230} tick={<NameTick max={28} />} />
        <Tooltip
          cursor={{ fill: 'var(--surface-3)', opacity: 0.6 }}
          content={({ active, payload }) => {
            const d = active && payload?.[0]?.payload;
            if (!d) return null;
            return <ChartTip title={d.full} rows={[{ label: 'Sold', value: fmt(d.v), color: ACCENT }]} foot={`${plural(d.orders, 'order')} · click to open`} />;
          }}
        />
        <Bar
          dataKey="v"
          fill="var(--color-sales)"
          radius={[0, 4, 4, 0]}
          barSize={18}
          cursor="pointer"
          onClick={(d: { code?: string }) => d.code && onPick(d.code)}
        >
          <LabelList dataKey="v" content={<EndLabel fmt={fmt} />} />
        </Bar>
      </BarChart>
    </ChartContainer>
  );
}

// ------------------------------------------------------------- prices ---

export function PriceChart({
  lines,
  per,
  currency,
  average,
  from,
  to,
}: {
  lines: SoldLine[];
  per: string;
  currency: Currency;
  average: number;
  from: string;
  to: string;
}) {
  const t = (iso: string) => new Date(`${iso}T00:00:00`).getTime();
  const data = lines
    .filter((l) => priceOf(l).per === per && priceOf(l).value > 0)
    .map((l) => ({ x: t(l.date), y: priceOf(l).value, z: l.kg || l.qty || 1, l }));
  if (!data.length) return <div className="ps-empty">No price recorded on these sales.</div>;
  const ys = data.map((d) => d.y);
  const pad = Math.max(1, (Math.max(...ys) - Math.min(...ys)) * 0.25);

  return (
    <ChartContainer config={config} height={230}>
      <ScatterChart margin={{ top: 16, right: 16, left: 0, bottom: 0 }}>
        <CartesianGrid {...grid} />
        <XAxis
          type="number"
          dataKey="x"
          domain={[t(from), t(to)]}
          {...axis}
          tickFormatter={(v: number) => dm(new Date(v).toISOString().slice(0, 10))}
          tickCount={6}
        />
        <YAxis
          type="number"
          dataKey="y"
          {...axis}
          width={56}
          domain={[Math.max(0, Math.floor(Math.min(...ys) - pad)), Math.ceil(Math.max(...ys) + pad)]}
          tickFormatter={(v: number) => String(v)}
        />
        {/* Dot size follows the quantity sold. */}
        <ZAxis type="number" dataKey="z" range={[60, 260]} />
        {average > 0 && (
          <ReferenceLine
            y={average}
            stroke="var(--text-3)"
            strokeDasharray="4 4"
            label={{ value: `avg ${Math.round(average)}`, position: 'insideTopRight', fill: 'var(--text-3)', fontSize: 11 }}
          />
        )}
        <Tooltip
          cursor={{ strokeDasharray: '3 3', stroke: 'var(--border)' }}
          content={({ active, payload }) => {
            const d = active && payload?.[0]?.payload;
            if (!d) return null;
            const l: SoldLine = d.l;
            return (
              <ChartTip
                title={`${l.rep || 'No rep'} · ${dm(l.date)}`}
                rows={[
                  { label: 'Price', value: priceText(d.y, per, currency), color: ACCENT },
                  { label: 'Quantity', value: l.kg ? kgText(l.kg) : `${l.qty} ${l.uom}` },
                  { label: 'Amount', value: money(l.amount, currency) },
                ]}
                foot={l.order}
              />
            );
          }}
        />
        <Scatter data={data} fill="var(--color-sales)" fillOpacity={0.8} stroke="var(--surface)" strokeWidth={2} />
      </ScatterChart>
    </ChartContainer>
  );
}

// --------------------------------------------------------------- reps ---

export function RepsChart({ reps, currency }: { reps: RepShare[]; currency: Currency }) {
  const data = reps.map((r) => ({ name: r.rep, v: r.amount, r }));
  return (
    <ChartContainer config={config} height={data.length * 36 + 16}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 84, left: 4, bottom: 4 }}>
        <XAxis type="number" hide />
        <YAxis type="category" dataKey="name" {...axis} width={120} tick={<NameTick max={16} />} />
        <Tooltip
          cursor={{ fill: 'var(--surface-3)', opacity: 0.6 }}
          content={({ active, payload }) => {
            const d = active && payload?.[0]?.payload;
            if (!d) return null;
            const r: RepShare = d.r;
            return (
              <ChartTip
                title={r.rep}
                rows={[
                  { label: 'Sold', value: money(r.amount, currency), color: ACCENT },
                  { label: 'Weight', value: r.kg ? kgText(r.kg) : '—' },
                  { label: 'Orders', value: r.orders },
                ]}
              />
            );
          }}
        />
        <Bar dataKey="v" fill="var(--color-sales)" radius={[0, 4, 4, 0]} barSize={16}>
          <LabelList dataKey="v" content={<EndLabel fmt={(v) => money(v, currency)} />} />
        </Bar>
      </BarChart>
    </ChartContainer>
  );
}
