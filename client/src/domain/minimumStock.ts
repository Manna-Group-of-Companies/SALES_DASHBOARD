/**
 * Minimum stock: the shelf, the run, and how an order divides between them.
 *
 * Four numbers describe a pool and they are all different things:
 *
 *   - **minimum** — the level to hold. `Manna Minimum Stock Item.qty`.
 *   - **shelf** — what physically exists. `Manna Minimum Stock Batch.qty`.
 *     Reading the pool's own `qty` as the shelf is the mistake this module
 *     exists to prevent; on the live site `120 AJAX 69` holds a minimum of 2
 *     against 4 on the shelf, and `160 RTS 99` a minimum of 10 against 0.
 *   - **reserved** — what reps have already booked off the shelf.
 *   - **in production** — a run raised in SAP to refill the pool. **Intent,
 *     not stock.** It never counts towards availability.
 *
 * The rule that must not be broken: **never add the shelf and the run
 * together.** An empty shelf with a full run still sells nothing off the
 * shelf. They are two pools with two counters and two claims.
 */

import type {
  MinStockLine,
  OrderLine,
  StockReservationRow,
} from './types';
import { FULFILMENT_MODE, RESERVATION_SOURCE } from '@/api/endpoints';

// ------------------------------------------------------- fulfilment mode ---

/** What a line ended up being served from. Reported, never chosen. */
export type FulfilmentMode =
  | 'minimum_stock'
  | 'production_run'
  | 'new_production'
  | 'undecided';

export function modeOf(line: Pick<OrderLine, 'fulfilmentMode'>): FulfilmentMode {
  switch ((line.fulfilmentMode ?? '').trim()) {
    case FULFILMENT_MODE.minimumStock:
      return 'minimum_stock';
    case FULFILMENT_MODE.productionRun:
      return 'production_run';
    case FULFILMENT_MODE.newProduction:
      return 'new_production';
    default:
      return 'undecided';
  }
}

export function modeValue(mode: FulfilmentMode): string {
  if (mode === 'minimum_stock') return FULFILMENT_MODE.minimumStock;
  if (mode === 'production_run') return FULFILMENT_MODE.productionRun;
  if (mode === 'new_production') return FULFILMENT_MODE.newProduction;
  return FULFILMENT_MODE.undecided;
}

/**
 * How the line reads on screen.
 *
 * "Made to order" is deliberately what an unset mode says. Every line is
 * served from somewhere, and a line nobody booked stock for is being made —
 * "not decided" would suggest a decision is outstanding when none is.
 */
export function modeLabel(mode: FulfilmentMode): string {
  switch (mode) {
    case 'minimum_stock':
      return 'Served from minimum stock';
    case 'production_run':
      return 'Claimed from a production run — not made yet';
    default:
      return 'Made to order';
  }
}

export function modeTone(mode: FulfilmentMode): 'stock' | 'run' | 'make' {
  if (mode === 'minimum_stock') return 'stock';
  if (mode === 'production_run') return 'run';
  return 'make';
}

// ------------------------------------------------------------- the pools ---

/** Rolls and belts together — the unit almost everything here works in. */
export interface Qty {
  rolls: number;
  belts: number;
}

export const NONE: Qty = { rolls: 0, belts: 0 };

const clamp = (n: number) => (Number.isFinite(n) && n > 0 ? n : 0);

/** Free on the shelf: what exists, less what is booked. */
export function shelfAvailable(s: MinStockLine): Qty {
  return {
    rolls: clamp(s.shelfRolls - s.reservedRolls),
    belts: clamp(s.shelfBelts - s.reservedBelts),
  };
}

/**
 * Free on the run: raised, less what reps have claimed.
 *
 * Its own pool with its own counter. Never added to the shelf.
 */
export function runAvailable(s: MinStockLine): Qty {
  return {
    rolls: clamp(s.inProductionRolls - s.reservedInProductionRolls),
    belts: clamp(s.inProductionBelts - s.reservedInProductionBelts),
  };
}

