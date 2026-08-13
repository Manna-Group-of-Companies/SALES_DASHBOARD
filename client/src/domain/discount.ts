/**
 * Discounts a sales manager gives at approval.
 *
 * **This file is a port of `app/lib/core/discount.dart` and must stay one.**
 * The phone and the dashboard price the same order for the same customer, and
 * there is no Server Script to arbitrate between them — a rule that differs by
 * device is two different invoices for one order. Where the two disagreed on
 * 13 August 2026 (the ceiling, and whether the GM may still override) the
 * phone's answer was taken, and the cases are pinned in
 * `shared/fixtures/discount.json`, which both test suites read.
 *
 * The rep quotes a rate. The sales manager, reviewing the order, may knock a
 * percentage off any line. Both numbers have to survive: the customer is
 * invoiced the discounted rate, but the business needs to see what was given
 * away, so the original rate is kept rather than overwritten.
 *
 * Where the two numbers live differs by order type, and this file is the only
 * place that knows it:
 *
 *   Sales Order Item   `price_list_rate` and `discount_percentage` — the
 *                      standard ERPNext fields, so Desk, the print formats and
 *                      the Sales Invoice read the discount without being
 *                      taught about it.
 *   Lead Order Item    `custom_price_list_rate` and `custom_discount_percentage`
 *                      — our own child table, which has no standard pricing
 *                      fields at all.
 *
 * In both cases `rate` is the net rate the customer pays and `amount` is
 * qty x rate. Nothing on this site recomputes them, so every figure here is
 * written explicitly and must be internally consistent before it is sent.
 *
 * Functions take **raw ERPNext rows**, not the dashboard's own `OrderLine`.
 * That is deliberate: it is the shape the fixtures are written in and the
 * shape the Dart takes, so the two can be compared case for case.
 */

/** A row as ERPNext returns it. Values arrive as numbers or numeric strings. */
export type PricedRow = Record<string, unknown>;

