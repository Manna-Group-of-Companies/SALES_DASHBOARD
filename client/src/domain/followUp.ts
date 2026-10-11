/**
 * The GM's follow-up: what happens to an order after the GM has approved it.
 *
 * Asked for 25 September 2026. An approved order leaves "Escalated to you",
 * and the promise it was approved on still has to be kept. The follow-up view
 * holds every order the GM approved — waiting for the sales manager's push, in
 * SAP, invoiced — with its condition and the conversation about it, so the
 * history of what was promised, answered and accepted reads in one place.
 *
 * **Dashboard only.** The phone has no follow-up screen; the GM follows up
 * here. The rules both apps share — that a rep's answer is kept on the order,
 * and who may add a note — are in `creditCommitment.ts` and
 * `shared/fixtures/credit_commitment.json` → `follow_up`. What lives here is
 * how the screen sorts and tells the story, which is this screen's business.
 */

import { COND_AWAITING, COND_CLOSED, conditionOverdue } from './creditCondition';
import { PO_STATUS } from './orderStatus';

export type FollowUpBucket = 'answered' | 'overdue' | 'awaiting_push' | 'open' | 'done';

export const FOLLOW_UP_LABEL: Record<FollowUpBucket, string> = {
  answered: 'Rep has answered',
  overdue: 'Overdue',
  awaiting_push: 'Waiting for the push',
  open: 'Condition open',
  done: 'Closed',
};

/** The order the piles are shown in: what needs the GM first. */
export const FOLLOW_UP_BUCKETS: FollowUpBucket[] = [
  'answered',
  'overdue',
  'awaiting_push',
  'open',
  'done',
];

interface ConditionLike {
  status: string;
  dueDate?: string | null;
}

/**
 * Which pile an order sits in.
 *
 * An answer outranks everything: the rep has done something and is waiting
 * on the GM, which is the one case the GM is the hold-up. Overdue comes next,
 * because it is the one that needs chasing. Waiting for the push outranks a
 * merely open condition — until it is in SAP the order has not happened — and
 * an order with nothing live on it is done, whether or not it ever had a
 * condition.
 */
export function followUpBucket(input: {
  poStatus?: string | null;
  conditions: ConditionLike[];
  today: Date;
}): FollowUpBucket {
  const live = input.conditions.filter((c) => c.status !== COND_CLOSED);
  if (live.some((c) => c.status === COND_AWAITING)) return 'answered';
  if (live.some((c) => conditionOverdue(c.status, c.dueDate, input.today))) return 'overdue';
  if ((input.poStatus ?? '').trim() === PO_STATUS.finalApproval) return 'awaiting_push';
  if (live.length) return 'open';
  return 'done';
}

export type TimelineKind = 'commitment' | 'comment' | 'answer' | 'approved' | 'condition' | 'closed';

export interface TimelineEntry {
  /** Frappe's `YYYY-MM-DD HH:MM:SS`, which sorts as text. Empty sorts first. */
  at: string;
  kind: TimelineKind;
  who: string;
  /** 'Sales Rep', 'Sales Manager', 'General Manager' — who spoke, not their name. */
  role?: string;
  text: string;
}

/**
 * The order's history, oldest first.
 *
 * Built from four places the facts actually live: the commitment on the
 * order, the comments, the GM's approval stamp, and each condition. A rep's
 * answer arrives as a comment from 25 Sep 2026; an answer given before that
 * exists only on the condition, so it is read from there when no comment
 * carries it — never both, or the same answer would appear twice.
 */
export function followUpTimeline(input: {
  rep: string;
  placedAt?: string;
  commitment?: string;
  commitmentDue?: string;
  gmApprovedBy?: string;
  gmApprovedOn?: string;
  comments: { author: string; authorRole: string; comment: string; postedOn: string }[];
  conditions: {
    condition: string;
    dueDate?: string;
    setBy?: string;
    setOn?: string;
    response?: string;
    respondedOn?: string;
    status: string;
    closeNote?: string;
    closedBy?: string;
    closedOn?: string;
  }[];
}): TimelineEntry[] {
  const out: TimelineEntry[] = [];

  if (input.commitment?.trim()) {
    out.push({
      at: input.placedAt ?? '',
      kind: 'commitment',
      who: input.rep || 'The rep',
      role: 'Sales Rep',
      text: input.commitmentDue
        ? `${input.commitment.trim()} (to be met by ${input.commitmentDue})`
        : input.commitment.trim(),
    });
  }

  const answersInThread = new Set<string>();
  for (const c of input.comments) {
    const isAnswer = c.authorRole === 'Sales Rep';
    if (isAnswer) answersInThread.add(c.comment.trim());
    out.push({
      at: c.postedOn,
      kind: isAnswer ? 'answer' : 'comment',
      who: c.author,
      role: c.authorRole,
      text: c.comment,
    });
  }

  if (input.gmApprovedOn) {
    out.push({
      at: input.gmApprovedOn,
      kind: 'approved',
      who: input.gmApprovedBy || 'The GM',
      role: 'General Manager',
      text: 'Approved the credit and sent the order back to the sales manager to push to SAP.',
    });
  }

  for (const k of input.conditions) {
    out.push({
      at: k.setOn ?? '',
      kind: 'condition',
      who: k.setBy || 'The GM',
      role: 'General Manager',
      text: k.dueDate ? `Condition: ${k.condition} — due ${k.dueDate}` : `Condition: ${k.condition}`,
    });
    const answer = (k.response ?? '').trim();
    if (answer && !answersInThread.has(answer)) {
      out.push({
        at: k.respondedOn ?? '',
        kind: 'answer',
        who: input.rep || 'The rep',
        role: 'Sales Rep',
        text: answer,
      });
    }
    if (k.status === COND_CLOSED) {
      out.push({
        at: k.closedOn ?? '',
        kind: 'closed',
        who: k.closedBy || 'The GM',
        role: 'General Manager',
        text: k.closeNote ? `Closed the condition: ${k.closeNote}` : 'Closed the condition.',
      });
    }
  }

  // Stable, so entries stamped in the same second keep the order they were
  // built in — the condition straight after the approval that made it.
  return out
    .map((e, i) => ({ e, i }))
    .sort((a, b) => a.e.at.localeCompare(b.e.at) || a.i - b.i)
    .map(({ e }) => e);
}