/** How far below the target the **shelf** is. Never measured against free stock. */
export function shortfall(s: MinStockLine): number {
  return clamp(s.minimumRolls - s.shelfRolls);
}

/**
 * Shortfall after the run in flight is counted against it.
 *
 * A pool 20 short with 20 already on order does not need ordering again, so
 * the ask nets the run off — while availability still ignores it entirely.
 */
export function shortfallAfterRun(s: MinStockLine): number {
  return clamp(shortfall(s) - s.inProductionRolls);
}

/** Below the level it is supposed to hold. A run is owed. */
export function belowMinimum(s: MinStockLine): boolean {
  return s.shelfRolls < s.minimumRolls;
}

/**
 * Nothing left to promise.
 *
 * Fires at exactly the minimum, while the quantity still looks right, and it
 * is the alarm that describes reps being turned away right now.
 */
export function fullyBooked(s: MinStockLine): boolean {
  const free = shelfAvailable(s);
  return free.rolls <= 0 && free.belts <= 0;
}

export function needsRun(s: MinStockLine): boolean {
  return belowMinimum(s) || fullyBooked(s);
}

/** both → fully booked → below minimum → healthy. */
export function urgency(s: MinStockLine): 0 | 1 | 2 | 3 {
  const low = belowMinimum(s);
  const booked = fullyBooked(s);
  if (low && booked) return 3;
  if (booked) return 2;
  if (low) return 1;
  return 0;
}

/** Most urgent first; within a band, the biggest shortfall first. */
export function byUrgency(a: MinStockLine, b: MinStockLine): number {
  const d = urgency(b) - urgency(a);
  if (d !== 0) return d;
  const s = shortfall(b) - shortfall(a);
  if (s !== 0) return s;
  return a.itemCode.localeCompare(b.itemCode);
}

export function poolByItem(pool: MinStockLine[]): Map<string, MinStockLine> {
  return new Map(pool.map((s) => [s.itemCode, s]));
}

// --------------------------------------------------------------- the split ---

/**
 * How an order line divides between the shelf and the plant.
 *
 * **An order is never refused for exceeding the pool.** Fifteen rolls against
 * a pool of ten is an order for fifteen: ten come off the shelf and five are
 * made. Only the *reservation* is capped.
 */
export interface Split {
  ordered: Qty;
  /** Actually booked against a pool — from the reservation rows. */
  reserved: Qty;
  /** The remainder, which has to be manufactured. */
  toMake: Qty;
  /** True when nothing at all came from a pool. */
  allMadeToOrder: boolean;
  /** True when part came from a pool and part did not. */
  isSplit: boolean;
}

/**
 * The split for one line, from its live reservations.
 *
 * The order line does not carry it — a reservation is a separate record — so
 * this is derived. Callers that cannot read the reservations must show **no
 * split at all** rather than a guessed one; see `SPLIT_UNKNOWN`.
 */
export function splitOf(line: OrderLine, reservations: StockReservationRow[], orderId: string): Split {
  const ordered: Qty = { rolls: line.rolls || 0, belts: line.looseBelts || 0 };
  const reserved = heldBy(reservations, line.itemCode, orderId);
  const toMake: Qty = {
    rolls: clamp(ordered.rolls - reserved.rolls),
    belts: clamp(ordered.belts - reserved.belts),
  };
  const nothingReserved = reserved.rolls <= 0 && reserved.belts <= 0;
  const nothingToMake = toMake.rolls <= 0 && toMake.belts <= 0;
  return {
    ordered,
    reserved,
    toMake,
    allMadeToOrder: nothingReserved,
    // Both halves non-empty. Calling a wholly-made line a "split" would have
    // somebody telling a customer half of it is in stock.
    isSplit: !nothingReserved && !nothingToMake,
  };
}

