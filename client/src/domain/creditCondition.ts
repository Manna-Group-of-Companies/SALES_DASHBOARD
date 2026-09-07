/**
 * Who may move a credit condition, and when one is overdue.
 *
 * A condition is the record of a promise the GM extracted in exchange for
 * letting an over-limit order through. The whole value of it is that the
 * person who owes it cannot mark it done — so that rule has to hold in the
 * request as well as in the screen, on the dashboard as well as on the phone.
 * There are no Server Scripts on this site: a hidden button is not a
 * permission, it is a suggestion.
 *
 * The Dart twin is `app/lib/core/credit_condition.dart`. Both are pinned by
 * `shared/fixtures/credit_condition.json`, which both test suites read.
 */

export const COND_OPEN = 'Open';
export const COND_AWAITING = 'Awaiting Review';
export const COND_CLOSED = 'Closed';

export type ConditionStatus =
  | typeof COND_OPEN
  | typeof COND_AWAITING
  | typeof COND_CLOSED;

export type ConditionAction = 'respond' | 'close' | 'reopen';

/** The coarse role taking the action. Anything else is refused. */
export type ConditionActor = 'gm' | 'rep' | 'sales_manager' | string;

/**
 * Whether `actor` may take `action` on a condition at `status`.
 *
 * An unrecognised role is refused rather than waved through. Erring towards
 * refusal costs a phone call; erring the other way costs the accountability
 * the feature exists for.
 */
export function canMoveCondition(
  status: string,
  action: ConditionAction,
  actor: ConditionActor,
): boolean {
  const isGm = actor === 'gm';

  switch (action) {
    case 'respond':
      // Only the rep answers, and only while it is still live. Answering a
      // closed condition would reopen a settled matter by the back door.
      return actor === 'rep' && (status === COND_OPEN || status === COND_AWAITING);

    case 'close':
      // The GM alone. This is the line the whole feature is drawn around.
      return isGm && (status === COND_OPEN || status === COND_AWAITING);

    case 'reopen':
      // Send one back for more, or reopen one that turned out not to have
      // been met after all.
      return isGm && (status === COND_AWAITING || status === COND_CLOSED);

    default:
      return false;
  }
}

/** What the status becomes, or null if `actor` may not do this. */
export function nextConditionStatus(
  status: string,
  action: ConditionAction,
  actor: ConditionActor,
): ConditionStatus | null {
  if (!canMoveCondition(status, action, actor)) return null;
  if (action === 'respond') return COND_AWAITING;
  if (action === 'close') return COND_CLOSED;
  return COND_OPEN;
}

/**
 * Whether a condition is late.
 *
 * Overdue is what is still owed *today*. A condition closed after its date is
 * closed, not overdue — showing it in red forever would make the list a
 * history of lateness nobody can act on, and bury the ones still needing a
 * chase.
 *
 * No deadline is never late. Frappe reads an unset Date back as null, '' or
 * the string 'null' depending on how it was written; all three mean the GM
 * set none.
 */
export function conditionOverdue(
  status: string,
  dueDateIso: string | null | undefined,
  today: Date,
): boolean {
  if (status === COND_CLOSED) return false;
  const raw = (dueDateIso ?? '').trim();
  if (!raw || raw === 'null') return false;
  const due = new Date(`${raw.slice(0, 10)}T00:00:00`);
  if (Number.isNaN(due.getTime())) return false;
  const t = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  // Due today is not yet late — the rep has the day.
  return due.getTime() < t.getTime();
}
