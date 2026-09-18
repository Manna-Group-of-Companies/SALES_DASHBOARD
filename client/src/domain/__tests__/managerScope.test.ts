/**
 * Which screens each sales manager's dashboard offers.
 *
 * Three teams of five run out of one codebase, and they are not asked to do
 * the same job. The rule under test is that the reduced set is the *default* —
 * a manager nobody has configured must not silently inherit the order
 * pipeline.
 */

import { describe, expect, it } from 'vitest';
import { canOpen, canOpenAs, screensFor, screensForUser, type ManagerScreen } from '../sales';

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

/**
 * The GM is scoped by role, not by team.
 *
 * Their escalation queue links straight to `/orders/:id`, and that route is
 * behind `TeamRoute`. A GM runs no sales team of their own, so a team-only
 * test gave them nothing and the link redirected to `/` — which on screen is
 * a button that does nothing at all.
 */
describe('the General Manager', () => {
  it('opens every screen without managing a team', () => {
    for (const s of [...PARTY, ...ORDER_SIDE]) {
      expect(canOpenAs('general_manager', undefined, s)).toBe(true);
    }
  });

  it('reaches the order they were escalated, which is the whole point', () => {
    expect(canOpenAs('general_manager', undefined, 'orders')).toBe(true);
  });

  it('is not narrowed by a team that would narrow a sales manager', () => {
    // Saneesh's token gives a sales manager party records only. It must not
    // take the order pipeline away from a GM who happens to carry one.
    expect(canOpenAs('general_manager', 'Saneesh', 'orders')).toBe(true);
    expect(canOpen('Saneesh', 'orders')).toBe(false);
  });

  it('changes nothing for anybody else', () => {
    expect(screensForUser('sales_manager', 'Pareeth')).toEqual(screensFor('Pareeth'));
    expect(screensForUser('sales_manager', 'Saneesh')).toEqual(screensFor('Saneesh'));
    expect(screensForUser('production_manager', undefined)).toEqual([]);
    expect(canOpenAs('stock_manager', undefined, 'orders')).toBe(false);
    expect(canOpenAs(undefined, undefined, 'orders')).toBe(false);
  });
});
