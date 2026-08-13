/**
 * What production changed since the reader last looked.
 *
 * Checked against `shared/fixtures/stage_watch.json`, the same file
 * `app/test/stage_watch_test.dart` reads.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/stage_watch.json';
import {
  STAGE_FIELD,
  changedLineIds,
  changesSince,
  describeChange,
  snapshotOf,
  stageText,
  type StageSnapshot,
} from '../stageWatch';

describe('shared fixture: the field names', () => {
  it('watches the two fields the fixture names', () => {
    expect(STAGE_FIELD.made).toBe(cases.fields.made_part);
    expect(STAGE_FIELD.shelf).toBe(cases.fields.shelf_part);
  });
});

describe('shared fixture: what changed', () => {
  for (const c of cases.changes) {
    it(c.why, () => {
      const got = changesSince(c.seen as StageSnapshot | null, c.lines);
      expect(got).toHaveLength(c.expect.length);
      c.expect.forEach((want, i) => {
        expect(got[i].lineId).toBe(want.line_id);
        expect(got[i].part).toBe(want.part);
        expect(got[i].from).toBe(want.from);
        expect(got[i].to).toBe(want.to);
      });
    });
  }
});

describe('shared fixture: the snapshot', () => {
  for (const c of cases.snapshot) {
    it(c.why, () => {
      expect(snapshotOf(c.lines)).toEqual(c.expect);
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('a first look establishes the baseline', () => {
  it('reports nothing, then reports the next move', () => {
    // The whole point: opening an order is not news. What happens after is.
    const lines = [{ name: 'row1', item_name: 'X', custom_production_stage: 'Curing' }];
    expect(changesSince(null, lines)).toEqual([]);

    const seen = snapshotOf(lines);
    const moved = [{ name: 'row1', item_name: 'X', custom_production_stage: 'Packed' }];
    expect(changesSince(seen, moved)).toHaveLength(1);
  });

  it('does not repeat a change once it has been seen', () => {
    const moved = [{ name: 'row1', item_name: 'X', custom_production_stage: 'Packed' }];
    expect(changesSince(snapshotOf(moved), moved)).toEqual([]);
  });
});

describe('the three ways Frappe returns an unset field', () => {
  it('are all the same thing, and none of them is a change', () => {
    const seen: StageSnapshot = { row1: '|' };
    for (const v of [null, undefined, '', '   ', 'null', 'undefined']) {
      const lines = [{ name: 'row1', item_name: 'X', custom_production_stage: v }];
      expect(changesSince(seen, lines), `stage ${JSON.stringify(v)}`).toEqual([]);
    }
  });
});

describe('what the reader is shown', () => {
  it('names which half of a split line moved', () => {
    // "this line moved" would hide that the other half has not.
    // The made half is left where it was, so only the shelf half is news.
    const c = changesSince({ row1: 'Cutting|Packed' }, [
      {
        name: 'row1',
        item_name: '160 SR 99',
        custom_production_stage: 'Cutting',
        custom_stock_stage: 'Dispatched',
      },
    ]);
    expect(c).toHaveLength(1);
    expect(describeChange(c[0])).toContain('from stock');
    expect(describeChange(c[0])).toContain('Packed → Dispatched');
  });

  it('says "Not started" rather than leaving a blank', () => {
    expect(stageText('')).toBe('Not started');
    expect(stageText('Curing')).toBe('Curing');
    const c = changesSince({ row1: '|' }, [
      { name: 'row1', item_name: 'X', custom_production_stage: 'Cutting' },
    ]);
    expect(describeChange(c[0])).toContain('Not started → Cutting');
  });

  it('collects the moved lines for highlighting, without duplicates', () => {
    const c = changesSince({ row1: 'Cutting|Packed' }, [
      {
        name: 'row1',
        item_name: 'X',
        custom_production_stage: 'Curing',
        custom_stock_stage: 'Dispatched',
      },
    ]);
    expect(c).toHaveLength(2);
    expect([...changedLineIds(c)]).toEqual(['row1']);
  });
});

describe('an order whose lines were edited', () => {
  it('reports neither the added nor the removed line as a stage change', () => {
    const seen: StageSnapshot = { row1: 'Curing|', row2: 'Cutting|' };
    const now = [
      { name: 'row1', item_name: 'X', custom_production_stage: 'Curing' },
      { name: 'row3', item_name: 'Z', custom_production_stage: 'Cutting' },
    ];
    expect(changesSince(seen, now)).toEqual([]);
  });

  it('ignores a row with no name rather than keying the snapshot on nothing', () => {
    expect(snapshotOf([{ item_name: 'X' }])).toEqual({});
  });
});
