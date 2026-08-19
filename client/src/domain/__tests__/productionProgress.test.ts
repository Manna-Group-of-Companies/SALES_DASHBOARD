/**
 * How far through production a line is, as the floor sees it.
 *
 * Checked against `shared/fixtures/production_progress.json`, the same file
 * `app/test/production_progress_test.dart` reads.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/production_progress.json';
import {
  DISPATCHED,
  PACKED,
  MINIMUM_STOCK_SEQUENCE,
  SEQUENCES,
  FALLBACK_SEQUENCE,
  rollUp,
  workComplete,
  workPosition,
  workProgress,
  workSequence,
  workTotal,
} from '../production';
import { PRODUCTION_STATUS } from '../orderStatus';

const SEQ: Record<string, string[]> = {
  minimum_stock: MINIMUM_STOCK_SEQUENCE,
  pctr: SEQUENCES.PCTR,
  generic: FALLBACK_SEQUENCE,
};

describe('shared fixture: the sequences the fixture names', () => {
  it('match what the code actually uses', () => {
    for (const [key, seq] of Object.entries(cases.sequences)) {
      expect(SEQ[key]).toEqual(seq);
    }
  });
});

describe('shared fixture: what the floor is shown', () => {
  for (const c of cases.progress) {
    it(c.why, () => {
      const seq = SEQ[c.sequence];
      const want = c.expect as Record<string, number | boolean>;

      expect(workPosition(seq, c.stage)).toBe(want.position);
      if (want.total !== undefined) expect(workTotal(seq)).toBe(want.total);
      if (want.progress !== undefined) expect(workProgress(seq, c.stage)).toBe(want.progress);
      if (want.complete !== undefined) expect(workComplete(seq, c.stage)).toBe(want.complete);
    });
  }
});

// -------------------------------------------------- dashboard-side detail ---

describe('the floor is never shown a stage it cannot reach', () => {
  it('drops Dispatched from every sequence it works', () => {
    for (const seq of [MINIMUM_STOCK_SEQUENCE, ...Object.values(SEQUENCES), FALLBACK_SEQUENCE]) {
      expect(workSequence(seq)).not.toContain(DISPATCHED);
      // ...and loses nothing else on the way.
      expect(workSequence(seq)).toHaveLength(seq.length - 1);
    }
  });

  it('ends every cycle on Packed, which is what makes packed mean finished', () => {
    for (const seq of [MINIMUM_STOCK_SEQUENCE, ...Object.values(SEQUENCES), FALLBACK_SEQUENCE]) {
      expect(workSequence(seq).at(-1)).toBe(PACKED);
      expect(workComplete(seq, PACKED)).toBe(true);
      expect(workProgress(seq, PACKED)).toBe(1);
    }
  });
});

describe('the order roll-up is deliberately left alone', () => {
  /*
   * The floor's own progress bar and the order's Ready/Dispatched status
   * answer different questions. Packed finishes the making; only Dispatch
   * Planning, once the full quantity has gone, finishes the order. Collapsing
   * the two would have an order calling itself dispatched while the goods sat
   * on the floor.
   */
  it('still separates a packed order from a dispatched one', () => {
    const packed = [{ category: 'PCTR', productionStage: PACKED }];
    const gone = [{ category: 'PCTR', productionStage: DISPATCHED }];

    expect(workComplete(SEQUENCES.PCTR, PACKED)).toBe(true);
    expect(rollUp(packed)).toBe(PRODUCTION_STATUS.ready);
    expect(rollUp(gone)).toBe(PRODUCTION_STATUS.dispatched);
  });
});
