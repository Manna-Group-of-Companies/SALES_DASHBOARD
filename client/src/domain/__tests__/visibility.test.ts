/**
 * Which customers, leads and routes a rep may see.
 *
 * Checked against `shared/fixtures/visibility.json`, the same file
 * `app/test/visibility_test.dart` reads. This one decides whether one unit's
 * customers can be seen by another, so it is exactly the rule that must not
 * differ between the phone and the dashboard.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/visibility.json';
import {
  POOLED_UNITS,
  VISIBILITY_FIELD,
  canAssignOwner,
  isCoveringFor,
  isPooledUnit,
  sharesWithUnit,
  visibleOwnerValues,
  visibleReps,
  type Person,
} from '../visibility';

/** The fixture speaks raw ERPNext field names; the domain speaks its own. */
const PEOPLE: Person[] = cases.people.map((p) => ({
  name: p.name,
  unit: p.custom_company,
  enabled: p.enabled === 1,
  isGroup: p.is_group === 1,
}));

describe('shared fixture: the field names and the pooled units', () => {
  it('reads the fields the fixture names', () => {
    expect(VISIBILITY_FIELD.unit).toBe(cases.fields.unit);
    expect(VISIBILITY_FIELD.customerOwner).toBe(cases.fields.customer_owner);
    expect(VISIBILITY_FIELD.leadOwner).toBe(cases.fields.lead_owner);
    expect(VISIBILITY_FIELD.routeOwner).toBe(cases.fields.route_owner);
  });

  it('pools exactly the units the fixture pools', () => {
    expect([...POOLED_UNITS]).toEqual(cases.pooled_units);
  });
});

describe('shared fixture: which units are pooled', () => {
  for (const c of cases.pooled) {
    it(c.why, () => {
      expect(isPooledUnit(c.unit)).toBe(c.expect);
    });
  }
});

describe('shared fixture: who sees whose records', () => {
  for (const c of cases.visible) {
    it(c.why, () => {
      const got = visibleReps(PEOPLE, c.person);
      if (c.expect) expect(got.sort()).toEqual([...c.expect].sort());
      for (const excluded of c.expect_excludes ?? []) expect(got).not.toContain(excluded);
    });
  }
});

describe('shared fixture: what an unassigned record needs to be seen', () => {
  for (const c of cases.owner_values) {
    it(c.why, () => {
      expect(visibleOwnerValues(PEOPLE, c.person).sort()).toEqual([...c.expect].sort());
    });
  }
});

describe('shared fixture: who may assign an owner', () => {
  for (const c of cases.can_assign) {
    it(c.why, () => {
      expect(canAssignOwner(PEOPLE, c.person)).toBe(c.expect);
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('pooling never leaks across units', () => {
  it('shows a UAE rep no Indian customers, and an Indian rep no UAE ones', () => {
    const uae = visibleReps(PEOPLE, 'Kailas Babu');
    for (const other of ['Amjad Pr', 'Sirajudheen Kasim', 'Prasad V']) {
      expect(uae).not.toContain(other);
    }
    expect(visibleReps(PEOPLE, 'Amjad Pr')).toEqual(['Amjad Pr']);
  });

  it('never returns the whole company for anybody', () => {
    for (const p of PEOPLE) {
      expect(visibleReps(PEOPLE, p.name).length).toBeLessThan(PEOPLE.length);
    }
  });
});

describe('it fails closed', () => {
  it('gives an unresolvable login nothing rather than everything', () => {
    // An empty list is handed to the API as "show nothing". A filter of
    // `undefined` would be read as no filter, and answer with every customer
    // in the company — the bug that was live on 12 Aug 2026.
    expect(visibleReps(PEOPLE, undefined)).toEqual([]);
    expect(visibleReps(PEOPLE, 'nobody@nowhere')).toEqual([]);
    expect(visibleReps([], 'Kailas Babu')).toEqual([]);
  });

  it('does not read a missing unit as membership of the pool', () => {
    const orphan: Person[] = [{ name: 'No Unit', unit: '', enabled: true, isGroup: false }];
    expect(visibleReps([...PEOPLE, ...orphan], 'No Unit')).toEqual(['No Unit']);
  });

  it('leaves a disabled person with nothing, rather than their old team', () => {
    expect(visibleReps(PEOPLE, 'Ex UAE Rep')).toEqual([]);
  });
});

describe('who is covering for whom', () => {
  it('knows a UAE rep is looking at a colleague’s customer', () => {
    expect(isCoveringFor(PEOPLE, 'Kailas Babu', 'Manikandan')).toBe(true);
  });

  it('does not call a rep’s own customer a cover', () => {
    expect(isCoveringFor(PEOPLE, 'Kailas Babu', 'Kailas Babu')).toBe(false);
    expect(isCoveringFor(PEOPLE, 'Kailas Babu', undefined)).toBe(false);
  });

  it('is never true outside a pooled unit, because nothing is shared there', () => {
    expect(isCoveringFor(PEOPLE, 'Amjad Pr', 'Sirajudheen Kasim')).toBe(false);
  });

  it('says a UAE rep shares and an Indian rep does not', () => {
    expect(sharesWithUnit(PEOPLE, 'Renjith')).toBe(true);
    expect(sharesWithUnit(PEOPLE, 'Amjad Pr')).toBe(false);
    expect(sharesWithUnit(PEOPLE, 'nobody')).toBe(false);
  });
});
