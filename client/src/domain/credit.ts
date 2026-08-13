/**
 * What a customer owes, and how old it is.
 *
 * **Paired with `app/lib/core/credit.dart`.** Both read
 * `shared/fixtures/credit.json` in their tests, so a rule that changes on one
 * side turns the other side red. See `shared/README.md`.
 *
 * SAP ages its receivables into four buckets and sends all four, plus a single
 * credit limit. ERPNext gained four `Currency` fields on `Customer` on
 * 13 August 2026 to hold them:
 *
 *     custom_outstanding_0_30      0–30 days
 *     custom_outstanding_30_60     30–60 days
 *     custom_outstanding_60_90     60–90 days
 *     custom_outstanding_90_plus   over 90 days
 *
 * `custom_outstanding_balance` stays, and stays the **total**. That is not
 * redundancy, it is the point:
 *
 *   - it is the figure the credit limit has always been checked against, on
 *     both apps, and every one of those checks keeps working untouched;
 *   - it is what SAP itself calls the balance, so recomputing it here would
 *     let a rounding difference in our sum move a figure a manager was shown;
 *   - the buckets are zero on all 620 customers until the SAP job is changed
 *     to send them, and a dashboard that derived the total from the buckets
 *     would read every customer as owing nothing in the meantime.
 *
 * The credit **limit** is deliberately not split. SAP gives one number.
 */

/** A customer as ERPNext returns it. Values arrive as numbers or strings. */
export type CustomerRow = Record<string, unknown>;

export const OUTSTANDING_FIELD = {
  total: 'custom_outstanding_balance',
  creditLimit: 'custom_credit_limit',
  d0_30: 'custom_outstanding_0_30',
  d30_60: 'custom_outstanding_30_60',
  d60_90: 'custom_outstanding_60_90',
  d90plus: 'custom_outstanding_90_plus',
} as const;

/**
 * How far the stored total may sit from the sum of the buckets before it is
 * called a fault. SAP rounds; a rupee is not a broken sync.
 */
export const AGING_TOLERANCE = 1;

function num(v: unknown): number {
  if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
  if (typeof v === 'string') {
    const n = Number(v.trim());
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

const round2 = (n: number) => (Number.isFinite(n) ? Number(n.toFixed(2)) : 0);

export interface Aging {
  /** 0–30 days. */
  current: number;
  /** 30–60 days. */
  d30: number;
  /** 60–90 days. */
  d60: number;
  /** Over 90 days. */
  d90: number;
  /** What the buckets add up to. */
  sum: number;
  /** What the credit decision is made on. */
  total: number;
  creditLimit: number;
  /**
   * Whether SAP has actually sent a breakdown for this customer.
   *
   * False must render as "not synced", never as four zeros — four zeros beside
   * a real total reads as "nothing is overdue", which is a statement nobody
   * has the data to make.
   */
  bucketsKnown: boolean;
  /**
   * The stored total and the buckets disagree by more than rounding. Surfaced
   * rather than smoothed over: it means the SAP job wrote one and not the
   * other, and quietly picking a winner would hide a broken sync for months.
   */
  mismatch: boolean;
}

export function agingOf(customer: CustomerRow): Aging {
  const current = num(customer[OUTSTANDING_FIELD.d0_30]);
  const d30 = num(customer[OUTSTANDING_FIELD.d30_60]);
  const d60 = num(customer[OUTSTANDING_FIELD.d60_90]);
  const d90 = num(customer[OUTSTANDING_FIELD.d90plus]);
  const stored = num(customer[OUTSTANDING_FIELD.total]);

  // Any bucket, including a negative one: a credit note in the 30–60 column is
  // still a breakdown that arrived.
  const bucketsKnown = current !== 0 || d30 !== 0 || d60 !== 0 || d90 !== 0;
  const sum = round2(current + d30 + d60 + d90);

  /*
   * The stored total wins whenever there is one. It only falls back to the sum
   * when SAP wrote buckets and left the total at zero — showing zero there
   * would tell a manager a customer owing 169,900 was clear.
   */
  const total = stored !== 0 ? stored : bucketsKnown ? sum : 0;

  return {
    current,
    d30,
    d60,
    d90,
    sum,
    total,
    creditLimit: num(customer[OUTSTANDING_FIELD.creditLimit]),
    bucketsKnown,
    mismatch: bucketsKnown && stored !== 0 && Math.abs(stored - sum) > AGING_TOLERANCE,
  };
}

/** What is older than ninety days. Zero when nothing is, or nothing is known. */
export function overdueAmount(customer: CustomerRow): number {
  return num(customer[OUTSTANDING_FIELD.d90plus]);
}

export function hasOverdue(customer: CustomerRow): boolean {
  return overdueAmount(customer) > 0;
}

/**
 * Whether an order takes this customer past their credit limit.
 *
 * **Unchanged by the aging split, deliberately.** The four buckets are shown,
 * not enforced: old debt does not escalate on its own. Adding that rule
 * silently would start stopping orders the day it shipped, on customers
 * nobody had warned — so it is a decision to be taken, not a side effect of
 * displaying a number. Recorded 13 Aug 2026 as "information only, for now".
 *
 * No limit set is not an unlimited limit, but it is not an escalation either.
 * Many of the 620 customers have none, and escalating all of them would bury
 * the general manager and teach everyone to wave the queue through.
 */
export function overCreditLimit(customer: CustomerRow, orderTotal: number): boolean {
  const a = agingOf(customer);
  if (!(a.creditLimit > 0)) return false;
  return a.total + orderTotal > a.creditLimit;
}

/** The four boxes, in the order they are shown, oldest last. */
export interface AgingBucket {
  key: 'current' | 'd30' | 'd60' | 'd90';
  label: string;
  amount: number;
  /** The oldest bucket is styled as a warning wherever it is shown. */
  overdue: boolean;
}

export function bucketsOf(a: Aging): AgingBucket[] {
  return [
    { key: 'current', label: '0–30 days', amount: a.current, overdue: false },
    { key: 'd30', label: '30–60 days', amount: a.d30, overdue: false },
    { key: 'd60', label: '60–90 days', amount: a.d60, overdue: false },
    { key: 'd90', label: 'Over 90 days', amount: a.d90, overdue: a.d90 > 0 },
  ];
}

export const AGING_NOT_SYNCED =
  'SAP has not sent an age breakdown for this customer yet. The total is still the total.';

export const AGING_MISMATCH =
  'The age breakdown does not add up to the outstanding balance. The balance is what the credit limit is checked against; the breakdown needs re-syncing from SAP.';
