/**
 * Turning SAP's kilos into rolls and belts.
 *
 * SAP holds finished-goods stock as a total weight. A rep orders rolls and
 * belts. The conversion needs two per-item numbers — weight-per-roll and
 * belts-per-roll — and both apps must convert identically, or the same shelf
 * reads differently on a phone and on a dashboard.
 *
 * THE TRAP THIS FILE EXISTS FOR
 *
 * Frappe stores Int and Float as `NOT NULL DEFAULT 0`. There is no null. An
 * item nobody has entered weights for reads exactly like an item that
 * genuinely weighs nothing per roll. Conflating those two is expensive in both
 * directions:
 *
 *   - dividing kilos by a zero roll-weight gives `Infinity`, and `Infinity`
 *     rendered into an order screen is an order for an unbounded quantity;
 *   - rendering the result as `0` tells a rep "out of stock" when the truth is
 *     "nobody has told us how to convert this".
 *
 * So the answer is a third thing: UNKNOWN. Every caller has to handle it, which
 * is the point — it cannot be quietly rounded into a number.
 *
 * WHY IT MATTERS NOW
 *
 * 288 items hold about 37,260 kg in SAP with no belt data. They read 0 qty in
 * ERPNext today only because the import deliberately withheld their stock. On
 * the next scheduled sync they become eligible to receive it, and this stops
 * being theoretical.
 *
 * Pinned by `shared/fixtures/stock_from_kg.json`, which the phone's suite reads
 * too. The Dart twin is `app/lib/core/stock_from_kg.dart`.
 */

/** A conversion that could not be made, and why, so a screen can say so. */
export interface UnknownStock {
  known: false;
  /** The kilos are still real and still worth showing. */
  kg: number;
  reason: 'no_weight_per_roll' | 'no_belts_per_roll' | 'not_weighed';
}

export interface KnownStock {
  known: true;
  kg: number;
  /** Fractional on purpose — see `partial_rolls_are_real` in the fixture. */
  rolls: number;
  belts: number;
  weightPerBelt: number;
}

export type StockFromKg = KnownStock | UnknownStock;

/** Three decimals. Enough that 149.2/38.4 round-trips; short of float noise. */
const round3 = (v: number): number => Math.round(v * 1000) / 1000;

/**
 * A stored number that Frappe may have defaulted to 0.
 *
 * Zero, negative and non-finite all mean "no usable value". Negative is not
 * merely invalid — propagated, it yields a negative roll count that looks like
 * a number and is not one.
 */
function usable(v: unknown): number | null {
  const n = Number(v ?? 0);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * Weight of one belt.
 *
 * The site's own invariant is `weightPerBelt x beltsPerRoll = weightPerRoll`,
 * and `custom_avg_weight_per_roll` holds the BELT weight despite its name. The
 * FG import of 10 September 2026 left it at 0 on all 153 items it gave belt
 * data to, so it is derived here when missing rather than believed.
 *
 * The stored value wins when it is present: it is what a human entered, and
 * this only fills a hole.
 */
export function weightPerBelt(input: {
  storedWeightPerBelt?: number | null;
  weightPerRoll?: number | null;
  beltsPerRoll?: number | null;
}): number | null {
  const stored = usable(input.storedWeightPerBelt);
  if (stored !== null) return stored;

  const roll = usable(input.weightPerRoll);
  const belts = usable(input.beltsPerRoll);
  if (roll === null || belts === null) return null;
  return round3(roll / belts);
}

/**
 * Kilos on the shelf, as rolls and belts.
 *
 * `isWeighed` is false for anything sold in Nos or Litre — a tin of solution
 * has no rolls, and the question should not be asked of it rather than
 * answered with a zero.
 */
export function stockFromKg(input: {
  kg: number;
  weightPerRoll?: number | null;
  beltsPerRoll?: number | null;
  storedWeightPerBelt?: number | null;
  isWeighed?: boolean;
}): StockFromKg {
  const kg = Number.isFinite(Number(input.kg)) ? Number(input.kg) : 0;

  if (input.isWeighed === false) {
    return { known: false, kg, reason: 'not_weighed' };
  }

  const roll = usable(input.weightPerRoll);
  const belts = usable(input.beltsPerRoll);

  // Both are required. A roll count without a belt count is half an answer,
  // and half an answer on an order screen gets treated as a whole one.
  if (roll === null) return { known: false, kg, reason: 'no_weight_per_roll' };
  if (belts === null) return { known: false, kg, reason: 'no_belts_per_roll' };

  const rolls = round3(kg / roll);
  return {
    known: true,
    kg,
    rolls,
    // From the UNROUNDED roll count: rounding first and multiplying compounds
    // the error by belts-per-roll, which is up to 20 here.
    belts: round3((kg / roll) * belts),
    weightPerBelt: round3(roll / belts),
  };
}

/** What a screen shows when the conversion could not be made. */
export function unknownStockLabel(reason: UnknownStock['reason']): string {
  switch (reason) {
    case 'not_weighed':
      return 'Not sold by weight';
    case 'no_belts_per_roll':
      return 'Belts per roll not set';
    default:
      return 'Weights not set';
  }
}
