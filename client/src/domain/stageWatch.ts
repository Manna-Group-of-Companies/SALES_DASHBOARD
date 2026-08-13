/**
 * What a rep or sales manager is told when production moves an item.
 *
 * **Paired with `app/lib/core/stage_watch.dart`.** Both read
 * `shared/fixtures/stage_watch.json` in their tests. See `shared/README.md`.
 *
 * **Why a stored diff rather than a push.** Two things rule out anything else
 * on this site today:
 *
 *   - there are **no Server Scripts**, so nothing can fire when production
 *     saves a stage;
 *   - `Notification Log` — Frappe's own per-user notification store, which is
 *     otherwise exactly right — grants role `All` `read: 1, create: 0`. A rep's
 *     or production manager's login cannot write one over the API. (The
 *     dashboard has been writing to a `Sales Notification` doctype that **does
 *     not exist on this site**, fire-and-forget, so every notification it has
 *     ever raised has silently gone nowhere.)
 *
 * So each device remembers the stages it last showed for an order, and the
 * difference is the news. It is honest — it can only ever report a real change
 * between two things the reader saw — and it needs no schema, no permission
 * change and no server support. What it cannot do is buzz a phone that never
 * opens the order; see `shared/DIVERGENCES.md` item 7 for what that would take.
 *
 * **A split line has two stages that finish separately**, so each is watched on
 * its own axis. Reporting "this line moved" would hide that the other half has
 * not.
 */

export const STAGE_FIELD = {
  made: 'custom_production_stage',
  shelf: 'custom_stock_stage',
} as const;

/** Which half of a line moved. */
export type StagePart = 'made' | 'shelf';

/** Line id → `"<made>|<shelf>"`. Flat so it stores as one string. */
export type StageSnapshot = Record<string, string>;

export interface StageChange {
  lineId: string;
  itemName: string;
  part: StagePart;
  from: string;
  to: string;
}

/** A row as ERPNext returns it. */
type Row = Record<string, unknown>;

/** Frappe returns an unset Data field as null, '' or the string 'null'. */
function stage(v: unknown): string {
  const s = typeof v === 'string' ? v.trim() : v == null ? '' : String(v).trim();
  return s === 'null' || s === 'undefined' ? '' : s;
}

const key = (r: Row) => String(r.name ?? '');

/** What this device is showing now, to be remembered until the next look. */
export function snapshotOf(lines: Row[]): StageSnapshot {
  const out: StageSnapshot = {};
  for (const l of lines) {
    const id = key(l);
    if (!id) continue;
    out[id] = `${stage(l[STAGE_FIELD.made])}|${stage(l[STAGE_FIELD.shelf])}`;
  }
  return out;
}

/**
 * What moved since the snapshot was taken.
 *
 * `previous` of `null` — an order this device has never opened — reports
 * **nothing**. A rep opening a month-old order must not be shown fifty changes
 * they have known about for weeks; the first look is what establishes the
 * baseline, not what generates the news.
 *
 * Lines added or removed since are not stage changes and are not reported. A
 * stage going *backwards* is, and deliberately: production correcting itself is
 * the change a rep most needs, because they may already have promised a date.
 */
export function changesSince(previous: StageSnapshot | null, lines: Row[]): StageChange[] {
  if (!previous) return [];
  const out: StageChange[] = [];

  for (const l of lines) {
    const id = key(l);
    const before = previous[id];
    // Not seen last time: a new line, not a change to an old one.
    if (!id || before === undefined) continue;

    const [madeBefore = '', shelfBefore = ''] = before.split('|');
    const madeNow = stage(l[STAGE_FIELD.made]);
    const shelfNow = stage(l[STAGE_FIELD.shelf]);
    const itemName = String(l.item_name ?? l.item_code ?? id);

    if (madeNow !== madeBefore) {
      out.push({ lineId: id, itemName, part: 'made', from: madeBefore, to: madeNow });
    }
    if (shelfNow !== shelfBefore) {
      out.push({ lineId: id, itemName, part: 'shelf', from: shelfBefore, to: shelfNow });
    }
  }
  return out;
}

/** Which line ids moved, for highlighting the rows that did. */
export function changedLineIds(changes: StageChange[]): Set<string> {
  return new Set(changes.map((c) => c.lineId));
}

/** "the part being made" / "the part off the shelf" — never just "the line". */
export function partLabel(part: StagePart): string {
  return part === 'made' ? 'being made' : 'from stock';
}

/** "Not started" reads better than an empty cell for a stage nobody has set. */
export function stageText(s: string): string {
  return s.trim() === '' ? 'Not started' : s;
}

/** "160 SR 99 (being made): Cutting → Curing" */
export function describeChange(c: StageChange): string {
  return `${c.itemName} (${partLabel(c.part)}): ${stageText(c.from)} → ${stageText(c.to)}`;
}

// ------------------------------------------------------------- storage ---

const STORE_PREFIX = 'stageSeen:';

/**
 * Per browser, per order. Deliberately **not** shared between devices: it is a
 * record of what *this* reader has been shown, and syncing it would mean a
 * manager's laptop silently marking a rep's phone as caught up.
 */
export function loadSeen(orderId: string): StageSnapshot | null {
  try {
    const raw = localStorage.getItem(STORE_PREFIX + orderId);
    return raw ? (JSON.parse(raw) as StageSnapshot) : null;
  } catch {
    // A blocked or full localStorage must not take the order screen down.
    return null;
  }
}

export function saveSeen(orderId: string, snapshot: StageSnapshot): void {
  try {
    localStorage.setItem(STORE_PREFIX + orderId, JSON.stringify(snapshot));
  } catch {
    /* nothing to do — the worst case is the changes show again next time */
  }
}
