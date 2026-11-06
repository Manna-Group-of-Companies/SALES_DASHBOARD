/**
 * Charts on Recharts, in the manner of shadcn/ui's chart block (5 Nov 2026):
 * a container that turns a small config into CSS colour variables
 * (`--color-<key>`), and one tooltip that looks like the rest of the app.
 *
 * Not the shadcn package itself: that brings Tailwind and its own base
 * styles, which would restyle every existing screen of the hosted dashboard.
 * This is the same idea on the app's own tokens (styles/global.css), so the
 * charts follow light and dark mode like everything else.
 */

import type { CSSProperties, ReactElement, ReactNode } from 'react';
import { ResponsiveContainer } from 'recharts';
import './chart.css';

export type ChartConfig = Record<string, { label: string; color: string }>;

/** Sizes the chart to its box and publishes each series colour as `--color-<key>`. */
export function ChartContainer({
  config,
  height = 240,
  className = '',
  children,
}: {
  config: ChartConfig;
  height?: number;
  className?: string;
  children: ReactElement;
}) {
  const vars = Object.fromEntries(Object.entries(config).map(([k, v]) => [`--color-${k}`, v.color])) as CSSProperties;
  return (
    <div className={`chart ${className}`} style={{ ...vars, height }}>
      <ResponsiveContainer width="100%" height="100%">
        {children}
      </ResponsiveContainer>
    </div>
  );
}

/** The tooltip box: a title line, then label · value rows. */
export function ChartTip({ title, rows, foot }: { title: ReactNode; rows: { label: ReactNode; value: ReactNode; color?: string }[]; foot?: ReactNode }) {
  return (
    <div className="chart-tip">
      <div className="chart-tip__title">{title}</div>
      {rows.map((r, i) => (
        <div className="chart-tip__row" key={i}>
          {r.color && <i style={{ background: r.color }} />}
          <span className="chart-tip__label">{r.label}</span>
          <span className="chart-tip__value">{r.value}</span>
        </div>
      ))}
      {foot && <div className="chart-tip__foot">{foot}</div>}
    </div>
  );
}

/** Axis and grid props shared by every chart, so they all read the same. */
export const axis = {
  tickLine: false,
  axisLine: false,
  tick: { fontSize: 11, fill: 'var(--text-3)' },
} as const;
export const grid = { stroke: 'var(--border)', strokeDasharray: '3 3', vertical: false } as const;

/** `59184` → `59.2k`, `1250000` → `12.5L` (INR) / `1.25M` (AED). For axes only. */
export function compact(v: number, currency: 'INR' | 'AED' | 'kg'): string {
  const a = Math.abs(v);
  if (currency === 'INR') {
    if (a >= 1e7) return `${+(v / 1e7).toFixed(1)}Cr`;
    if (a >= 1e5) return `${+(v / 1e5).toFixed(1)}L`;
  } else if (a >= 1e6) return `${+(v / 1e6).toFixed(1)}M`;
  if (a >= 1e3) return `${+(v / 1e3).toFixed(1)}k`;
  return String(Math.round(v));
}
