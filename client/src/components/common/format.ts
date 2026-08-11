import { CURRENCY } from '@/api/config';

/** Indian-format money, e.g. ₹1,84,500. */
export function money(n: number, decimals = 0): string {
  return `${CURRENCY}${n.toLocaleString('en-IN', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals === 0 ? 0 : 2,
  })}`;
}

/** Compact money for tiles: ₹1.85L, ₹12.4Cr. */
export function moneyShort(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1_00_00_000) return `${CURRENCY}${(n / 1_00_00_000).toFixed(2)}Cr`;
  if (abs >= 1_00_000) return `${CURRENCY}${(n / 1_00_000).toFixed(2)}L`;
  if (abs >= 1_000) return `${CURRENCY}${(n / 1_000).toFixed(1)}k`;
  return money(n);
}

export function qty(n: number, uom: string): string {
  const rounded = Math.round(n * 1000) / 1000;
  return `${rounded.toLocaleString('en-IN', { maximumFractionDigits: 3 })} ${uom}`;
}

/** "3 hours ago", "just now" — for timeline and notification rows. */
export function relativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return '—';
  const secs = Math.round((Date.now() - then) / 1000);
  if (secs < 45) return 'just now';
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(iso).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' });
}

/** "Good morning" / "Good afternoon" / "Good evening" — landing-page greeting. */
export function greeting(): string {
  const h = new Date().getHours();
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

export function initials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase() ?? '')
    .join('');
}
