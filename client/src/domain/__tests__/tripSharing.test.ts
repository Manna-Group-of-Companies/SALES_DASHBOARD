/**
 * Shared trips: whether one counts as being with the manager, and whose money
 * each expense was.
 *
 * Checked against `shared/fixtures/trip_sharing.json`, the same file
 * `app/test/trip_sharing_test.dart` reads. One rep raises a trip and tags the
 * colleagues who came along, so "whose expense is this" has to be answered
 * identically on a phone and on the web — or two sheets disagree about what
 * somebody spent.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/trip_sharing.json';
import type { Trip } from '../types';
import {
  claimFor,
  claimants,
  travelClaim,
  tripClaim,
  EXPENSE_OWNER_FIELD,
  expenseOwner,
  isCommonExpense,
  personalExpense,
  splitExpenses,
  travelledWithManager,
} from '../trips';

const tripOf = (t: { sales_person: string; tagged: string[] }): Trip =>
  ({ id: 'TRP-TEST', person: t.sales_person, taggedReps: t.tagged, date: '2026-08-18' }) as Trip;

describe('shared fixture: the field names', () => {
  it('reads the field the fixture names', () => {
    expect(EXPENSE_OWNER_FIELD).toBe(cases.fields.expense_owner);
  });
});

describe('shared fixture: a trip with the manager', () => {
  for (const c of cases.with_manager) {
    it(c.why, () => {
      expect(travelledWithManager(tripOf(c.trip), c.person, c.manager_name)).toBe(c.expect);
    });
  }
});

describe('shared fixture: whose expense is it', () => {
  for (const c of cases.expenses) {
    it(c.why, () => {
      expect(expenseOwner(c.expense)).toBe(c.expect.owner);
      expect(isCommonExpense(c.expense)).toBe(c.expect.common);
    });
  }
});

describe('shared fixture: splitting a trip', () => {
  for (const c of cases.totals) {
    it(c.why, () => {
      const split = splitExpenses(c.expenses);
      const e = c.expect as Record<string, unknown>;
      if (e.common !== undefined) expect(split.common).toBeCloseTo(e.common as number, 2);
      if (e.trip_total !== undefined) expect(split.total).toBeCloseTo(e.trip_total as number, 2);
      for (const [person, amount] of Object.entries((e.own ?? {}) as Record<string, number>)) {
        expect(split.own.get(person) ?? 0, person).toBeCloseTo(amount, 2);
      }
    });
  }
});

// ------------------------------------------------- dashboard-side detail ---

describe('the bug that made the column read zero', () => {
  it('counted nothing while the trips were sitting right there', () => {
    /*
     * Live on 18 Aug 2026: TRP-00258 (Jaimon D) and TRP-00301 (Test Rep) both
     * carried `|Pareeth Kb|`. The caller passed `person.teamManager`, which is
     * the TOKEN `Pareeth`, and the tags hold the record name `Pareeth Kb`. So
     * every "Shop visit with manager" cell read zero and looked like a data
     * problem rather than a comparison against the wrong string.
     */
    const trip = tripOf({ sales_person: 'Jaimon D', tagged: ['Pareeth Kb'] });
    expect(travelledWithManager(trip, 'Jaimon D', 'Pareeth')).toBe(false);
    expect(travelledWithManager(trip, 'Jaimon D', 'Pareeth Kb')).toBe(true);
  });
});

describe('the common pot is reported, not divided', () => {
  it('is left whole rather than split between the travellers', () => {
    // Nobody asked for it to be split. Inventing a division would put money on
    // somebody's sheet that was never agreed with them.
    const split = splitExpenses([{ amount: 900 }]);
    expect(split.common).toBe(900);
    expect(split.own.size).toBe(0);
    expect(personalExpense([{ amount: 900 }], 'Jaimon D')).toBe(0);
  });

  it('does not let a tagged expense fall into the common pot', () => {
    const split = splitExpenses([
      { custom_for_person: 'Jaimon D', amount: 250 },
      { amount: 800 },
    ]);
    expect(split.common).toBe(800);
    expect(split.own.get('Jaimon D')).toBe(250);
    expect(split.total).toBe(1050);
  });
});