/**
 * What actually covers a line, once the free shelf is taken into account.
 *
 * `splitOf` answers "how much of this line is *held*" and calls the remainder
 * `toMake`. That is only the same thing when the shelf is empty. Live on
 * 12 Aug 2026, `155 MSR 87` had a shelf of 4, one roll held by
 * SAL-ORD-2026-00129, and the manager raised that line to 2 — so one roll was
 * uncovered while **three sat free**, and the screen reported it as "to be
 * made". A production run raised off that reading would have manufactured a
 * roll that was already on the shelf.
 *
 * Uncovered and unavailable are different states and get different names:
 *
 *   - `reserved` — a reservation row holds it. Nobody can take it.
 *   - `availableNow` — nothing holds it, but the shelf has it free. It is one
 *     booking away, not one production run away.
 *   - `toMake` — nothing holds it and the shelf does not have it. This, and
 *     only this, is what has to be manufactured.
 *
 * `free` is the *unbooked* shelf — `positionFor(...).freeForOthers`, which is
 * already net of every other order's hold. Passing the gross shelf here would
 * offer stock that somebody else has booked.
 */
export interface Cover {
  reserved: Qty;
  availableNow: Qty;
  toMake: Qty;
  /** True when the uncovered part cannot be met from stock at all. */
  needsProduction: boolean;
}

export function coverFor(split: Split, free: Qty): Cover {
  const availableNow: Qty = {
    rolls: Math.min(split.toMake.rolls, clamp(free.rolls)),
    belts: Math.min(split.toMake.belts, clamp(free.belts)),
  };
  const toMake: Qty = {
    rolls: clamp(split.toMake.rolls - availableNow.rolls),
    belts: clamp(split.toMake.belts - availableNow.belts),
  };
  return {
    reserved: split.reserved,
    availableNow,
    toMake,
    needsProduction: toMake.rolls > 0 || toMake.belts > 0,
  };
}

/**
 * How much of an item an order should be holding, given what the shelf has.
 *
 * The rule the sales manager stated, in one line: **if it is on the shelf, it
 * comes off the shelf.** Production is only for the part the shelf has not
 * got. Anything less means an order that could have shipped tomorrow is queued
 * behind a run, and the rolls it should have taken sit unbooked for another
 * rep to take.
 *
 * `reservedTotal` is the sum of the live reservation rows for the item —
 * everybody's, including this order's — never the pool's stored counter, which
 * drifts. `held` is this order's share of that sum, so subtracting it gives
 * what *other* orders hold, and the shelf less that is what this order may
 * take.
 *
 * Rolls and belts draw on the SAME shelf. They were planned on separate axes
 * until 21 August 2026, on the reasoning that "a roll is not a belt until
 * somebody cuts it" — which is true, and which nonetheless produced the wrong
 * answer: a pool of 48 whole rolls and no loose belts covered zero belts, so a
 * rep ordering five rolls and one belt was told the belt would be made to
 * order while 48 rolls sat on the shelf. Somebody cuts it. That is what
 * `allocateFromPool` does, and it is pinned by
 * `shared/fixtures/belt_from_roll.json`.
 */
export interface HoldPlan {
  /** What the order should hold once this is applied. */
  target: Qty;
  /** The change against what it holds now. Negative gives stock back. */
  delta: Qty;
  /** What the shelf cannot cover. This, and only this, is production. */
  short: Qty;
  /** What the pool's reserved counter should read afterwards. */
  counter: Qty;
  /** Whether anything needs writing at all. */
  changed: boolean;
}

/** What one order can take off a pool, and what is left for production. */
export interface PoolAllocation {
  /** Whole rolls served from the pool. */
  rolls: number;
  /** Belts served, whether loose or cut from a roll opened for them. */
  belts: number;
  /**
   * Rolls broken into to cover [belts]. They leave the roll count; the belts
   * not sold stay in the pool as loose stock, which is what the reserved
   * counters already imply — see `MinStock.availableLooseBelts` on the phone.
   */
  rollsOpened: number;
  /** What the pool could not cover. This, and only this, is production. */
  shortRolls: number;
  shortBelts: number;
}

