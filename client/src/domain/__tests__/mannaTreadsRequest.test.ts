/**
 * Asking for Manna Treads orders: the batching the Server Script's 50-order
 * limit forces, the one-line summary of a send, and when the office sync has
 * answered. `manna_mt_so_request` throws for more than 50 and marks none, so
 * a selection of 51 sent whole is 51 orders silently not asked for.
 */

import { describe, expect, it } from 'vitest';
import {
  assessOrder,
  batchesOf,
  billableKg,
  MT_REQUEST_MAX,
  MT_VIEW_LABEL,
  notBillableReason,
  requestInBatches,
  requestSummary,
  syncAnswered,
  viewOf,
  type MtRequestOutcome,
} from '../mannaTreadsReorder';

const names = (n: number, from = 1) => Array.from({ length: n }, (_, i) => `SO-${from + i}`);

/** A stand-in for the script: refuses over 50, as the live one does; says ok to each. */
function fakeScript(opts: { failBatch?: number; refuse?: string[]; skip?: string[]; flag?: boolean } = {}) {
  const calls: string[][] = [];
  let inFlight = 0;
  let overlapped = false;
  const send = async (batch: string[]): Promise<MtRequestOutcome> => {
    calls.push(batch);
    inFlight += 1;
    if (inFlight > 1) overlapped = true;
    await Promise.resolve();
    inFlight -= 1;
    if (batch.length > MT_REQUEST_MAX) throw new Error('At most 50 orders at a time.');
    if (opts.failBatch === calls.length) throw new Error('Cannot reach the server. Check your connection.');
    return {
      results: batch
        .filter((n) => !opts.skip?.includes(n))
        .map((n) =>
          opts.refuse?.includes(n)
            ? { order: n, ok: false, message: 'Not an approved order' }
            : { order: n, ok: true, message: 'Queued' },
        ),
      flagRaised: opts.flag ?? true,
    };
  };
  return { send, calls, overlapped: () => overlapped };
}

describe('batches of at most 50', () => {
  it('matches the Server Script limit', () => {
    expect(MT_REQUEST_MAX).toBe(50);
  });

  it('splits in order, the last batch short', () => {
    const b = batchesOf(names(120), 50);
    expect(b.map((x) => x.length)).toEqual([50, 50, 20]);
    expect(b[0][0]).toBe('SO-1');
    expect(b[1][0]).toBe('SO-51');
    expect(b[2][19]).toBe('SO-120');
  });

  it('exactly 50 is one batch, 51 is two', () => {
    expect(batchesOf(names(50), 50)).toHaveLength(1);
    expect(batchesOf(names(51), 50).map((x) => x.length)).toEqual([50, 1]);
  });

  it('nothing is no batches', () => {
    expect(batchesOf([], 50)).toEqual([]);
  });

  it('asks for an order once, however often it is listed', () => {
    expect(batchesOf(['SO-1', 'SO-2', 'SO-1'], 50)).toEqual([['SO-1', 'SO-2']]);
  });

  it('a nonsense size still makes progress', () => {
    expect(batchesOf(names(3), 0)).toEqual([['SO-1'], ['SO-2'], ['SO-3']]);
  });
});

describe('asking in batches', () => {
  it('sends 120 as 50, 50, 20, one after another, and answers for all 120', async () => {
    const s = fakeScript();
    const out = await requestInBatches(names(120), s.send);
    expect(s.calls.map((c) => c.length)).toEqual([50, 50, 20]);
    expect(s.overlapped()).toBe(false);
    expect(out.results).toHaveLength(120);
    expect(out.results.every((r) => r.ok)).toBe(true);
    expect(out.results.map((r) => r.order)).toEqual(names(120));
    expect(out.flagRaised).toBe(true);
  });

  it('a batch that fails marks its own orders not sent, and the next batch still goes', async () => {
    const s = fakeScript({ failBatch: 2 });
    const out = await requestInBatches(names(120), s.send);
    expect(s.calls).toHaveLength(3);
    const byOk = (ok: boolean) => out.results.filter((r) => r.ok === ok).map((r) => r.order);
    expect(byOk(false)).toEqual(names(50, 51));
    expect(byOk(true)).toEqual([...names(50), ...names(20, 101)]);
    expect(out.results[50].message).toBe('Cannot reach the server. Check your connection.');
  });

  it("keeps the script's refusals and its reasons", async () => {
    const s = fakeScript({ refuse: ['SO-2'] });
    const out = await requestInBatches(names(3), s.send);
    expect(out.results[1]).toEqual({ order: 'SO-2', ok: false, message: 'Not an approved order' });
    expect(out.results.filter((r) => r.ok)).toHaveLength(2);
  });

  it('an order the answer does not mention is unanswered, never done', async () => {
    const s = fakeScript({ skip: ['SO-3'] });
    const out = await requestInBatches(names(3), s.send);
    expect(out.results[2]).toEqual({
      order: 'SO-3',
      ok: false,
      message: 'The server did not answer for this order.',
    });
  });

  it('the flag counts as raised if any batch raised it', async () => {
    let n = 0;
    const out = await requestInBatches(names(60), async (batch) => {
      n += 1;
      return { results: batch.map((o) => ({ order: o, ok: true, message: '' })), flagRaised: n === 2 };
    });
    expect(out.flagRaised).toBe(true);
  });

  it('every batch failing is every order not sent, and nothing thrown', async () => {
    const out = await requestInBatches(names(3), async () => {
      throw new Error('Only the accountant may ask for Manna Treads sales orders.');
    });
    expect(out.results.map((r) => r.ok)).toEqual([false, false, false]);
    expect(out.flagRaised).toBe(false);
  });
});

