/**
 * What the shelf has, and how an order line divides between it and the plant.
 *
 * WHAT THIS USED TO BE
 *
 * Four numbers described a *pool* — a minimum to hold, the dated batches
 * making up the shelf, what reps had reserved off it, and a production run
 * raised to refill it with its own separate claims — and most of this module
 * was the arithmetic keeping those four apart.
 *
 * All four are gone, on 17 September 2026. Checked against the live site:
 * every one of the 129 pool rows carried a minimum of **zero**, so nothing
 * built on the minimum had ever been able to fire; the batch rows were a
 * hand-typed snapshot from 10 September that *beat* SAP's live figure; and
 * SAP commits stock against its own sales orders, so subtracting an ERPNext
 * reservation on top deducted the same roll twice.
 *
 * What is left is one figure per item — available to promise, straight from
 * SAP — and the split, which is a *display*: it tells a manager how much of a
 * line the shelf can cover today and how much has to be made. It books
 * nothing, because nothing here books anything any more.
 */

import type { MinStockLine, OrderLine } from './types';
import { FULFILMENT_MODE } from '@/api/endpoints';

// ------------------------------------------------------- fulfilment mode ---

/** What a line is to be served from. A note for the floor; it moves no stock. */
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
 * served from somewhere, and a line nobody marked is being made — "not
 * decided" would suggest a decision is outstanding when none is.
 */
