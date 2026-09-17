/**
 * A belt comes out of a roll.
 *
 * `shared/fixtures/belt_from_roll.json` states the rule; this file asserts the
 * dashboard obeys it, and `app/test/belt_from_roll_test.dart` asserts the phone
 * does. Both read the same cases, so the two cannot drift.
 *
 * The bug this closes: a rep ordered five rolls and one loose belt of a PCTR
 * item against a pool of 48 rolls, and was told the belt would be made to
 * order. Rolls and belts were clamped against the pool independently, so a
 * pool holding whole rolls and no loose belts covered zero belts.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/belt_from_roll.json';
import { allocateFromPool, splitOf } from '../minimumStock';

interface AllocateCase {
  why: string;
  want: { rolls: number; belts: number };
  pool: { rolls: number; belts: number; beltsPerRoll: number };
  expect: {
    rolls: number;
    belts: number;
    rollsOpened: number;
    shortRolls: number;
    shortBelts: number;
  };
}

const CASES = cases.allocate as AllocateCase[];

describe('serving loose belts by opening a roll', () => {
  for (const c of CASES) {
    it(c.why, () => {
      expect(
        allocateFromPool({
          wantRolls: c.want.rolls,
          wantBelts: c.want.belts,
          poolRolls: c.pool.rolls,
          poolBelts: c.pool.belts,
          beltsPerRoll: c.pool.beltsPerRoll,
        }),
      ).toEqual(c.expect);
    });
  }

  it('never promises more than was asked for', () => {
    for (const c of CASES) {
      const got = allocateFromPool({
        wantRolls: c.want.rolls,
        wantBelts: c.want.belts,
        poolRolls: c.pool.rolls,
        poolBelts: c.pool.belts,
        beltsPerRoll: c.pool.beltsPerRoll,
      });
      expect(got.rolls).toBeLessThanOrEqual(c.want.rolls);
      expect(got.belts).toBeLessThanOrEqual(c.want.belts);
    }
  });

  it('never takes more rolls off the shelf than are on it', () => {
    // Whole rolls promised plus rolls opened for belts both leave the roll
    // count, and together they cannot exceed the pool. Getting this wrong
    // would oversell the shelf by exactly the rolls that were cut.
    for (const c of CASES) {
      const got = allocateFromPool({
        wantRolls: c.want.rolls,
        wantBelts: c.want.belts,
        poolRolls: c.pool.rolls,
        poolBelts: c.pool.belts,
        beltsPerRoll: c.pool.beltsPerRoll,
      });
      expect(got.rolls + got.rollsOpened).toBeLessThanOrEqual(c.pool.rolls);
    }
  });

  it('accounts for every unit asked for, as stock or as production', () => {
    for (const c of CASES) {
      const got = allocateFromPool({
        wantRolls: c.want.rolls,
        wantBelts: c.want.belts,
        poolRolls: c.pool.rolls,
        poolBelts: c.pool.belts,
        beltsPerRoll: c.pool.beltsPerRoll,
      });
      expect(got.rolls + got.shortRolls).toBe(c.want.rolls);
      expect(got.belts + got.shortBelts).toBe(c.want.belts);
    }
  });
});

describe('the split shown for the reported case', () => {
  /*
   * This asserted `holdPlan` — the write plan that decided what reservation to
   * put on the shelf. There is no reservation to write any more, and the same
   * rule now governs a *display*: how much of the line the shelf covers, and
   * how much the floor is asked for.
   */
  it('covers the belt off the shelf instead of sending it to production', () => {
    // 48 rolls available, nothing loose.
    const split = splitOf({ rolls: 5, looseBelts: 1 }, { rolls: 48, belts: 0 }, 6);

    expect(split.fromStock).toEqual({ rolls: 5, belts: 1 });
    // `toMake` is what production is raised for, and it must be nothing here.
    expect(split.toMake).toEqual({ rolls: 0, belts: 0 });
  });

  it('still refuses to cut an item with no belts-per-roll on its master', () => {
    const split = splitOf({ rolls: 0, looseBelts: 1 }, { rolls: 48, belts: 0 });
    expect(split.fromStock.belts).toBe(0);
    expect(split.toMake.belts).toBe(1);
  });
});