describe('the summary of a send', () => {
  const outcome = (ok: number, refused: number, flagRaised = true): MtRequestOutcome => ({
    results: [
      ...names(ok).map((o) => ({ order: o, ok: true, message: '' })),
      ...names(refused, 100).map((o) => ({ order: o, ok: false, message: 'Not an approved order' })),
    ],
    flagRaised,
  });

  it('all sent', () => {
    expect(requestSummary(outcome(3, 0))).toEqual({ text: '3 sent to the office sync', tone: 'success' });
  });

  it('some refused', () => {
    expect(requestSummary(outcome(2, 1))).toEqual({ text: '2 sent, 1 refused', tone: 'warning' });
  });

  it('none sent', () => {
    expect(requestSummary(outcome(0, 2))).toEqual({ text: 'None sent, 2 refused', tone: 'critical' });
  });

  it('sent, but the sync was not asked to run, says so in the same line', () => {
    const s = requestSummary(outcome(1, 0, false));
    expect(s.text).toMatch(/^1 sent to the office sync\. /);
    expect(s.text).toMatch(/Sync with SAP/);
    expect(s.tone).toBe('warning');
  });
});

describe('when the office sync has answered', () => {
  const asked = { order: 'SO-1', mt_sales_order: '', mt_requested: true, mt_error: '' };

  it('still waiting: asked, no order, no error', () => {
    expect(syncAnswered(asked)).toBe(false);
  });

  it('created, failed, or no longer asked for', () => {
    expect(syncAnswered({ ...asked, mt_sales_order: '440' })).toBe(true);
    expect(syncAnswered({ ...asked, mt_error: 'Item I-11688 is not in Manna Treads SAP' })).toBe(true);
    expect(syncAnswered({ ...asked, mt_requested: false })).toBe(true);
  });

  it('whitespace is not an answer', () => {
    expect(syncAnswered({ ...asked, mt_sales_order: '  ', mt_error: ' ' })).toBe(false);
  });
});

describe('the words for an order with no kilos', () => {
  it('says what is recorded, not that Hi-Tech delivered nothing', () => {
    const text = notBillableReason('nothing_delivered') ?? '';
    expect(text).toMatch(/recorded/);
    expect(text).not.toMatch(/Hi-Tech/);
  });
});

describe('the words for an order asked for', () => {
  it('queued and failed have not reached SAP, and the filter does not say they have', () => {
    expect(viewOf('queued')).toBe('sent');
    expect(viewOf('failed')).toBe('sent');
    expect(MT_VIEW_LABEL.sent).not.toMatch(/SAP/);
  });
});

describe('kilos billable so far, while Hi-Tech still has the order open', () => {
  const line = { item: 'I-1', ordered_kg: 40, amount: 8800, rate_per_kg: 220, delivered_kg: 0, invoiced_kg: 0 };
  const open = (lines: (typeof line)[]) =>
    assessOrder({
      sap_sales_order: '412',
      sap_status: 'bost_Open',
      customer_mt_code: 'C-0001',
      mt_sales_order: '',
      mt_requested: false,
      mt_error: '',
      lines,
    });

  it('invoiced straight from the order, with no delivery, counts the invoiced kilos', () => {
    const a = open([{ ...line, invoiced_kg: 12.5 }]);
    expect(a.state).toBe('at_hitech');
    expect(a.basis).toBe('invoiced');
    expect(billableKg(a)).toBe(12.5);
  });

  it('delivered wins, and the two are never added', () => {
    const a = open([
      { ...line, delivered_kg: 10.1, invoiced_kg: 5 },
      { ...line, item: 'I-2', delivered_kg: 0.2, invoiced_kg: 0 },
    ]);
    expect(a.basis).toBe('delivered');
    expect(billableKg(a)).toBe(10.3);
  });

  it('nothing yet is nothing', () => {
    expect(billableKg(open([line]))).toBe(0);
  });
});
