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
  rollUp,
  sequenceFor,
  stageCaption,
  stageIsUnknown,
  stageProgress,
  tracksFor,
  type StagedLine,
} from '../production';
import { PRODUCTION_STATUS } from '../orderStatus';

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

describe('one track per line', () => {
  /*
   * There were two, when a line was split between a shelf reservation and the
   * part being made, and this block asserted each half kept its own stage,
   * its own sequence and its own field — so a shelf half dispatched while the
   * made half was still curing could not read as a finished order.
   *
   * Reservations were removed on 17 September 2026 with the rest of the
   * minimum-stock doctypes, so no line reports a shelf half. The list shape
   * survives, holding exactly one track.
   */
  it('renders one, on the line own sequence', () => {
    const t = tracksFor({ category: 'PCTR', productionStage: 'Curing' });
    expect(t.map((x) => x.key)).toEqual(['progress']);
    expect(t[0].title).toBe('Progress');
    expect(t[0].sequence).toEqual(SEQUENCES.PCTR);
    expect(t[0].stage).toBe('Curing');
  });

  it('writes to the made-part field, the only one left', () => {
    expect(tracksFor({ category: 'PCTR' })[0].field).toBe('productionStage');
  });

  it('keeps the shorter cycle for a line marked as served from stock', () => {
    // The fulfilment mode is a label the manager sets, not a reservation, and
    // it still picks the three-step cycle: a line taken off the shelf is
    // picked and packed, not extruded and cured.
    const t = tracksFor({ category: 'PCTR', fulfilmentMode: 'From Minimum Stock' });
    expect(t[0].sequence).toEqual(MINIMUM_STOCK_SEQUENCE);
  });

  it('treats a blank stage as Not Started rather than leaving it empty', () => {
    expect(tracksFor({ category: 'PCTR' })[0].stage).toBe('Not Started');
  });
});

describe('the roll-up takes the least advanced line', () => {

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
      [{ category: 'PCTR', productionStage: 'garbage' }],
      [{ category: 'PCTR', productionStage: 'Dispatched' }],
    ];
    for (const c of cases) expect(allowed).toContain(rollUp(c));
  });

  it('is Not Started for an empty order', () => {
    expect(rollUp([])).toBe(PRODUCTION_STATUS.notStarted);
  });
});