export function modeLabel(mode: FulfilmentMode): string {
  switch (mode) {
    case 'minimum_stock':
      return 'Served from stock';
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

/**
 * What a line is served from.
 *
 * It used to be derived from the live reservation rows first and the stored
 * `custom_fulfilment_mode` only as a fallback, because the field-sales app
 * booked stock without ever writing the field — so trusting the field alone
 * reported a stocked line as "Made to order". There are no reservation rows
 * now, and the field is the only record there is.
 */
export function servedFrom(
  line: Pick<OrderLine, 'fulfilmentMode' | 'itemCode'>,
): FulfilmentMode {
  const stored = modeOf(line);
  return stored === 'undecided' ? 'new_production' : stored;
}

// ------------------------------------------------------------- the shelf ---

/** Rolls and belts together — the unit almost everything here works in. */
export interface Qty {
  rolls: number;
  belts: number;
}

export const NONE: Qty = { rolls: 0, belts: 0 };

const clamp = (n: number) => (Number.isFinite(n) && n > 0 ? n : 0);

/**
 * What can be promised of an item right now.
 *
 * Nothing is subtracted here. SAP has already taken off every quantity
 * committed to an open sales order, whoever raised it; taking an ERPNext
 * figure off as well would deduct the same roll twice.
 *
 * An item whose master carries no weights reports nothing, on instruction —
 * SAP holds it in kilograms and nobody has said what a roll weighs, so there
 * is no honest figure to give. Ask `weightsKnown` before rendering a zero:
 * "not set up" and "we are out" want different things doing about them.
 */
export function shelfAvailable(s: MinStockLine): Qty {
  if (!s.weightsKnown) return NONE;
  return { rolls: clamp(s.availableRolls), belts: clamp(s.availableBelts) };
}

/** Nothing left to promise. */
export function outOfStock(s: MinStockLine): boolean {
  const free = shelfAvailable(s);
  return free.rolls <= 0 && free.belts <= 0;
}

export function poolByItem(pool: MinStockLine[]): Map<string, MinStockLine> {
  return new Map(pool.map((s) => [s.itemCode, s]));
}

// --------------------------------------------------------------- the split ---

/**
 * How an order line divides between the shelf and the plant.
 *
 * **An order is never refused for exceeding what is on the shelf.** Fifteen
 * rolls against eight available is an order for fifteen: eight come off the
 * shelf and seven are made.
 */
export interface Split {
  ordered: Qty;
  /** What the shelf can cover today. */
  fromStock: Qty;
  /** The remainder, which has to be manufactured. */
  toMake: Qty;
  /** True when the shelf covers none of it. */
  allMadeToOrder: boolean;
  /** True when part comes off the shelf and part does not. */
  isSplit: boolean;
}

/**
 * The split for one line against what is free.
 *
 * `free` is `shelfAvailable(...)` for the item — already net of every open
 * SAP order, including this one once it has reached SAP. That last part is
 * worth knowing: an order that has been pushed is counted in its own
 * deduction, so a line can read as "to be made" once SAP has committed the
 * stock to it. That is correct — the rolls are spoken for, by this order.
 */
export function splitOf(
  line: Pick<OrderLine, 'rolls' | 'looseBelts'>,
  free: Qty,
  beltsPerRoll = 0,
): Split {
  const ordered: Qty = { rolls: line.rolls || 0, belts: line.looseBelts || 0 };
  const allocated = allocateFromPool({
    wantRolls: ordered.rolls,
    wantBelts: ordered.belts,
    poolRolls: free.rolls,
    poolBelts: free.belts,
    beltsPerRoll,
  });
  const fromStock: Qty = { rolls: allocated.rolls, belts: allocated.belts };
  const toMake: Qty = {
    rolls: clamp(allocated.shortRolls),
    belts: clamp(allocated.shortBelts),
  };
  const nothingFromStock = fromStock.rolls <= 0 && fromStock.belts <= 0;
  const nothingToMake = toMake.rolls <= 0 && toMake.belts <= 0;
  return {
    ordered,
    fromStock,
    toMake,
    allMadeToOrder: nothingFromStock,
    // Both halves non-empty. Calling a wholly-made line a "split" would have
    // somebody telling a customer half of it is in stock.
    isSplit: !nothingFromStock && !nothingToMake,
  };
}

/** What one order can take off the shelf, and what is left for production. */
export interface PoolAllocation {
  /** Whole rolls served from stock. */
  rolls: number;
  /** Belts served, whether loose or cut from a roll opened for them. */
  belts: number;
  /**
   * Rolls broken into to cover [belts]. They leave the roll count; the belts
   * not sold stay on the shelf as loose stock.
   */
  rollsOpened: number;
  /** What the shelf could not cover. This, and only this, is production. */
  shortRolls: number;
  shortBelts: number;
}

/**
 * Split an order line between the shelf and production.
 *
 * **A belt comes out of a roll.** Serving one against a shelf with no loose
 * belts opens a whole roll: the belt goes out and the rest of that roll stays
 * on the shelf. Treating belts as coverable only by loose belts is what sent a
 * single belt to production while 48 rolls sat on the shelf.
 *
 * Order of service, and why:
 *
 *  - **Loose belts before opening a roll.** A roll already cut should be
 *    finished before another one is broken into.
 *  - **Whole rolls before rolls opened for belts.** Only bites when the shelf
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
    // shelf after the whole rolls above have been promised is all there is.
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

/** "10 rolls from stock, 5 rolls made to order" — or the honest whole. */
export function describeSplit(s: Split): string {
  const q = (x: Qty) => {
    const parts: string[] = [];
    if (x.rolls) parts.push(`${x.rolls} roll${x.rolls === 1 ? '' : 's'}`);
    if (x.belts) parts.push(`${x.belts} belt${x.belts === 1 ? '' : 's'}`);
    return parts.join(' + ') || '0';
  };
  if (s.allMadeToOrder) return 'This whole line will be made to order';
  if (!s.isSplit) return `${q(s.fromStock)} from stock`;
  return `Split: ${q(s.fromStock)} from stock, ${q(s.toMake)} made to order`;
}

// ------------------------------------------------ the line's stock position ---

/**
 * What a sales manager needs to read one line's stock position.
 *
 * It carried five figures — the minimum, the shelf, what this order held, what
 * others held, what was free — because a reservation could hide most of the
 * story: `SAL-ORD-2026-00106` was 8 rolls + 2 belts with 4 + 2 reserved, and
 * the screen said only "booked by this order: 4 rolls + 2 belts", so a run
 * raised off it would have been for double.
 *
 * There is nothing to attribute now. SAP's figure has every order's claim
 * already inside it, and what the manager needs is that figure and whether it
 * can be trusted.
 */
export interface StockPosition {
  /** False when SAP holds no record of the item at all. */
  stocked: boolean;
  /** False when the item master has no weights, so there is no figure. */
  weightsKnown: boolean;
  available: Qty;
}

export function positionFor(
  itemCode: string,
  pool: Map<string, MinStockLine>,
): StockPosition {
  const s = pool.get(itemCode);
  if (!s) return { stocked: false, weightsKnown: false, available: NONE };
  return {
    stocked: true,
    weightsKnown: s.weightsKnown,
    available: shelfAvailable(s),
  };
}