/**
 * Split an order line between a minimum-stock pool and production.
 *
 * **A belt comes out of a roll.** Serving one against a pool with no loose
 * belts opens a whole roll: the belt goes out and the rest of that roll stays
 * in the pool. Treating belts as coverable only by loose belts is what sent a
 * single belt to production while 48 rolls sat on the shelf.
 *
 * Order of service, and why:
 *
 *  - **Loose belts before opening a roll.** A roll already cut should be
 *    finished before another one is broken into.
 *  - **Whole rolls before rolls opened for belts.** Only bites when the pool
 *    cannot cover everything, and there it gives the customer more product —
 *    a whole roll rather than one belt cut off it.
 *  - **Nothing is cut when `beltsPerRoll` is 0 or less.** That means the item
 *    is not sold in belts, or its master is incomplete; either way selling
 *    belts that cannot be cut is the worse mistake.
 *
 * Pinned by `shared/fixtures/belt_from_roll.json`, which both suites read.
 */
export function allocateFromPool(input: {
  wantRolls: number;
  wantBelts: number;
  poolRolls: number;
  poolBelts: number;
  beltsPerRoll: number;
}): PoolAllocation {
  const wantRolls = clamp(input.wantRolls);
  const wantBelts = clamp(input.wantBelts);
  const poolRolls = clamp(input.poolRolls);
  const poolBelts = clamp(input.poolBelts);
  const perRoll = clamp(input.beltsPerRoll);

  const rolls = Math.min(wantRolls, poolRolls);

  const fromLoose = Math.min(wantBelts, poolBelts);
  let stillWanted = wantBelts - fromLoose;

  let rollsOpened = 0;
  let fromOpened = 0;
  if (stillWanted > 0 && perRoll > 0) {
    // Whole rolls only: half a roll cannot be opened, and what is left of the
    // pool after the whole rolls above have been promised is all there is.
    const spare = Math.floor(poolRolls - rolls);
    rollsOpened = Math.min(Math.ceil(stillWanted / perRoll), Math.max(0, spare));
    fromOpened = Math.min(stillWanted, rollsOpened * perRoll);
    stillWanted -= fromOpened;
  }

  const belts = fromLoose + fromOpened;
  return {
    rolls,
    belts,
    rollsOpened,
    shortRolls: wantRolls - rolls,
    shortBelts: wantBelts - belts,
  };
}

export function holdPlan(input: {
  ordered: Qty;
  held: Qty;
  shelf: Qty;
  reservedTotal: Qty;
  /**
   * From the Item master. Absent means "not cuttable", which is the safe
   * reading for an item that is not sold in belts or whose master is
   * incomplete — it can only ever narrow what the pool is said to cover.
   */
  beltsPerRoll?: number;
}): HoldPlan {
  const heldRolls = clamp(input.held.rolls);
  const heldBelts = clamp(input.held.belts);

  // The shelf, less every OTHER order's hold.
  const freeRolls = clamp(input.shelf.rolls - (input.reservedTotal.rolls - heldRolls));
  const freeBelts = clamp(input.shelf.belts - (input.reservedTotal.belts - heldBelts));

  const allocated = allocateFromPool({
    wantRolls: input.ordered.rolls,
    wantBelts: input.ordered.belts,
    poolRolls: freeRolls,
    poolBelts: freeBelts,
    beltsPerRoll: input.beltsPerRoll ?? 0,
  });

  const target: Qty = { rolls: allocated.rolls, belts: allocated.belts };

  return {
    target,
    delta: { rolls: target.rolls - heldRolls, belts: target.belts - heldBelts },
    short: { rolls: allocated.shortRolls, belts: allocated.shortBelts },
    // Rebuilt from the row sum rather than nudged, so a counter that has
    // drifted away from the rows is repaired by the same write.
    counter: {
      rolls: input.reservedTotal.rolls - heldRolls + target.rolls,
      belts: input.reservedTotal.belts - heldBelts + target.belts,
    },
    changed: target.rolls !== heldRolls || target.belts !== heldBelts,
  };
}

