/**
 * Shared pieces of the Managing Director's rates screen.
 *
 * The screen is built from summary rows that open onto their detail —
 * `ExpandRow` — because with the real catalogue a flat table would be
 * thousands of rows long. Long lists inside an opened row go through `Paged`:
 * a filter box and the first 25, with "Show all" one click away.
 */

import { useMemo, useState, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react';
import { Button, Input } from '@/components/ui';
import { itemKind, type SnapItem } from '@/domain/dealerRates';

// ------------------------------------------------------------- format ---

export function rs(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—';
  return `₹${n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function signed(n: number): string {
  if (!n) return '±0';
  return `${n > 0 ? '+' : '−'}${rs(Math.abs(n))}`;
}

export function range(values: number[]): string {
  const v = values.filter((x) => Number.isFinite(x));
  if (!v.length) return '—';
  const lo = Math.min(...v);
  const hi = Math.max(...v);
  return lo === hi ? rs(lo) : `${rs(lo)} – ${rs(hi)}`;
}

/** A Frappe datetime, `2026-09-25 11:46:00`, read as local time on every browser. */
export function parseDt(v: string | null | undefined): Date | null {
  if (!v) return null;
  const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)/.exec(v.trim());
  const d = new Date(m ? `${m[1]}T${m[2]}` : v);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function when(v: string | null | undefined): string {
  const d = parseDt(v);
  if (!d) return 'never';
  const mins = Math.floor((Date.now() - d.getTime()) / 60000);
  const rel =
    mins < 1 ? 'just now' : mins < 60 ? `${mins} min ago` : mins < 1440 ? `${Math.floor(mins / 60)} h ago` : `${Math.floor(mins / 1440)} days ago`;
  return `${d.toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })} (${rel})`;
}

export function kindOf(i: SnapItem): string {
  const k = itemKind(i);
  return k === 'Other' ? i.type || '—' : k;
}

export const matchItem = (i: SnapItem, q: string) => `${i.code} ${i.name} ${i.type}`.toLowerCase().includes(q);

// ----------------------------------------------------------- download ---

export function download(name: string, content: string) {
  const blob = new Blob([content], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export function stampNow(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

// ---------------------------------------------------------- expanding ---

/** Which summary rows are open. */
export function useOpenSet<K>() {
  const [open, setOpen] = useState<Set<K>>(new Set());
  const toggle = (k: K) =>
    setOpen((prev) => {
      const n = new Set(prev);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });
  return { open, toggle, has: (k: K) => open.has(k) };
}

/**
 * A summary row that opens onto its detail. The whole row is the control —
 * click or Enter — and a chevron says so. `cells` are the summary's cells
 * after the chevron; `colSpan` counts the chevron too.
 */
export function ExpandRow({
  open,
  onToggle,
  colSpan,
  cells,
  children,
  tone,
  label,
}: {
  open: boolean;
  onToggle: () => void;
  colSpan: number;
  cells: ReactNode;
  children?: ReactNode;
  tone?: 'changed' | 'warn';
  label?: string;
}) {
  const onKey = (e: KeyboardEvent<HTMLTableRowElement>) => {
    if (e.target !== e.currentTarget) return;
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onToggle();
    }
  };
  return (
    <>
      <tr
        className={`rates__sum ${open ? 'is-open' : ''} ${tone ? `rates__sum--${tone}` : ''}`}
        onClick={onToggle}
        onKeyDown={onKey}
        tabIndex={0}
        aria-expanded={open}
        aria-label={label}
      >
        <td className="rates__chev" aria-hidden>
          {open ? '▾' : '▸'}
        </td>
        {cells}
      </tr>
      {open && (
        <tr className="rates__detail">
          <td colSpan={colSpan}>{children}</td>
        </tr>
      )}
    </>
  );
}

/** Put on an input or button inside a summary row so using it does not open or close the row. */
export const keepRow = {
  onClick: (e: MouseEvent) => e.stopPropagation(),
  onKeyDown: (e: KeyboardEvent) => e.stopPropagation(),
};

/**
 * A long list inside an opened row: a filter box once there are more than ten,
 * the first `pageSize`, and "Show all" for the rest.
 */
export function Paged<T>({
  rows,
  header,
  children,
  match,
  placeholder,
  pageSize = 25,
  empty,
}: {
  rows: T[];
  header: ReactNode;
  children: (row: T) => ReactNode;
  match?: (row: T, q: string) => boolean;
  placeholder?: string;
  pageSize?: number;
  empty?: string;
}) {
  const [q, setQ] = useState('');
  const [all, setAll] = useState(false);
  const needle = q.trim().toLowerCase();
  const shown = useMemo(() => (needle && match ? rows.filter((r) => match(r, needle)) : rows), [rows, needle, match]);
  const visible = all ? shown : shown.slice(0, pageSize);
  return (
    <div className="rates__paged">
      {match && rows.length > 10 && (
        <div className="rates__paged-bar">
          <Input compact value={q} onChange={(e) => setQ(e.target.value)} placeholder={placeholder ?? 'Filter'} />
          <span className="tiny dim">
            {shown.length} of {rows.length}
          </span>
        </div>
      )}
      <div className="table-wrap">
        <table className="table rates__inner">
          <thead>{header}</thead>
          <tbody>{visible.map((r) => children(r))}</tbody>
        </table>
      </div>
      {shown.length === 0 && <div className="small dim rates__pad">{empty ?? 'Nothing matches.'}</div>}
      {!all && shown.length > pageSize && (
        <div className="rates__pad">
          <Button size="sm" variant="ghost" onClick={() => setAll(true)}>
            Show all {shown.length}
          </Button>
          <span className="tiny dim"> showing the first {pageSize}</span>
        </div>
      )}
    </div>
  );
}

/** "Black Pearl ₹5 · Platinum ₹3", kept to one line with a count of the rest. */
export function Chips({ items, max = 4 }: { items: string[]; max?: number }) {
  const head = items.slice(0, max);
  return (
    <span className="rates__chips">
      {head.map((t) => (
        <span key={t} className="rates__chip">
          {t}
        </span>
      ))}
      {items.length > max && <span className="tiny dim">+{items.length - max} more</span>}
    </span>
  );
}