describe('money never appears from nowhere', () => {
  it('always totals to the sum of the rows', () => {
    const rows = [
      { custom_for_person: 'A', amount: 10.5 },
      { custom_for_person: 'B', amount: 20.25 },
      { amount: 5.25 },
      { custom_for_person: '', amount: 4 },
    ];
    const s = splitExpenses(rows);
    const own = [...s.own.values()].reduce((t, n) => t + n, 0);
    expect(own + s.common).toBeCloseTo(s.total, 2);
    expect(s.total).toBeCloseTo(40, 2);
  });

  it('treats a missing or rubbish amount as nothing, not NaN', () => {
    const s = splitExpenses([{ custom_for_person: 'A' }, { amount: 'x' }]);
    expect(s.total).toBe(0);
    expect(Number.isNaN(s.common)).toBe(false);
  });
});

describe('what each person claims off a shared trip', () => {
  const rates = { ownCar: 10, ownBike: 5, companyCar: 0, companyBike: 0, mixed: 0 } as never;

  /** One 10 km own-bike leg = 50, plus the expenses given. */
  const trip = (expenses: { forPerson?: string; amount: number }[]) =>
    ({
      id: 'TRP-1',
      person: 'Test Rep',
      date: '2026-08-18',
      taggedReps: ['Pareeth Kb'],
      legs: [{ mode: 'Own Vehicle (Bike)', distanceKm: 10 }],
      expenses,
    }) as never;

  it('gives a tagged expense to the person it is tagged to, not the trip owner', () => {
    // The report showed a Pareeth-tagged expense under Test Rep, because the
    // owner was charged the whole trip and the colleague was shown their own
    // expenses separately — the same money on two sheets.
    const t = trip([{ forPerson: 'Pareeth Kb', amount: 300 }]);
    expect(claimFor(t, 'Pareeth Kb', rates)).toBe(300);
    expect(claimFor(t, 'Test Rep', rates)).toBe(travelClaim(t, rates));
  });

  it('leaves the common pot and the travel with the owner', () => {
    // The person who drove paid for the fuel and the toll.
    const t = trip([{ amount: 200 }]);
    expect(claimFor(t, 'Test Rep', rates)).toBeCloseTo(travelClaim(t, rates) + 200, 2);
    expect(claimFor(t, 'Pareeth Kb', rates)).toBe(0);
  });

  it('always sums back to the trip’s own total', () => {
    /*
     * The property that says nothing was lost or invented. Whatever the mix of
     * tagged and common, the people on a trip between them claim exactly what
     * the trip cost.
     */
    for (const expenses of [
      [],
      [{ amount: 200 }],
      [{ forPerson: 'Pareeth Kb', amount: 300 }],
      [{ forPerson: 'Pareeth Kb', amount: 300 }, { amount: 200 }],
      [
        { forPerson: 'Test Rep', amount: 120 },
        { forPerson: 'Pareeth Kb', amount: 300 },
        { amount: 200 },
      ],
    ]) {
      const t = trip(expenses);
      const total = claimants(t).reduce((s, p) => s + claimFor(t, p, rates), 0);
      expect(total, JSON.stringify(expenses)).toBeCloseTo(tripClaim(t, rates), 2);
    }
  });

  it('counts somebody who only has a tagged expense as a claimant', () => {
    // Otherwise their money would be dropped from the reconciliation above
    // rather than showing up as missing.
    const t = trip([{ forPerson: 'Amjad Pr', amount: 90 }]);
    expect(claimants(t)).toContain('Amjad Pr');
    expect(claimFor(t, 'Amjad Pr', rates)).toBe(90);
  });
});
