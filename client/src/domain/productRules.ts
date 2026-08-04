/**
 * Per-category quantity, weight and money maths (spec 1.2 – 1.5).
 *
 * Each product family measures itself differently, so every screen that needs a
 * line total funnels through `computeLine` rather than doing its own arithmetic.
 * Change the rules here and the order form, the manager's review and the
 * proforma all move together.
 */

import type { OrderItem, Product, ProductCategory, TinSize } from './types';

// Bonding Gum packaging, fixed by the factory (1.4).
export const BG_KG_PER_ROLL = 5;
export const BG_ROLLS_PER_BOX = 4;
export const BG_KG_PER_BOX = BG_KG_PER_ROLL * BG_ROLLS_PER_BOX; // 20 kg

export const VS_TIN_SIZES: TinSize[] = [10, 30];

/** The unit a category is billed in. */
export function uomFor(category: ProductCategory): string {
  return category === 'VS' ? 'L' : 'Kg';
}

/** How the rate reads on screen — VS is priced by the tin, the rest by weight. */
export function rateUnitFor(category: ProductCategory): string {
  return category === 'VS' ? 'per tin' : 'per kg';
}

/** PCTR only: the weight one loose belt carries (1.2). */
export function weightPerBelt(product: Product): number {
  const rollWeight = product.avgWeightPerRoll ?? 0;
  const belts = product.beltsPerRoll ?? 0;
  if (belts <= 0) return 0;
  return rollWeight / belts;
}

/** What the rep keys, before any derivation. */
export interface LineInput {
  rolls?: number;
  looseBelts?: number;
  kg?: number;
  tins?: number;
  tinSize?: TinSize;
  rate?: number;
}

export interface ComputedLine {
  /** Billable quantity in `uom` — kg for PCTR/CTR/BG, litres for VS. */
  quantity: number;
  uom: string;
  /** Money for the line. */
  amount: number;
  /** Human-readable breakdown, e.g. "12 rolls x 28.5 kg + 3 belts". */
  breakdown: string;
}

/**
 * Turn a rep's keystrokes into a billable quantity and amount.
 *
 * The `rate` passed in should already be the effective rate — the caller
 * decides whether that is the rep's quote or the manager's locked final rate.
 */
export function computeLine(product: Product, input: LineInput): ComputedLine {
  const rate = num(input.rate);
  const uom = uomFor(product.category);

  switch (product.category) {
    case 'PCTR': {
      const rolls = num(input.rolls);
      const belts = num(input.looseBelts);
      const perRoll = num(product.avgWeightPerRoll);
      const perBelt = weightPerBelt(product);
      // Average weight, so this is an estimate until the rolls are weighed.
      const quantity = round3(rolls * perRoll + belts * perBelt);
      const parts: string[] = [];
      if (rolls) parts.push(`${rolls} roll${rolls === 1 ? '' : 's'} x ${perRoll} kg (avg)`);
      if (belts) parts.push(`${belts} belt${belts === 1 ? '' : 's'} x ${round3(perBelt)} kg`);
      return {
        quantity,
        uom,
        amount: round2(quantity * rate),
        breakdown: parts.join(' + ') || '—',
      };
    }

    case 'CTR': {
      // Fixed-weight rolls, so the weight is exact and belts do not apply (1.3).
      const rolls = num(input.rolls);
      const perRoll = num(product.exactWeightPerRoll);
      const quantity = round3(rolls * perRoll);
      return {
        quantity,
        uom,
        amount: round2(quantity * rate),
        breakdown: rolls ? `${rolls} roll${rolls === 1 ? '' : 's'} x ${perRoll} kg (exact)` : '—',
      };
    }

    case 'BG': {
      const kg = num(input.kg);
      const boxes = Math.floor(kg / BG_KG_PER_BOX);
      const looseRolls = Math.round((kg % BG_KG_PER_BOX) / BG_KG_PER_ROLL);
      const parts: string[] = [];
      if (boxes) parts.push(`${boxes} box${boxes === 1 ? '' : 'es'}`);
      if (looseRolls) parts.push(`${looseRolls} roll${looseRolls === 1 ? '' : 's'}`);
      return {
        quantity: round3(kg),
        uom,
        amount: round2(kg * rate),
        breakdown: parts.length ? `${parts.join(' + ')} = ${kg} kg` : '—',
      };
    }

    case 'VS': {
      // Each tin size is its own line at its own rate (1.5), so the rate here
      // is per tin rather than per litre.
      const tins = num(input.tins);
      const size = input.tinSize ?? product.tinSize ?? 10;
      const quantity = round3(tins * size);
      return {
        quantity,
        uom,
        amount: round2(tins * rate),
        breakdown: tins ? `${tins} x ${size}L tin${tins === 1 ? '' : 's'} = ${quantity} L` : '—',
      };
    }
  }
}

