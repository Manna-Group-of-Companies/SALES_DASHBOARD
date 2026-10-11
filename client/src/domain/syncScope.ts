/**
 * Which SAP syncs a login's Sync button asks for.
 *
 * DECIDED 25 SEPTEMBER 2026 — every sync reachable wherever its data is read.
 * Until then stock and credit were offered to the Manna Treads sales team
 * only, so the GM, whose approval screens show credit and stock, and the
 * production and stock managers, who read the stock page, could refresh
 * neither. Nothing syncs on a timer, so a sync nobody may ask for simply does
 * not happen.
 *
 *   - **Orders: everyone.** Approved orders go to SAP and SAP's status, edits
 *     and invoices come back. Any unit's order is in that sync.
 *   - **Stock (with the items and the two weight UDFs): everyone except a
 *     login that belongs to another unit.** It is Manna Treads' finished-goods
 *     warehouse, so a Retreads or UAE login — sales or production — has
 *     nothing in it. A login with no unit at all (the GM) reads it too.
 *     `manna_stock_request_sync` accepts any signed-in user.
 *   - **Credit: the Manna Treads sales team and the GM.** The sync reads
 *     MANNA_TREADS_LIVE only, so another unit's press would refresh a book its
 *     customers are not in. The GM approves over-limit orders on this figure;
 *     `manna_sap_request_sync` admits Higher Management from 25 Sep 2026.
 *   - **Pricing is not here.** The MD raises it from /rates, the only screen
 *     that shows SAP prices.
 *   - **The accountant: orders only** (26 Sep 2026). His screen is built from
 *     the order sync — what Hi-Tech delivered, and the Manna Treads orders it
 *     creates. He has no Sales Person, so without this he would read as a
 *     unit-less login and raise stock too; he reads no stock, and his ERPNext
 *     role cannot read Bin.
 *
 * The Dart twin is `app/lib/core/sync_scope.dart`.
 */

import type { User } from './types';
import { parseServerDate } from './serverDate';

export type SyncKind = 'orders' | 'stock' | 'credit';

const TREADS = 'Manna Treads';

export function syncsFor(
  user: Pick<User, 'role' | 'salesCompany' | 'productionUnit'> | null | undefined,
): SyncKind[] {
  if (!user) return [];
  if (user.role === 'accountant') return ['orders'];
  const sales = (user.salesCompany ?? '').trim();
  const unit = (user.productionUnit ?? '').trim();
  // A login's own unit: its Sales Person's company, else the unit it runs.
  const own = sales || unit;
  const out: SyncKind[] = ['orders'];
  if (!own || own === TREADS) out.push('stock');
  if (sales === TREADS || user.role === 'general_manager') out.push('credit');
  return out;
}

// ------------------------------------------------- what the button says ---

const LABEL: Record<SyncKind, string> = {
  orders: 'orders',
  stock: 'stock',
  credit: 'credit limits',
};

/** One sync's state, as the header's Sync button reads it. */
export interface SyncReading {
  kind: SyncKind;
  /** The Single's status: Idle | Queued | Running | Success | Failed. */
  status: string;
  /** The order Single has no Queued status; its raised flag means waiting. */
  queued?: boolean;
  /** When it last ran to the end WITHOUT failing, as the Server Script wrote it. */
  lastSyncAt: string | null;
}

export interface SyncSummary {
  tone: 'ok' | 'warn' | 'busy';
  /** Beside the button. */
  text: string;
  /** The tooltip: each sync on its own line. */
  detail: string;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "today 18:52", "yesterday 09:05", "27 Sep 14:52", "27 Sep 2025 14:52" — or "never". */
export function syncStamp(v: string | null | undefined, now: Date): string {
  const ms = parseServerDate(v);
  if (Number.isNaN(ms)) return 'never';
  const d = new Date(ms);
  const hhmm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(now) - day(d)) / 86_400_000);
  if (days === 0) return `today ${hhmm}`;
  if (days === 1) return `yesterday ${hhmm}`;
  const year = d.getFullYear() === now.getFullYear() ? '' : ` ${d.getFullYear()}`;
  return `${d.getDate()} ${MONTHS[d.getMonth()]}${year} ${hhmm}`;
}

const isBusy = (r: SyncReading) => r.status === 'Running' || r.status === 'Queued' || !!r.queued;

function listOf(kinds: SyncKind[]): string {
  const names = kinds.map((k) => LABEL[k]);
  if (names.length <= 1) return names.join('');
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/** The reading synced longest ago; one that never has counts as oldest of all. */
function oldest(readings: SyncReading[]): SyncReading {
  return readings.reduce((a, b) => {
    const ta = parseServerDate(a.lastSyncAt);
    const tb = parseServerDate(b.lastSyncAt);
    if (Number.isNaN(ta)) return a;
    if (Number.isNaN(tb)) return b;
    return tb < ta ? b : a;
  });
}

/**
 * What the header's Sync button says while nobody is pressing it — the
 * status and the last sync time (11 Oct 2026, the user's request).
 *
 * The time is the OLDEST last good run among the login's syncs: one press runs
 * all of them, so that is when everything the button covers was last brought
 * up to date. Showing the newest would let a stock sync from a fortnight ago
 * hide behind this morning's orders. A sync whose last run failed turns the
 * line amber and is named, with when it last worked. One running or queued —
 * someone else may have pressed — says so first.
 */
export function syncSummary(readings: SyncReading[], now: Date): SyncSummary | null {
  if (readings.length === 0) return null;
  const detail = readings
    .map((r) => {
      const state = isBusy(r)
        ? r.status === 'Running'
          ? ' · running now'
          : ' · queued'
        : r.status === 'Failed'
          ? ' · last run failed'
          : '';
      const name = LABEL[r.kind].charAt(0).toUpperCase() + LABEL[r.kind].slice(1);
      return `${name}: synced ${syncStamp(r.lastSyncAt, now)}${state}`;
    })
    .join('\n');

  const busy = readings.filter(isBusy);
  if (busy.length) {
    return { tone: 'busy', text: `Syncing ${listOf(busy.map((r) => r.kind))}…`, detail };
  }
  const failed = readings.filter((r) => r.status === 'Failed');
  if (failed.length) {
    const kinds = listOf(failed.map((r) => r.kind));
    return {
      tone: 'warn',
      text: `${kinds.charAt(0).toUpperCase()}${kinds.slice(1)} sync failed · last good ${syncStamp(oldest(failed).lastSyncAt, now)}`,
      detail,
    };
  }
  const when = syncStamp(oldest(readings).lastSyncAt, now);
  return { tone: 'ok', text: when === 'never' ? 'Not synced yet' : `Synced ${when}`, detail };
}