/** What this order holds of an item, from the Active reservation rows only. */
export function heldBy(
  reservations: StockReservationRow[],
  itemCode: string,
  orderId: string,
): Qty {
  let rolls = 0;
  let belts = 0;
  for (const r of reservations) {
    if (r.status !== 'Active' || r.itemCode !== itemCode) continue;
    if (r.salesOrder !== orderId && r.leadOrder !== orderId) continue;
    rolls += r.rolls;
    belts += r.looseBelts;
  }
  return { rolls, belts };
}

/** Whether this order's hold on an item came off the shelf or off a run. */
export function heldFrom(
  reservations: StockReservationRow[],
  itemCode: string,
  orderId: string,
): 'shelf' | 'run' | 'none' {
  for (const r of reservations) {
    if (r.status !== 'Active' || r.itemCode !== itemCode) continue;
    if (r.salesOrder !== orderId && r.leadOrder !== orderId) continue;
    return r.source === RESERVATION_SOURCE.productionRun ? 'run' : 'shelf';
  }
  return 'none';
}

/**
 * What a line was **actually** served from.
 *
 * Derived from the reservation rows first, and only then from
 * `custom_fulfilment_mode`. That order matters: the field-sales app does not
 * currently write the field at all — SAL-ORD-2026-00106 holds 4 rolls and 2
 * belts against MSR-00027 with `custom_fulfilment_mode` still empty — so
 * trusting the field would report a stocked line as "Made to order" and tell a
 * manager to build goods that are already on the shelf.
 *
 * The reservation is the record of what was held. The field is a label that
 * may or may not have been applied.
 *
 * When the rows could not be read, `reservationsLoaded = false` falls back to
 * the stored field rather than concluding nothing was ever booked.
 */
export function servedFrom(
  line: Pick<OrderLine, 'fulfilmentMode' | 'itemCode'>,
  reservations: StockReservationRow[],
  orderId: string,
  reservationsLoaded = true,
): FulfilmentMode {
  if (reservationsLoaded) {
    const from = heldFrom(reservations, line.itemCode, orderId);
    if (from === 'shelf') return 'minimum_stock';
    if (from === 'run') return 'production_run';
  }
  const stored = modeOf(line);
  // No hold and no label: it is being made. Not "undecided" — every line is
  // served from somewhere, and nobody owes a decision here.
  return stored === 'undecided' && reservationsLoaded ? 'new_production' : stored;
}

/** "10 rolls from minimum stock, 5 rolls made to order" — or the honest whole. */
export function describeSplit(s: Split): string {
  const q = (x: Qty) => {
    const parts: string[] = [];
    if (x.rolls) parts.push(`${x.rolls} roll${x.rolls === 1 ? '' : 's'}`);
    if (x.belts) parts.push(`${x.belts} belt${x.belts === 1 ? '' : 's'}`);
    return parts.join(' + ') || '0';
  };
  if (s.allMadeToOrder) return 'This whole line will be made to order';
  if (!s.isSplit) return `${q(s.reserved)} from minimum stock`;
  return `Split: ${q(s.reserved)} from minimum stock, ${q(s.toMake)} made to order`;
}

// ----------------------------------------------------- reconciling counters ---

/**
 * What an item is **actually** holding, summed from the reservation rows.
 *
 * The pool's `custom_reserved_qty` is a hand-maintained cache of this sum, and
 * on 8 Aug 2026 it was proven wrong: a Sales Order deleted in the Desk left
 * `120 AJAX 69` claiming 3 rolls and 2 belts booked with no reservation behind
 * them, quietly blocking stock that was free.
 *
 * Trusting the rows is safe both ways. Rows ahead of the counter report *more*
 * held, which is conservative; rows behind it free stock that genuinely is.
 */
