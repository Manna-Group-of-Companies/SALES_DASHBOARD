/**
 * Which of a dispatch's orders become one order to the customer.
 *
 * This replaced "Close the week" on 20 August 2026. A week was a thing the
 * office closed; a van is a thing the customer received. Two of a customer's
 * orders arriving together are one delivery to them, and that is what their
 * rep should be able to name when they ring.
 *
 * The rules are pinned by `shared/fixtures/combined_order.json`, which also
 * records why only the dashboard implements this — the phone's own weekly
 * combine was deleted rather than converted, so there is exactly one way to
 * combine and nothing to drift against. See `shared/DIVERGENCES.md`.
 *
 * Kept separate from `api/client.ts` so the rule can be tested without a
 * network: everything below is a decision about which orders group together,
 * and none of it needs to know how a Combined Order is written.
 */

/** One order a dispatch touched, as this rule needs to see it. */
export interface CombinableOrder {
  id: string;
  /** May be unset — Frappe reads a blank Link back three different ways. */
  customer?: string | null;
  total: number;
  /** Did THIS dispatch leave nothing outstanding on the order? */
  complete: boolean;
  /** Already a member of an earlier group, and not to be moved. */
  alreadyCombined: boolean;
}

/** One group to create: a customer, their orders, and what they come to. */
export interface PlannedGroup {
  customer: string;
  orders: string[];
  total: number;
}

/**
 * An unset Frappe Link arrives as `null`, `''` or the literal string `'null'`
 * from naive interpolation. All three mean "no customer", and gathering them
 * under one blank key would invent a group belonging to nobody.
 */
function namedCustomer(v: string | null | undefined): string {
  const s = (v ?? '').trim();
  return s === '' || s === 'null' ? '' : s;
}

/** Paise, not floating-point tails — this figure is quoted to a customer. */
function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

/**
 * Plan the groups for one dispatch. Pure: it writes nothing.
 *
 * Two exclusions do the real work, and both exist for the same reason —
 * `Sales Order.custom_combined_order` is a single Link, so an order can be in
 * at most one group, and a group's count and total must never describe
 * something other than what it holds:
 *
 * - **Incomplete orders are skipped.** A part-loaded order — seven of ten
 *   rolls now, three on the next van — waits for the dispatch that clears the
 *   remainder and joins that group instead. Grouping it here would mean the
 *   later dispatch either moved it, silently falsifying this group, or left
 *   it, so a group claimed an order that was still partly owed.
 * - **Already-grouped orders are skipped**, never moved. The order belongs to
 *   the dispatch that completed it, and that has already happened.
 *
 * A customer left with fewer than two eligible orders gets no group at all.
 * One order is not a combination, and the weekly close's habit of making
 * groups of one gave the rep a second identifier for something that already
 * had one.
 */
export function planCombinedOrders(orders: CombinableOrder[]): PlannedGroup[] {
  const byCustomer = new Map<string, CombinableOrder[]>();

  for (const o of orders) {
    if (!o.complete || o.alreadyCombined) continue;
    const customer = namedCustomer(o.customer);
    if (!customer) continue;
    const list = byCustomer.get(customer) ?? [];
    list.push(o);
    byCustomer.set(customer, list);
  }

  const groups: PlannedGroup[] = [];
  for (const [customer, list] of byCustomer) {
    if (list.length < 2) continue;
    groups.push({
      customer,
      orders: list.map((o) => o.id),
      total: round2(list.reduce((s, o) => s + o.total, 0)),
    });
  }
  return groups;
}
