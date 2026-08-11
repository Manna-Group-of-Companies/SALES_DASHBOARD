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

// ------------------------------------------------------------- weights ---

/** The three weight figures as they arrive, before anything is derived. */
export interface RawWeights {
  weightPerBelt?: number;
  beltsPerRoll?: number;
  weightPerRoll?: number;
}

/**
 * Fill in whichever weight figure the master is missing.
 *
 * `weightPerBelt x beltsPerRoll = weightPerRoll` is an identity, so any two
 * give the third. Every product enters the app through here — the REST
 * boundary and the spreadsheet importer both — so no screen ever has to know
 * that ERPNext's field name says "roll" while the number means "belt".
 *
 * Nothing is invented: a figure that cannot be derived stays undefined, and
 * `isMisconfigured` refuses the line rather than letting it price at zero.
 */
export function normaliseWeights(raw: RawWeights): RawWeights {
  const belts = raw.beltsPerRoll && raw.beltsPerRoll > 0 ? raw.beltsPerRoll : undefined;
  let perBelt = raw.weightPerBelt && raw.weightPerBelt > 0 ? raw.weightPerBelt : undefined;
  let perRoll = raw.weightPerRoll && raw.weightPerRoll > 0 ? raw.weightPerRoll : undefined;

  if (perRoll == null && perBelt != null && belts != null) perRoll = round3(perBelt * belts);
  if (perBelt == null && perRoll != null && belts != null) perBelt = round3(perRoll / belts);

  return { weightPerBelt: perBelt, beltsPerRoll: belts, weightPerRoll: perRoll };
}

/** The weight of one whole roll, in kg. Zero when the master is incomplete. */
export function rollWeight(product: Product): number {
  if (product.weightPerRoll && product.weightPerRoll > 0) return product.weightPerRoll;
  const perBelt = num(product.weightPerBelt);
  const belts = num(product.beltsPerRoll);
  return perBelt > 0 && belts > 0 ? round3(perBelt * belts) : 0;
}

/** PCTR only: the weight one loose belt carries (1.2). */
export function beltWeight(product: Product): number {
  if (product.weightPerBelt && product.weightPerBelt > 0) return product.weightPerBelt;
  const belts = num(product.beltsPerRoll);
  const perRoll = num(product.weightPerRoll);
  return belts > 0 && perRoll > 0 ? round3(perRoll / belts) : 0;
}

/**
 * Why this product cannot be sold, or null when it can.
 *
 * An item missing its weight would price at `rate x 0` and look entirely
 * normal on the proforma — the total is simply too low, and nothing on the
 * page says why. Block the line instead, and name the missing field so
 * whoever maintains the master can fix it.
 */
export function isMisconfigured(product: Product): string | null {
  switch (product.category) {
    case 'PCTR': {
      if (!(num(product.beltsPerRoll) > 0)) {
        return 'No belts-per-roll on this item, so no roll can be cut. Fix the item master before selling it.';
      }
      if (!(rollWeight(product) > 0)) {
        return 'No roll weight on this item, so it would price at zero. Fix the item master before selling it.';
      }
      return null;
    }
    case 'CTR':
      return rollWeight(product) > 0
        ? null
        : 'No roll weight on this item, so it would price at zero. Fix the item master before selling it.';
    case 'VS':
      return product.tinSize ? null : 'No tin size on this item, so it cannot be priced.';
    case 'BG':
      // Sold by the kilogram straight from the rep's entry — nothing to derive.
      return null;
  }
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
      const perRoll = rollWeight(product);
      const perBelt = beltWeight(product);
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
      const perRoll = rollWeight(product);
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
  field: 'rolls' | 'looseBelts' | 'kg' | 'tins' | 'rate' | 'product';
  message: string;
}

/**
 * Category-specific input validation. Returns every problem rather than the
 * first, so the row can flag all of its bad fields at once.
 */
