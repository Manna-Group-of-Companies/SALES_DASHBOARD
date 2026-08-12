/**
 * Which screens each sales manager's dashboard offers.
 *
 * Three teams of five run out of one codebase, and they are not asked to do
 * the same job. The rule under test is that the reduced set is the *default* —
 * a manager nobody has configured must not silently inherit the order
 * pipeline.
 */

import { describe, expect, it } from 'vitest';
import { canOpen, screensFor, type ManagerScreen } from '../sales';

const PARTY: ManagerScreen[] = ['customers', 'leads', 'locations', 'regularizations'];
const ORDER_SIDE: ManagerScreen[] = ['orders', 'approvals', 'combined', 'stock'];

describe('Pareeth runs the order pipeline', () => {
  it('opens everything', () => {
    for (const s of [...PARTY, ...ORDER_SIDE]) {
      expect(canOpen('Pareeth', s)).toBe(true);
    }
  });
});

describe('Saneesh and Renjith run party records only', () => {
  for (const team of ['Saneesh', 'Renjith']) {
    it(`${team} gets exactly the four party screens`, () => {
      expect(screensFor(team).sort()).toEqual([...PARTY].sort());
    });

    it(`${team} cannot reach the order pipeline`, () => {
      for (const s of ORDER_SIDE) expect(canOpen(team, s)).toBe(false);
    });
  }
});

describe('the reduced set is the default', () => {
  it('does not hand a new, unconfigured team the order pipeline', () => {
    // The failure that costs least is the one where somebody asks for access.
    expect(canOpen('SomeNewManager', 'orders')).toBe(false);
    expect(canOpen('SomeNewManager', 'customers')).toBe(true);
  });

  it('gives somebody who manages no team nothing at all', () => {
    expect(screensFor(undefined)).toEqual([]);
    expect(screensFor('')).toEqual([]);
    expect(screensFor('   ')).toEqual([]);
    expect(canOpen(undefined, 'customers')).toBe(false);
  });
});

describe('the token is matched exactly', () => {
  it('does not treat a different casing as Pareeth', () => {
    // Deliberate: the token is a stored value, not free text, and a loose
    // match here would be a permission granted by a typo.
    expect(canOpen('pareeth', 'orders')).toBe(false);
  });
});