/** A number as Frappe might return it — number, numeric string, or null. */
function num(v: unknown): number {
  if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
  if (typeof v === 'string') {
    const n = Number(v.trim());
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

/**
 * The most a sales manager may take off a line.
 *
 * Not a costing limit — nobody has given one. It is a guard against a typo:
 * 100 in a percentage box is an order given away, and a fat finger on the
 * keypad should not be able to do that silently. A genuine giveaway above
 * this is a conversation with the GM, not a number typed at a counter.
 */
export const MAX_DISCOUNT_PERCENT = 50;

/** The discount on a line, in percent. Zero when there is none. */
export function discountPercentOf(item: PricedRow): number {
  const standard = num(item.discount_percentage);
  if (standard > 0) return standard;
  return num(item.custom_discount_percentage);
}

/**
 * The rate before any discount.
 *
 * Falls back to the net rate when nothing was discounted, so an undiscounted
 * line reports the same number both ways rather than zero. Orders taken
 * before discounts existed have no pre-discount rate stored at all, and must
 * read as full price rather than as free.
 */
export function rateBeforeDiscount(item: PricedRow): number {
  const standard = num(item.price_list_rate);
  if (standard > 0) return standard;
  const custom = num(item.custom_price_list_rate);
  if (custom > 0) return custom;
  return num(item.rate);
}

/** The rate the customer actually pays. */
export function rateAfterDiscount(item: PricedRow): number {
  return num(item.rate);
}

/**
 * Money is held to paise. Rounding at every step, rather than once at the
 * end, is what makes the lines on screen add up to the total underneath them
 * — a manager who cannot reconcile the two by eye will not trust either.
 */
export function roundMoney(v: number): number {
  return Number.isFinite(v) ? Number(v.toFixed(2)) : 0;
}

/** What a rate becomes after `percent` is taken off it. */
export function discountedRate(base: number, percent: number): number {
  return roundMoney(base * (1 - percent / 100));
}

/**
 * The percentage `net` represents off `base`.
 *
 * The inverse of `discountedRate`, used when somebody sets a rate directly
 * and the stored percentage would otherwise contradict it. Returns 0 rather
 * than a negative when the rate went *up*: a rate above the original is a
 * price rise, not a negative discount, and showing "−8% discount" would read
 * as a discount rather than as its opposite.
 */
export function percentOff(base: number, net: number): number {
  if (base <= 0 || net >= base) return 0;
  return Number((((base - net) / base) * 100).toFixed(2));
}

/** What a line is worth at full price. */
export function lineBeforeDiscount(item: PricedRow): number {
  return roundMoney(num(item.qty) * rateBeforeDiscount(item));
}

/**
 * What a line is worth after the discount.
 *
 * Prefers the stored `amount`, because that is the figure ERPNext and the
 * proforma print. Falls back to qty x rate when it is missing or zero — lead
 * orders written before the app sent `amount` have it as zero, and a manager
 * must never be shown a nil order against rates a rep entered correctly.
 */
export function lineAfterDiscount(item: PricedRow): number {
  const stored = num(item.amount);
  if (stored > 0) return roundMoney(stored);
  return roundMoney(num(item.qty) * rateAfterDiscount(item));
}

/** True when this line has had something taken off it. */
export function isDiscounted(item: PricedRow): boolean {
  return discountPercentOf(item) > 0;
}

/** An order's totals, before and after the discounts on its lines. */
export interface DiscountTotals {
  /** What the order would be worth at the rates the rep quoted. */
  beforeDiscount: number;
  /** What it is worth at the rates the customer will be invoiced. */
  afterDiscount: number;
  /** How many lines carry a discount. */
  discountedLines: number;
  /**
   * What was given away. Derived rather than accumulated so it can never
   * disagree with the two totals a manager is reading it between.
   */
  discount: number;
  /** The discount as a share of the full price, for the one-line summary. */
  discountPercent: number;
  hasDiscount: boolean;
}

/** Totals an order's lines both ways. */
export function discountTotals(items: Iterable<PricedRow>): DiscountTotals {
  let before = 0;
  let after = 0;
  let n = 0;
  for (const it of items) {
    before += lineBeforeDiscount(it);
    after += lineAfterDiscount(it);
    if (isDiscounted(it)) n += 1;
  }
  const beforeDiscount = roundMoney(before);
  const afterDiscount = roundMoney(after);
  const discount = roundMoney(beforeDiscount - afterDiscount);
  return {
    beforeDiscount,
    afterDiscount,
    discountedLines: n,
    discount,
    discountPercent: percentOff(beforeDiscount, afterDiscount),
    hasDiscount: n > 0 && discount > 0,
  };
}

/**
 * Why a discount cannot be given, or null when it can.
 *
 * Returned as a message rather than a bool because every one of these is
 * something the manager has to be told; a disabled control that does not say
 * why is the same bug as no check at all.
 *
 * **Refused, not clamped.** An earlier version of this screen clamped 150 to
 * the ceiling on the grounds that it meant "as much as possible". The likelier
 * cause of 150 in a percentage box is a slip, and clamping turns that slip
 * into a giveaway silently — the exact outcome a limit exists to prevent.
 */
export function discountRefusal(percent: number): string | null {
  // `isNaN`, not `!isFinite`, to match the Dart exactly. Infinity then falls
  // through to the "more than 100%" message rather than the "between 0 and
  // 100" one. Both refuse; only the wording differs, and the wording is the
  // part a manager reads — so it is not allowed to differ by device.
  if (Number.isNaN(percent) || percent < 0) {
    return 'Enter a discount between 0 and 100.';
  }
  if (percent > 100) return 'A discount cannot be more than 100%.';
  if (percent > MAX_DISCOUNT_PERCENT) {
    return (
      `The most that can be given here is ${MAX_DISCOUNT_PERCENT}%. ` +
      'Anything more has to go to the general manager.'
    );
  }
  return null;
}

/**
 * The fields to write to put `percent` on a line.
 *
 * Every figure the discount touches is written together — the pre-discount
 * rate, the percentage, the net rate and the amount. They are computed from
 * one another here so that whatever else reads them later finds them
 * agreeing. Nothing on the server will fix them up if they do not.
 *
 * `isLead` picks the spelling of the two fields the two order types disagree
 * about; see the note at the top of this file.
 */
export function discountFields(input: {
  item: PricedRow;
  percent: number;
  isLead: boolean;
}): Record<string, unknown> {
  // Read the original before anything is overwritten. A line discounted twice
  // must discount off the rep's rate both times, never off the already
  // discounted one — otherwise 10% given twice quietly becomes 19%.
  const base = rateBeforeDiscount(input.item);
  const net = discountedRate(base, input.percent);
  const qty = num(input.item.qty);

  return {
    ...(input.isLead
      ? {
          custom_price_list_rate: base,
          custom_discount_percentage: input.percent,
        }
      : {
          price_list_rate: base,
          discount_percentage: input.percent,
          // ERPNext derives rate from price_list_rate and discount_amount when
          // it recalculates. Sent so its arithmetic lands on the same net rate
          // as ours rather than a rounding step away from it.
          discount_amount: roundMoney(base - net),
        }),
    rate: net,
    amount: roundMoney(qty * net),
  };
}