export function validateLine(product: Product, input: LineInput): LineIssue[] {
  const issues: LineIssue[] = [];
  const rate = num(input.rate);

  // An incomplete master is not something the rep can key their way out of, so
  // it is the only issue worth reporting — the rest would just be noise.
  const broken = isMisconfigured(product);
  if (broken) return [{ field: 'product', message: broken }];

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


// -------------------------------------------- writing a Sales Order line ---

/** What the manager keys when editing a line in the order. */
export interface LineEdit {
  rolls?: number;
  looseBelts?: number;
  kg?: number;
  tins?: number;
  /** Price per kilogram — what the rep quoted, and what people talk about. */
  ratePerKg: number;
}

/** The five figures a Sales Order Item row must carry for the money to agree. */
export interface OrderLineValues {
  qty: number;
  rate: number;
  amount: number;
  totalWeight: number;
  packingNote: string;
}

/**
 * Turn a manager's edit into the exact numbers ERPNext stores on the line.
 *
 * This mirrors a convention on the live site that looks wrong and is not:
 * `qty` counts **rolls** while `uom` reads "Kg", and `rate` is therefore money
 * per roll, not per kilogram. The live order SAL-ORD-2026-00104 shows it —
 * `qty 9, rate 1075.20, amount 9676.80` against `total_weight 302.4` and
 * `rate_per_kg 32`.
 *
 * Two identities have to survive every edit, because different screens read
 * different ones:
 *
 *   - `qty x rate == amount` — what ERPNext totals the order from,
 *   - `totalWeight x ratePerKg == amount` — what the proforma and the rep read.
 *
 * Solving both gives `qty = totalWeight / weightPerRoll`, which is why a part
 * roll of loose belts lands as a fractional qty rather than being rounded. Set
 * `qty` to a bare roll count instead and any order with loose belts bills the
 * belts for free.
 */
export function orderLineValues(product: Product, edit: LineEdit): OrderLineValues {
  const rate = num(edit.ratePerKg);
  const computed = computeLine(product, { ...edit, rate });
  const weight = computed.quantity;

  switch (product.category) {
    case 'PCTR':
    case 'CTR': {
      const perRoll = rollWeight(product);
      // Guarded: a master with no roll weight is refused by `isMisconfigured`
      // long before this, but a zero here would be an Infinity in the order.
      const qty = perRoll > 0 ? round3(weight / perRoll) : 0;
      const perUnit = round2(rate * perRoll);
      /*
       * Matches the note the field-sales app writes verbatim — "8 rolls + 2
       * loose belts · 210.00 kg (avg)" on SAL-ORD-2026-00106 — so a line the
       * manager edits reads identically to one the rep created, on the order
       * and on the picking list.
       */
      const rolls = num(edit.rolls);
      const belts = num(edit.looseBelts);
      const parts = [`${rolls} roll${rolls === 1 ? '' : 's'}`];
      if (belts) parts.push(`${belts} loose belt${belts === 1 ? '' : 's'}`);
      return {
        qty,
        rate: perUnit,
        /*
         * `qty x rate`, NOT `weight x ratePerKg`.
         *
         * The two differ once qty is rounded: on SAL-ORD-2026-00106 the weight
         * form gives 5250.00 and the app wrote 5249.79, which is 8.333 x 630.
         * ERPNext recomputes `amount = qty x rate` on save anyway, so writing
         * the weight form would be silently overwritten — and until it was,
         * the manager's preview would disagree with the saved order by 21
         * paise and shift `rounding_adjustment` with it.
         */
        amount: round2(qty * perUnit),
        totalWeight: weight,
        packingNote: `${parts.join(' + ')} · ${weight.toFixed(2)} kg${
          product.category === 'PCTR' ? ' (avg)' : ''
        }`,
      };
    }
    case 'BG':
      // Priced straight by the kilogram, so qty and weight are the same figure.
      return {
        qty: weight,
        rate: round2(rate),
        amount: round2(weight * rate),
        totalWeight: weight,
        packingNote: `${computed.breakdown}`,
      };
    case 'VS': {
      // Priced per tin (1.5), so `ratePerKg` is really a per-tin rate here and
      // the litres are the quantity.
      const tins = num(edit.tins);
      return {
        qty: tins,
        rate: round2(rate),
        amount: round2(tins * rate),
        totalWeight: weight,
        packingNote: computed.breakdown,
      };
    }
  }
}

/**
 * How a saved line reads in words — "12 rolls + 3 belts", "2 boxes (40 kg)".
 *
 * Lives here rather than in a screen because three of them render it, and they
 * must not describe the same line differently.
 */
export function describeEntry(item: OrderItem): string {
  switch (item.category) {
    case 'PCTR': {
      const parts: string[] = [];
      if (item.rolls) parts.push(`${item.rolls} roll${item.rolls === 1 ? '' : 's'}`);
      if (item.looseBelts) parts.push(`${item.looseBelts} belt${item.looseBelts === 1 ? '' : 's'}`);
      return parts.join(' + ') || '—';
    }
    case 'CTR':
      return `${item.rolls ?? 0} roll${item.rolls === 1 ? '' : 's'}`;
    case 'BG': {
      const kg = item.kg ?? item.quantity;
      const boxes = Math.floor(kg / 20);
      const rolls = Math.round((kg % 20) / 5);
      const parts: string[] = [];
      if (boxes) parts.push(`${boxes} box${boxes === 1 ? '' : 'es'}`);
      if (rolls) parts.push(`${rolls} roll${rolls === 1 ? '' : 's'}`);
      return parts.length ? `${parts.join(' + ')} (${kg} kg)` : `${kg} kg`;
    }
    case 'VS':
      return `${item.tins ?? 0} x ${item.tinSize ?? 10}L tin${(item.tins ?? 0) === 1 ? '' : 's'}`;
  }
}
