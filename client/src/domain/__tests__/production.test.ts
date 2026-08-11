/**
 * Production stages and the roll-up.
 *
 * The rule that must never break: **errors round down.** An order can look
 * less finished than it is; it must never look more finished than it is,
 * because the second one ships nothing and tells someone it did.
 */

import { describe, expect, it } from 'vitest';
import {
  FALLBACK_SEQUENCE,
  MINIMUM_STOCK_SEQUENCE,
  SEQUENCES,
  hasMakeHalf,
  hasStockHalf,
  rollUp,
  sequenceFor,
  stageCaption,
  stageIsUnknown,
  stageProgress,
  tracksFor,
  type StagedLine,
} from '../production';
import { PRODUCTION_STATUS } from '../orderStatus';

const split = (over: Partial<StagedLine> = {}): StagedLine => ({
  category: 'PCTR',
  reservedRolls: 4,
  reservedBelts: 2,
  toMakeRolls: 4,
  toMakeBelts: 0,
  splitKnown: true,
  ...over,
});

describe('a minimum-stock line skips the making stages', () => {
  it('gets the three-step cycle however it was made', () => {
    expect(sequenceFor({ category: 'PCTR', fulfilmentMode: 'From Minimum Stock' })).toEqual([
      'Not Started',
      'Packed',
      'Dispatched',
    ]);
  });

  it('gets the family cycle when it is being made', () => {
    expect(sequenceFor({ category: 'PCTR', fulfilmentMode: 'New Production' })).toEqual(
      SEQUENCES.PCTR,
    );
  });

  it('falls back for an unrecognised category rather than throwing', () => {
    expect(sequenceFor({ category: 'NONSENSE' })).toEqual(FALLBACK_SEQUENCE);
    expect(sequenceFor({})).toEqual(FALLBACK_SEQUENCE);
  });
});

describe('two tracks on a split line', () => {
  it('renders one per half, with the quantity in the title', () => {
    const t = tracksFor(split({ stockStage: 'Packed', productionStage: 'Curing' }));
    expect(t.map((x) => x.key)).toEqual(['stock', 'make']);
    expect(t[0].title).toBe('From minimum stock · 4 + 2 belts');
    expect(t[1].title).toBe('To be made · 4');
    expect(t[0].sequence).toEqual(MINIMUM_STOCK_SEQUENCE);
    expect(t[1].sequence).toEqual(SEQUENCES.PCTR);
  });

  it('writes each half to its own field', () => {
    const t = tracksFor(split());
    expect(t[0].field).toBe('stockStage');
    expect(t[1].field).toBe('productionStage');
  });

  it('shows one track when the line is wholly off the shelf', () => {
    const t = tracksFor(split({ toMakeRolls: 0, toMakeBelts: 0 }));
    expect(t.map((x) => x.key)).toEqual(['stock']);
  });

  it('shows one track when nothing was reserved', () => {
    const t = tracksFor(split({ reservedRolls: 0, reservedBelts: 0 }));
    expect(t.map((x) => x.key)).toEqual(['progress']);
  });

  it('shows ONE honest track when the split could not be read', () => {
    // Two invented tracks would be worse than one true one.
    const t = tracksFor(split({ splitKnown: false }));
    expect(t.map((x) => x.key)).toEqual(['progress']);
    expect(hasStockHalf(split({ splitKnown: false }))).toBe(false);
    expect(hasMakeHalf(split({ splitKnown: false }))).toBe(false);
  });
});

describe('the roll-up weighs both halves', () => {
  it('THE CASE: shelf half dispatched, made half curing, is NOT finished', () => {
    expect(rollUp([split({ stockStage: 'Dispatched', productionStage: 'Curing' })])).toBe(
      PRODUCTION_STATUS.inProduction,
    );
  });

  it('is finished only when both halves are', () => {
    expect(rollUp([split({ stockStage: 'Dispatched', productionStage: 'Dispatched' })])).toBe(
      PRODUCTION_STATUS.dispatched,
    );
  });

  it('is Ready only when the slowest half is packed', () => {
    expect(rollUp([split({ stockStage: 'Packed', productionStage: 'Packed' })])).toBe(
      PRODUCTION_STATUS.ready,
    );
    expect(rollUp([split({ stockStage: 'Packed', productionStage: 'Not Started' })])).toBe(
      PRODUCTION_STATUS.inProduction,
    );
  });

  it('is started as soon as the fastest half is touched', () => {
    expect(rollUp([split({ stockStage: 'Not Started', productionStage: 'Curing' })])).toBe(
      PRODUCTION_STATUS.inProduction,
    );
  });

  it('is Ready by the slowest LINE, not the fastest', () => {
    expect(
      rollUp([
        { category: 'PCTR', productionStage: 'Dispatched' },
        { category: 'CTR', productionStage: 'Not Started' },
      ]),
    ).toBe(PRODUCTION_STATUS.inProduction);
  });
});

describe('errors round DOWN, never to shippable', () => {
  it('treats an off-sequence stage as not started', () => {
    // "Curing" is not in the three-step stock cycle.
    const bad = { category: 'PCTR', fulfilmentMode: 'From Minimum Stock', productionStage: 'Curing' };
    expect(stageIsUnknown(bad)).toBe(true);
    expect(rollUp([bad])).toBe(PRODUCTION_STATUS.notStarted);
    expect(stageProgress(bad)).toBe(0);
    expect(stageCaption(bad)).toContain('not in this product');
  });

  it('never lets a typo make an order look dispatched', () => {
    expect(rollUp([{ category: 'PCTR', productionStage: 'Dispatchd' }])).toBe(
      PRODUCTION_STATUS.notStarted,
    );
  });

  it('only ever produces one of the four Select values', () => {
    const allowed = Object.values(PRODUCTION_STATUS) as string[];
    const cases: StagedLine[][] = [
      [],
      [{ category: 'ZZZ', productionStage: 'nonsense' }],
      [{ category: 'VS', productionStage: 'Sealing' }],
      [split({ stockStage: 'garbage', productionStage: 'garbage' })],
      [split({ stockStage: 'Dispatched', productionStage: 'Dispatched' })],
    ];
    for (const c of cases) expect(allowed).toContain(rollUp(c));
  });

  it('is Not Started for an empty order', () => {
    expect(rollUp([])).toBe(PRODUCTION_STATUS.notStarted);
  });
});
