/**
 * The GM's follow-up: which pile an approved order sits in, and how its
 * history reads. Dashboard only — the phone has no follow-up screen.
 */

import { describe, expect, it } from 'vitest';
import { followUpBucket, followUpTimeline } from '../followUp';

const today = new Date('2026-09-25T09:00:00');

describe('which pile an approved order sits in', () => {
  it("a rep's answer outranks everything — the GM is the one holding it up", () => {
    expect(
      followUpBucket({
        poStatus: 'Pending Final Approval',
        conditions: [{ status: 'Awaiting Review', dueDate: '2026-09-01' }],
        today,
      }),
    ).toBe('answered');
  });

  it('an overdue condition comes next, because it needs chasing', () => {
    expect(
      followUpBucket({
        poStatus: 'PO Approved - Ready for SAP',
        conditions: [{ status: 'Open', dueDate: '2026-09-20' }],
        today,
      }),
    ).toBe('overdue');
  });

  it('an order not yet pushed to SAP has not happened, so it outranks a merely open condition', () => {
    expect(
      followUpBucket({
        poStatus: 'Pending Final Approval',
        conditions: [{ status: 'Open', dueDate: '2026-10-09' }],
        today,
      }),
    ).toBe('awaiting_push');
  });

  it('in SAP with the condition still owed is open', () => {
    expect(
      followUpBucket({
        poStatus: 'PO Approved - Ready for SAP',
        conditions: [{ status: 'Open', dueDate: '2026-10-09' }],
        today,
      }),
    ).toBe('open');
  });

  it('nothing live on it is done, with a closed condition or with none', () => {
    expect(
      followUpBucket({
        poStatus: 'PO Approved - Ready for SAP',
        conditions: [{ status: 'Closed', dueDate: '2026-09-01' }],
        today,
      }),
    ).toBe('done');
    expect(
      followUpBucket({ poStatus: 'PO Approved - Ready for SAP', conditions: [], today }),
    ).toBe('done');
  });

  it('a closed condition that was late is not overdue', () => {
    expect(
      followUpBucket({
        poStatus: 'PO Approved - Ready for SAP',
        conditions: [{ status: 'Closed', dueDate: '2026-09-01' }],
        today,
      }),
    ).not.toBe('overdue');
  });
});

describe("the order's history", () => {
  const base = {
    rep: 'Jaimon D',
    placedAt: '2026-09-24 10:00:00',
    commitment: 'Cheque for 50,000 on Friday',
    gmApprovedBy: 'Rajiv',
    gmApprovedOn: '2026-09-24 15:00:00',
  };

  it('reads oldest first: commitment, comments, approval, condition, answer', () => {
    const t = followUpTimeline({
      ...base,
      comments: [
        { author: 'Pareeth', authorRole: 'Sales Manager', comment: 'Paid late twice', postedOn: '2026-09-24 12:00:00' },
        { author: 'Jaimon D', authorRole: 'Sales Rep', comment: 'Cheque collected', postedOn: '2026-09-26 11:00:00' },
      ],
      conditions: [
        {
          condition: 'Cheque for 50,000 on Friday',
          dueDate: '2026-09-27',
          setBy: 'Rajiv',
          setOn: '2026-09-24 15:00:00',
          response: 'Cheque collected',
          respondedOn: '2026-09-26 11:00:00',
          status: 'Awaiting Review',
        },
      ],
    });
    expect(t.map((e) => e.kind)).toEqual(['commitment', 'comment', 'approved', 'condition', 'answer']);
  });

  it('an answer in the thread is not repeated from the condition', () => {
    const t = followUpTimeline({
      ...base,
      comments: [
        { author: 'Jaimon D', authorRole: 'Sales Rep', comment: 'Cheque collected', postedOn: '2026-09-26 11:00:00' },
      ],
      conditions: [
        { condition: 'x', status: 'Awaiting Review', response: 'Cheque collected', respondedOn: '2026-09-26 11:00:00' },
      ],
    });
    expect(t.filter((e) => e.kind === 'answer')).toHaveLength(1);
  });

  it('an answer given before answers were kept on the order is read off the condition', () => {
    const t = followUpTimeline({
      ...base,
      comments: [],
      conditions: [
        { condition: 'x', status: 'Awaiting Review', response: 'Paid 20,000', respondedOn: '2026-09-25 09:00:00' },
      ],
    });
    expect(t.find((e) => e.kind === 'answer')?.text).toBe('Paid 20,000');
  });

  it('every answer is kept, not just the latest', () => {
    const t = followUpTimeline({
      ...base,
      comments: [
        { author: 'Jaimon D', authorRole: 'Sales Rep', comment: 'Half paid', postedOn: '2026-09-25 09:00:00' },
        { author: 'Rajiv', authorRole: 'General Manager', comment: 'Sent back: the rest too', postedOn: '2026-09-25 12:00:00' },
        { author: 'Jaimon D', authorRole: 'Sales Rep', comment: 'All paid', postedOn: '2026-09-26 09:00:00' },
      ],
      conditions: [{ condition: 'x', status: 'Awaiting Review', response: 'All paid' }],
    });
    expect(t.filter((e) => e.kind === 'answer').map((e) => e.text)).toEqual(['Half paid', 'All paid']);
  });

  it('a closed condition ends the story with who closed it', () => {
    const t = followUpTimeline({
      ...base,
      comments: [],
      conditions: [
        { condition: 'x', status: 'Closed', closedBy: 'Rajiv', closedOn: '2026-09-27 10:00:00', closeNote: 'Cheque cleared' },
      ],
    });
    expect(t[t.length - 1]).toMatchObject({ kind: 'closed', who: 'Rajiv' });
  });
});