export function trueReserved(reservations: StockReservationRow[], itemCode: string): Qty {
  let rolls = 0;
  let belts = 0;
  for (const r of reservations) {
    if (r.status !== 'Active' || r.itemCode !== itemCode) continue;
    if (r.source === RESERVATION_SOURCE.productionRun) continue; // the other pool
    rolls += r.rolls;
    belts += r.looseBelts;
  }
  return { rolls, belts };
}

export interface Drift {
  itemCode: string;
  storedRolls: number;
  actualRolls: number;
  storedBelts: number;
  actualBelts: number;
  shelfRolls: number;
}

export function findDrift(pool: MinStockLine[], reservations: StockReservationRow[]): Drift[] {
  const out: Drift[] = [];
  for (const s of pool) {
    const actual = trueReserved(reservations, s.itemCode);
    if (actual.rolls === s.reservedRolls && actual.belts === s.reservedBelts) continue;
    out.push({
      itemCode: s.itemCode,
      storedRolls: s.reservedRolls,
      actualRolls: actual.rolls,
      storedBelts: s.reservedBelts,
      actualBelts: actual.belts,
      shelfRolls: s.shelfRolls,
    });
  }
  return out;
}

// ------------------------------------------------ the line's stock position ---

/**
 * Everything a sales manager needs to read one line's stock position.
 *
 * The five figures are separate on purpose. `SAL-ORD-2026-00106` is 8 rolls +
 * 2 belts with 4 + 2 reserved, and the screen said only "booked by this order:
 * 4 rolls + 2 belts" — nothing said the order was for eight, or that four had
 * to be made. Production's line then read "8 rolls" while four sat in the
 * plant, so a run raised off that screen would have been for double.
 */
export interface StockPosition {
  pooled: boolean;
  minimum: number;
  shelf: number;
  heldByThisOrder: Qty;
  heldByOthers: Qty;
  freeForOthers: Qty;
  inProduction: Qty;
  /** Stored counter minus the truth. Positive means phantom bookings. */
  drift: number;
  driftBelts: number;
}

export function positionFor(
  itemCode: string,
  pool: Map<string, MinStockLine>,
  reservations: StockReservationRow[],
  orderId: string,
  /**
   * Whether the reservation rows were actually read. If the fetch failed, an
   * empty array is indistinguishable from "nothing reserved" — reconciling
   * against it would free every roll on the site at once. When unavailable
   * this falls back to the stored counter, which over-reserves at worst.
   */
  reservationsLoaded = true,
): StockPosition {
  const s = pool.get(itemCode);
  const here = heldBy(reservations, itemCode, orderId);
  if (!s) {
    return {
      pooled: false,
      minimum: 0,
      shelf: 0,
      heldByThisOrder: here,
      heldByOthers: NONE,
      freeForOthers: NONE,
      inProduction: NONE,
      drift: 0,
      driftBelts: 0,
    };
  }

  const actual = reservationsLoaded
    ? trueReserved(reservations, itemCode)
    : { rolls: s.reservedRolls, belts: s.reservedBelts };

  return {
    pooled: true,
    minimum: s.minimumRolls,
    shelf: s.shelfRolls,
    heldByThisOrder: here,
    heldByOthers: {
      rolls: clamp(actual.rolls - here.rolls),
      belts: clamp(actual.belts - here.belts),
    },
    freeForOthers: {
      rolls: clamp(s.shelfRolls - actual.rolls),
      belts: clamp(s.shelfBelts - actual.belts),
    },
    inProduction: { rolls: s.inProductionRolls, belts: s.inProductionBelts },
    drift: s.reservedRolls - actual.rolls,
    driftBelts: s.reservedBelts - actual.belts,
  };
}

/** Days an aged batch has been sitting. */
export function daysInStock(since: string | undefined, now: Date): number | null {
  if (!since) return null;
  const then = new Date(`${since.slice(0, 10)}T00:00:00`);
  if (Number.isNaN(then.getTime())) return null;
  const days = Math.floor((now.getTime() - then.getTime()) / 86_400_000);
  return days > 0 ? days : null;
}
