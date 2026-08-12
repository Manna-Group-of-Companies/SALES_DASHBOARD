/**
 * Team scoping — the boundary that keeps one manager out of another's data.
 *
 * The rule under test is that it **fails closed**. `teamOf` returning an empty
 * list was being handed to the API as "no filter", which an API reasonably
 * reads as *every rep in the company* — so a manager whose team could not be
 * resolved silently saw everybody's customers, leads and location captures.
 */

import { describe, expect, it } from 'vitest';
import { isTeamManager, reportsOf, scopeFor, teamOf } from '../sales';
import type { SalesPerson } from '../types';

const p = (id: string, teamManager: string, over: Partial<SalesPerson> = {}): SalesPerson => ({
  id,
  name: id,
  teamManager,
  unit: 'Manna Treads',
  enabled: true,
  isGroup: false,
  ...over,
});

/** The three real teams, five people each. */
const PEOPLE: SalesPerson[] = [
  p('Amjad Pr', 'Pareeth'),
  p('Jaimon D', 'Pareeth'),
  p('Pareeth Kb', 'Pareeth'),
  p('Prashanth', 'Pareeth'),
  p('Sirajudheen Kasim', 'Pareeth'),
  p('Bibin Balaravi', 'Saneesh'),
  p('Nikhil Tk', 'Saneesh'),
  p('Prasad V', 'Saneesh'),
  p('Saneesh', 'Saneesh'),
  p('Subhash', 'Saneesh'),
  p('Kailas Babu', 'Renjith'),
  p('Manikandan', 'Renjith'),
  p('Rajeev S', 'Renjith'),
  p('Renjith', 'Renjith'),
  p('Shihab K', 'Renjith'),
  p('Sales Team', '', { isGroup: true }),
  p('Test Rep', '', { enabled: false }),
];

describe('a manager sees their own team and nobody else', () => {
  it('gives Pareeth his five', () => {
    expect(teamOf(PEOPLE, 'Pareeth Kb').sort()).toEqual(
      ['Amjad Pr', 'Jaimon D', 'Pareeth Kb', 'Prashanth', 'Sirajudheen Kasim'].sort(),
    );
  });

  it('gives Renjith the UAE five, and none of Saneesh’s', () => {
    const uae = teamOf(PEOPLE, 'Renjith');
    expect(uae.sort()).toEqual(
      ['Kailas Babu', 'Manikandan', 'Rajeev S', 'Renjith', 'Shihab K'].sort(),
    );
    for (const other of ['Prasad V', 'Nikhil Tk', 'Bibin Balaravi', 'Subhash']) {
      expect(uae).not.toContain(other);
    }
  });

  it('never overlaps two teams', () => {
    const a = new Set(teamOf(PEOPLE, 'Pareeth Kb'));
    const b = teamOf(PEOPLE, 'Saneesh');
    const c = teamOf(PEOPLE, 'Renjith');
    for (const id of [...b, ...c]) expect(a.has(id)).toBe(false);
  });

  it('recognises a manager whose name is longer than the token', () => {
    // "Pareeth Kb" manages team "Pareeth". A rep never matches.
    expect(isTeamManager(PEOPLE.find((x) => x.id === 'Pareeth Kb'))).toBe(true);
    expect(isTeamManager(PEOPLE.find((x) => x.id === 'Amjad Pr'))).toBe(false);
  });

  it('excludes the manager from their own reports', () => {
    expect(reportsOf(PEOPLE, 'Renjith').map((x) => x.id)).not.toContain('Renjith');
    expect(reportsOf(PEOPLE, 'Renjith')).toHaveLength(4);
  });

  it('leaves out disabled people and group nodes', () => {
    const all = [
      ...teamOf(PEOPLE, 'Pareeth Kb'),
      ...teamOf(PEOPLE, 'Saneesh'),
      ...teamOf(PEOPLE, 'Renjith'),
    ];
    expect(all).not.toContain('Sales Team');
    expect(all).not.toContain('Test Rep');
    expect(all).toHaveLength(15);
  });
});

describe('scoping fails CLOSED', () => {
  it('returns null — not an empty list — when the team cannot be resolved', () => {
    // null is what forces a caller to refuse; [] was being sent as "no filter".
    expect(scopeFor(PEOPLE, 'Amjad Pr')).toBeNull();
    expect(scopeFor(PEOPLE, 'nobody@nowhere')).toBeNull();
    expect(scopeFor(PEOPLE, undefined)).toBeNull();
    expect(scopeFor([], 'Pareeth Kb')).toBeNull();
  });

  it('gives a rep no scope at all, rather than the whole company', () => {
    // The bug this guards: a rep or an unlinked login seeing everyone.
    expect(scopeFor(PEOPLE, 'Prasad V')).toBeNull();
  });

  it('returns a real list for a real manager', () => {
    expect(scopeFor(PEOPLE, 'Saneesh')).toHaveLength(5);
  });

  it('gives nothing when a manager’s name stops matching their token', () => {
    // Renamed in ERPNext, token left behind — must go quiet, not open up.
    const renamed = PEOPLE.map((x) => (x.id === 'Saneesh' ? p('S. Kumar', 'Saneesh') : x));
    expect(scopeFor(renamed, 'S. Kumar')).toBeNull();
  });
});
