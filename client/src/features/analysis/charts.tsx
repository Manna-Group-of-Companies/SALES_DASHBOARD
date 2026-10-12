/**
 * Hand-drawn SVG charts for the analysis screen.
 *
 * No chart library: the app has none, and these five shapes are all the
 * screen needs. Every chart measures its own width so text stays at its real
 * size instead of scaling with a viewBox, and every one has a hover layer —
 * a chart you cannot read a value off is a picture.
 *
 * Colours come from `--viz-*` tokens in analysis.css, never raw hex, so the
 * dark theme swaps them in one place.
 */

import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';

// ------------------------------------------------------------- plumbing ---

function useWidth<T extends HTMLElement>(): [React.RefObject<T>, number] {
  const ref = useRef<T>(null);
  const [w, setW] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    setW(el.clientWidth);
    const ro = new ResizeObserver(([e]) => setW(e.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

/** Round a maximum up to a tidy axis top, and give the ticks under it. */
function niceTicks(max: number, count = 4): number[] {
  if (!(max > 0)) return [0, 1];
  const raw = max / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? raw;
  const out: number[] = [];
  for (let v = 0; v <= max + step * 0.001; v += step) out.push(v);
  if (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
  return out;
}

function Tip({ x, y, width, children }: { x: number; y: number; width: number; children: ReactNode }) {
  // Flip to the left of the cursor in the right half so it never leaves the card.
  const left = x > width / 2;
  return (
    <div
      className="viz-tip"
      style={{ top: y, left: left ? undefined : x + 14, right: left ? width - x + 14 : undefined }}
    >
      {children}
    </div>
  );
}

export function Swatch({ color, line }: { color: string; line?: boolean }) {
  return <span className={`viz-swatch ${line ? 'viz-swatch--line' : ''}`} style={{ background: color }} />;
}

export function Legend({ items }: { items: Array<{ label: string; color: string; line?: boolean }> }) {
  return (
    <div className="viz-legend">
      {items.map((i) => (
        <span key={i.label} className="viz-legend__item">
          <Swatch color={i.color} line={i.line} />
          {i.label}
        </span>
      ))}
    </div>
  );
}

const PAD = { top: 12, right: 12, bottom: 26, left: 56 };

// --------------------------------------------------------------- trend ---

export interface TrendPoint {
  label: string;
  value: number;
  compare?: number;
  /** Shown under the value in the tooltip, e.g. "14 orders · 3.2 t". */
  detail?: string;
}

/**
 * This period as bars, the comparison period as a line over them, and an
 * optional least-squares trend line. One axis: all three are the same measure.
 */
export function TrendChart({
  points,
  format,
  compareLabel,
  showTrend,
  height = 260,
}: {
  points: TrendPoint[];
  format: (v: number) => string;
  compareLabel?: string;
  showTrend?: boolean;
  height?: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const hasCompare = points.some((p) => p.compare !== undefined);

  const max = Math.max(1, ...points.map((p) => Math.max(p.value, p.compare ?? 0)));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const iw = Math.max(0, width - PAD.left - PAD.right);
  const ih = height - PAD.top - PAD.bottom;
  const band = points.length ? iw / points.length : 0;
  const barW = Math.max(2, Math.min(36, band - 4));
  const x = (i: number) => PAD.left + band * i + band / 2;
  const y = (v: number) => PAD.top + ih - (v / top) * ih;
  const labelEvery = Math.max(1, Math.ceil(points.length / Math.max(1, Math.floor(iw / 56))));

  // Least squares over the bars.
  let trend: [number, number] | null = null;
  if (showTrend && points.length > 1) {
    const n = points.length;
    const xm = (n - 1) / 2;
    const ym = points.reduce((s, p) => s + p.value, 0) / n;
    let num = 0;
    let den = 0;
    points.forEach((p, i) => {
      num += (i - xm) * (p.value - ym);
      den += (i - xm) ** 2;
    });
    const slope = num / den;
    trend = [ym - slope * xm, ym + slope * (n - 1 - xm)];
  }

  const comparePath = hasCompare
    ? points
        .map((p, i) => (p.compare === undefined ? null : `${x(i)},${y(p.compare)}`))
        .filter(Boolean)
        .map((pt, i) => `${i ? 'L' : 'M'}${pt}`)
        .join(' ')
    : '';

  const h = hover !== null ? points[hover] : null;

  return (
    <div className="viz" ref={ref} onMouseLeave={() => setHover(null)}>
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label="Sales trend">
          {ticks.map((t) => (
            <g key={t}>
              <line className="viz-grid" x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} />
              <text className="viz-axis" x={PAD.left - 8} y={y(t)} dy="0.32em" textAnchor="end">
                {format(t)}
              </text>
            </g>
          ))}
          {points.map((p, i) => {
            const bh = Math.max(0, PAD.top + ih - y(p.value));
            return (
              <g key={i}>
                {bh > 0 && (
                  <path
                    className={`viz-bar ${hover === i ? 'is-hover' : ''}`}
                    d={roundedTop(x(i) - barW / 2, y(p.value), barW, bh, Math.min(4, barW / 2))}
                  />
                )}
                {i % labelEvery === 0 && (
                  <text className="viz-axis" x={x(i)} y={height - 8} textAnchor="middle">
                    {p.label}
                  </text>
                )}
              </g>
            );
          })}
          {comparePath && <path className="viz-compare" d={comparePath} />}
          {trend && (
            <line className="viz-trend" x1={x(0)} x2={x(points.length - 1)} y1={y(trend[0])} y2={y(trend[1])} />
          )}
          {/* Hit targets: the whole band, not the bar, so a short bar is still easy to hover. */}
          {points.map((_, i) => (
            <rect
              key={i}
              x={PAD.left + band * i}
              y={PAD.top}
              width={band}
              height={ih}
              fill="transparent"
              onMouseEnter={() => setHover(i)}
            />
          ))}
        </svg>
      )}
      {h && hover !== null && (
        <Tip x={x(hover)} y={PAD.top} width={width}>
          <div className="viz-tip__title">{h.label}</div>
          <div className="viz-tip__row">
            <Swatch color="var(--viz-1)" />
            This period <b>{format(h.value)}</b>
          </div>
          {h.compare !== undefined && (
            <div className="viz-tip__row">
              <Swatch color="var(--viz-compare)" line />
              {compareLabel} <b>{format(h.compare)}</b>
            </div>
          )}
          {h.detail && <div className="viz-tip__muted">{h.detail}</div>}
        </Tip>
      )}
    </div>
  );
}

function roundedTop(x: number, y: number, w: number, h: number, r: number): string {
  const rr = Math.min(r, h);
  return `M${x},${y + h} V${y + rr} Q${x},${y} ${x + rr},${y} H${x + w - rr} Q${x + w},${y} ${x + w},${y + rr} V${y + h} Z`;
}

// ---------------------------------------------------------- multi-line ---

export interface LineSeries {
  id: string;
  label: string;
  color: string;
  values: number[];
}

/** One line per rep. Hovering a name in the legend or a line brings it forward. */
export function MultiLineChart({
  labels,
  series,
  format,
  height = 260,
  onPick,
}: {
  labels: string[];
  series: LineSeries[];
  format: (v: number) => string;
  height?: number;
  onPick?: (id: string) => void;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const [focus, setFocus] = useState<string | null>(null);

  const max = Math.max(1, ...series.flatMap((s) => s.values));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const iw = Math.max(0, width - PAD.left - PAD.right);
  const ih = height - PAD.top - PAD.bottom;
  const step = labels.length > 1 ? iw / (labels.length - 1) : 0;
  const x = (i: number) => PAD.left + step * i;
  const y = (v: number) => PAD.top + ih - (v / top) * ih;
  const labelEvery = Math.max(1, Math.ceil(labels.length / Math.max(1, Math.floor(iw / 56))));

  return (
    <div className="viz" ref={ref} onMouseLeave={() => setHover(null)}>
      <Legend items={series.map((s) => ({ label: s.label, color: s.color, line: true }))} />
      {width > 0 && (
        <svg
          width={width}
          height={height}
          role="img"
          aria-label="Reps over time"
          onMouseMove={(e) => {
            const box = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
            const i = Math.round((e.clientX - box.left - PAD.left) / (step || 1));
            setHover(Math.max(0, Math.min(labels.length - 1, i)));
          }}
        >
          {ticks.map((t) => (
            <g key={t}>
              <line className="viz-grid" x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} />
              <text className="viz-axis" x={PAD.left - 8} y={y(t)} dy="0.32em" textAnchor="end">
                {format(t)}
              </text>
            </g>
          ))}
          {labels.map((l, i) =>
            i % labelEvery === 0 ? (
              <text key={i} className="viz-axis" x={x(i)} y={height - 8} textAnchor="middle">
                {l}
              </text>
            ) : null,
          )}
          {hover !== null && (
            <line className="viz-crosshair" x1={x(hover)} x2={x(hover)} y1={PAD.top} y2={PAD.top + ih} />
          )}
          {series.map((s) => (
            <path
              key={s.id}
              className="viz-line"
              style={{
                stroke: s.color,
                opacity: focus && focus !== s.id ? 0.18 : 1,
                cursor: onPick ? 'pointer' : undefined,
              }}
              d={s.values.map((v, i) => `${i ? 'L' : 'M'}${x(i)},${y(v)}`).join(' ')}
              onMouseEnter={() => setFocus(s.id)}
              onMouseLeave={() => setFocus(null)}
              onClick={() => onPick?.(s.id)}
            />
          ))}
          {hover !== null &&
            series.map((s) => (
              <circle key={s.id} className="viz-dot" cx={x(hover)} cy={y(s.values[hover] ?? 0)} r={4} style={{ fill: s.color }} />
            ))}
        </svg>
      )}
      {hover !== null && (
        <Tip x={x(hover)} y={PAD.top + 30} width={width}>
          <div className="viz-tip__title">{labels[hover]}</div>
          {[...series]
            .sort((a, b) => (b.values[hover] ?? 0) - (a.values[hover] ?? 0))
            .map((s) => (
              <div key={s.id} className="viz-tip__row">
                <Swatch color={s.color} line />
                {s.label} <b>{format(s.values[hover] ?? 0)}</b>
              </div>
            ))}
        </Tip>
      )}
    </div>
  );
}

// --------------------------------------------------------- stacked bars ---

export interface StackPoint {
  label: string;
  parts: number[];
}

/** Outstanding by age, stacked. The stack's height is the total owed. */
export function StackedBars({
  points,
  keys,
  colors,
  format,
  height = 240,
}: {
  points: StackPoint[];
  keys: string[];
  colors: string[];
  format: (v: number) => string;
  height?: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const max = Math.max(1, ...points.map((p) => p.parts.reduce((a, b) => a + b, 0)));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1];
  const iw = Math.max(0, width - PAD.left - PAD.right);
  const ih = height - PAD.top - PAD.bottom;
  const band = points.length ? iw / points.length : 0;
  const barW = Math.max(2, Math.min(36, band - 4));
  const x = (i: number) => PAD.left + band * i + band / 2;
  const y = (v: number) => PAD.top + ih - (v / top) * ih;
  const labelEvery = Math.max(1, Math.ceil(points.length / Math.max(1, Math.floor(iw / 56))));
  const h = hover !== null ? points[hover] : null;

  return (
    <div className="viz" ref={ref} onMouseLeave={() => setHover(null)}>
      <Legend items={keys.map((k, i) => ({ label: k, color: colors[i] }))} />
      {width > 0 && (
        <svg width={width} height={height} role="img" aria-label="Outstanding by age">
          {ticks.map((t) => (
            <g key={t}>
              <line className="viz-grid" x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} />
              <text className="viz-axis" x={PAD.left - 8} y={y(t)} dy="0.32em" textAnchor="end">
                {format(t)}
              </text>
            </g>
          ))}
          {points.map((p, i) => {
            let acc = 0;
            return (
              <g key={i} opacity={hover === null || hover === i ? 1 : 0.55}>
                {p.parts.map((v, k) => {
                  if (!(v > 0)) return null;
                  const y0 = y(acc);
                  acc += v;
                  const y1 = y(acc);
                  // A 1px surface gap between segments keeps neighbours apart.
                  return (
                    <rect
                      key={k}
                      x={x(i) - barW / 2}
                      y={y1}
                      width={barW}
                      height={Math.max(0, y0 - y1 - 1)}
                      style={{ fill: colors[k] }}
                    />
                  );
                })}
                {i % labelEvery === 0 && (
                  <text className="viz-axis" x={x(i)} y={height - 8} textAnchor="middle">
                    {p.label}
                  </text>
                )}
                <rect
                  x={PAD.left + band * i}
                  y={PAD.top}
                  width={band}
                  height={ih}
                  fill="transparent"
                  onMouseEnter={() => setHover(i)}
                />
              </g>
            );
          })}
        </svg>
      )}
      {h && hover !== null && (
        <Tip x={x(hover)} y={PAD.top + 30} width={width}>
          <div className="viz-tip__title">
            {h.label} · <b>{format(h.parts.reduce((a, b) => a + b, 0))}</b>
          </div>
          {[...keys].reverse().map((k) => {
            const i = keys.indexOf(k);
            return (
              <div key={k} className="viz-tip__row">
                <Swatch color={colors[i]} />
                {k} <b>{format(h.parts[i])}</b>
              </div>
            );
          })}
        </Tip>
      )}
    </div>
  );
}

// ------------------------------------------------------------- h-bars ---

export interface HBarRow {
  id: string;
  label: string;
  value: number;
  /** Right-hand text, e.g. "₹2.4L · 31%". */
  note: string;
  title?: string;
}

/** Ranked horizontal bars, one colour — the length is the information. */
export function HBars({ rows, onPick, active }: { rows: HBarRow[]; onPick?: (id: string) => void; active?: string }) {
  const max = Math.max(1, ...rows.map((r) => r.value));
  return (
    <div className="viz-hbars">
      {rows.map((r) => (
        <button
          key={r.id}
          type="button"
          className={`viz-hbar ${active === r.id ? 'is-active' : ''}`}
          onClick={() => onPick?.(r.id)}
          title={r.title}
          disabled={!onPick}
        >
          <span className="viz-hbar__label">{r.label}</span>
          <span className="viz-hbar__track">
            <span className="viz-hbar__fill" style={{ width: `${(r.value / max) * 100}%` }} />
          </span>
          <span className="viz-hbar__note num">{r.note}</span>
        </button>
      ))}
    </div>
  );
}

// ----------------------------------------------------------- sparkline ---

export function Sparkline({ values, width = 84, height = 22 }: { values: number[]; width?: number; height?: number }) {
  const max = Math.max(1, ...values);
  const step = values.length > 1 ? (width - 4) / (values.length - 1) : 0;
  const pts = values.map((v, i) => `${2 + i * step},${height - 2 - (v / max) * (height - 4)}`);
  const last = pts[pts.length - 1]?.split(',');
  return (
    <svg width={width} height={height} className="viz-spark" aria-hidden>
      {pts.length > 1 && <polyline points={pts.join(' ')} />}
      {last && <circle cx={last[0]} cy={last[1]} r={2.2} />}
    </svg>
  );
}