// ------------------------------------------------------------ validation ---

export interface LineIssue {
  field: 'rolls' | 'looseBelts' | 'kg' | 'tins' | 'rate';
  message: string;
}

/**
 * Category-specific input validation. Returns every problem rather than the
 * first, so the row can flag all of its bad fields at once.
 */
export function validateLine(product: Product, input: LineInput): LineIssue[] {
  const issues: LineIssue[] = [];
  const rate = num(input.rate);

  switch (product.category) {
    case 'PCTR': {
      const rolls = num(input.rolls);
      const belts = num(input.looseBelts);
      if (rolls < 0) issues.push({ field: 'rolls', message: 'Rolls cannot be negative.' });
      if (belts < 0) issues.push({ field: 'looseBelts', message: 'Belts cannot be negative.' });
      if (!Number.isInteger(rolls)) issues.push({ field: 'rolls', message: 'Rolls must be a whole number.' });
      if (!Number.isInteger(belts)) issues.push({ field: 'looseBelts', message: 'Belts must be a whole number.' });
      // A loose belt only means something against a roll that yields belts.
      const perRoll = product.beltsPerRoll ?? 0;
      if (belts > 0 && perRoll > 0 && belts >= perRoll) {
        issues.push({
          field: 'looseBelts',
          message: `${perRoll} belts make a full roll — book ${Math.floor(belts / perRoll)} more roll(s) instead.`,
        });
      }
      if (rolls === 0 && belts === 0) {
        issues.push({ field: 'rolls', message: 'Enter rolls or loose belts.' });
      }
      break;
    }

    case 'CTR': {
      const rolls = num(input.rolls);
      if (!Number.isInteger(rolls)) issues.push({ field: 'rolls', message: 'Rolls must be a whole number.' });
      if (rolls <= 0) issues.push({ field: 'rolls', message: 'Enter at least 1 roll.' });
      break;
    }

    case 'BG': {
      const kg = num(input.kg);
      if (kg <= 0) issues.push({ field: 'kg', message: 'Enter a quantity in kg.' });
      // The floor sells gum in 5 kg rolls, so anything else cannot be picked (1.4).
      else if (kg % BG_KG_PER_ROLL !== 0) {
        issues.push({
          field: 'kg',
          message: `Must be a multiple of ${BG_KG_PER_ROLL} kg — nearest are ${
            Math.floor(kg / BG_KG_PER_ROLL) * BG_KG_PER_ROLL
          } or ${Math.ceil(kg / BG_KG_PER_ROLL) * BG_KG_PER_ROLL} kg.`,
        });
      }
      break;
    }

    case 'VS': {
      const tins = num(input.tins);
      if (!Number.isInteger(tins)) issues.push({ field: 'tins', message: 'Tins must be a whole number.' });
      if (tins <= 0) issues.push({ field: 'tins', message: 'Enter at least 1 tin.' });
      break;
    }
  }

  if (rate <= 0) issues.push({ field: 'rate', message: 'Enter a rate.' });
  return issues;
}

/** Nudge a bonding-gum entry onto the nearest sellable 5 kg step. */
export function snapBgKg(kg: number): number {
  if (!Number.isFinite(kg) || kg <= 0) return 0;
  return Math.max(BG_KG_PER_ROLL, Math.round(kg / BG_KG_PER_ROLL) * BG_KG_PER_ROLL);
}

/** Order value, using each line's locked rate where one exists. */
export function orderTotal(items: OrderItem[]): number {
  return round2(
    items.reduce((sum, it) => {
      const rate = it.finalRate ?? it.quotedRate;
      // VS prices by the tin; everything else by weight.
      const amount = it.category === 'VS' ? (it.tins ?? 0) * rate : it.quantity * rate;
      return sum + amount;
    }, 0),
  );
}

/** The rate that actually applies to a line right now. */
export function effectiveRate(item: OrderItem): number {
  return item.finalRate ?? item.quotedRate;
}

/** Money for a single saved line. */
export function lineAmount(item: OrderItem): number {
  const rate = effectiveRate(item);
  return round2(item.category === 'VS' ? (item.tins ?? 0) * rate : item.quantity * rate);
}

// ---------------------------------------------------------------- utils ---

function num(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

export function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

export function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}
