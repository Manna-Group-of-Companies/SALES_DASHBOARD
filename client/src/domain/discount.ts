/**
 * Per-line discount, granted by the sales manager at approval.
 *
 * A rep quotes a rate. The manager may take a percentage off *that line* —
 * not the order — because the concession is usually about one product, and an
 * order-level discount would spread it across items nobody negotiated on. The
 * before and after figures are then shown side by side, so whoever signs the
 * order can see exactly what was given away.
 *
 * **Where it is stored.** ERPNext's own pricing fields on `Sales Order Item`,
 * not new custom ones:
 *
 *     price_list_rate      per unit, BEFORE the discount
 *     discount_percentage  what the manager took off
 *     discount_amount      per unit, the money taken off
 *     rate                 per unit, AFTER the discount
 *     amount               qty x rate
 *
 * They already exist on the site — only the Desk *section* is hidden, by a
 * Property Setter — and every downstream total ERPNext computes (`net_total`,
 * `grand_total`, the proforma, GST, the eventual Sales Invoice) is built from
 * `amount`. Inventing a custom field would leave the discount visible on this
 * screen and absent from the invoice, which is the one place it must not be.
 *
 * ERPNext recomputes `rate` from the discount only when `rate` is empty or a
 * Pricing Rule is in play. We always write a rate, and this site has no
 * Pricing Rules, so the figure written here is the figure kept.
 *
 * **What stays put.** `custom_rate_per_kg` remains what the rep quoted, per
 * kilogram, before any discount. It is the number the trade talks in and the
 * one the rep will be asked about. The discount is a separate, visible act,
 * never a quiet rewrite of the quoted rate.
 */

import { isGeneralManager } from './orderStatus';

/** ERPNext money precision on this site. */
const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * A percentage the site will accept.
 *
 * Clamped rather than rejected: a manager typing 150 means "as much as I can",
 * and refusing the save teaches nothing. 100% is allowed — a free replacement
 * roll is a real thing this trade does — and is the only case where the line
 * total legitimately reaches zero.
 */
export function normaliseDiscount(percent: number | null | undefined): number {
  const n = Number(percent);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(100, round2(n));
}

export interface DiscountedLine {
  /** Per unit, before the discount. Goes to `price_list_rate`. */
  perUnitBefore: number;
  /** Per unit, after. Goes to `rate`. */
  perUnitAfter: number;
  /** Per unit, taken off. Goes to `discount_amount`. */
  perUnitOff: number;
  /** Line total before the discount. */
  before: number;
  /** Line total after. Goes to `amount`. */
  after: number;
  /** What the customer was given on this line. */
  saved: number;
  percent: number;
}

/**
 * Apply a percentage to one line.
 *
 * The discount is taken off the **per-unit rate** and the amount rebuilt from
 * it, never taken off the amount directly. ERPNext stores one qty and one rate
 * and reconciles `amount` against `qty x rate` on every save; discounting the
 * amount alone would leave the two describing different money and the figure
 * would silently revert.
 */
export function discountLine(input: {
  /** Per unit, before the discount — what the line would have cost. */
  perUnit: number;
  qty: number;
  percent: number;
}): DiscountedLine {
  const percent = normaliseDiscount(input.percent);
  const perUnitBefore = round2(Math.max(0, input.perUnit));
  const qty = Math.max(0, input.qty);

  const perUnitAfter = round2(perUnitBefore * (1 - percent / 100));
  const before = round2(qty * perUnitBefore);
  const after = round2(qty * perUnitAfter);

  return {
    perUnitBefore,
    perUnitAfter,
    // Derived from the two rounded rates, so it can never disagree with them
    // by a paisa the way an independently rounded figure would.
    perUnitOff: round2(perUnitBefore - perUnitAfter),
    before,
    after,
    saved: round2(before - after),
    percent,
  };
}

export interface OrderDiscount {
  before: number;
  after: number;
  saved: number;
  /** The whole order's effective rate, which is not the average of the lines. */
  percent: number;
  /** How many lines carry one. */
  lines: number;
}

/**
 * Roll the lines up.
 *
 * The order-level percentage is `saved / before`, **not** the mean of the line
 * percentages. Ten per cent off a ₹500 line and nothing off a ₹50,000 one is
 * not a five per cent order, and showing it as one would misstate what was
 * given away by an order of magnitude.
 */
export function orderDiscount(
  lines: { before: number; after: number; percent: number }[],
): OrderDiscount {
  let before = 0;
  let after = 0;
  let n = 0;
  for (const l of lines) {
    before += l.before;
    after += l.after;
    if (normaliseDiscount(l.percent) > 0) n += 1;
  }
  before = round2(before);
  after = round2(after);
  const saved = round2(before - after);
  return {
    before,
    after,
    saved,
    percent: before > 0 ? round2((saved / before) * 100) : 0,
    lines: n,
  };
}

/**
 * Whether the discount on a line may still be changed.
 *
 * Deliberately the *same* gate as the rate, and for the same reason: a
 * discount is a price. Approval fixes what the customer pays, and a percentage
 * that could still move afterwards would let the signed total change without
 * anything going back for a decision.
 *
 * The General Manager keeps the override that already exists for rates. There
 * is no second rule here — one way to unlock a price, not two.
 */
export function discountEditable(role: string | undefined, rateApproved: boolean): boolean {
  return !rateApproved || isGeneralManager(role);
}

export const DISCOUNT_LOCKED =
  'This line is approved, so its discount is final. Only the General Manager can reopen a price once it has been signed off.';
