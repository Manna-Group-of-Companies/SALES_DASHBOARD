/**
 * The day's roster.
 *
 * Calling somebody absent is a payroll consequence and, on a bad day, an
 * accusation. So the rule under test is the order of the checks: every
 * innocent explanation has to be exhausted before `absent` is reached.
 */

import { describe, expect, it } from 'vitest';
import { rosterCounts, rosterFor, unexplained } from '../attendance';
import type { AttendanceLog, FieldLeaveRequest, SalesPerson } from '../types';

const person = (id: string, name = id): SalesPerson => ({
  id,
  name,
  teamManager: 'Pareeth',
  unit: 'Manna Treads',
  enabled: true,
  isGroup: false,
});

const PEOPLE = [person('Amjad Pr'), person('Jaimon D'), person('Prashanth')];

// A Thursday — an ordinary working day.
const DAY = '2026-08-13';
// A Sunday.
const SUNDAY = '2026-08-16';

const log = (p: string, over: Partial<AttendanceLog> = {}): AttendanceLog => ({
  id: `L-${p}`,
  person: p,
  date: DAY,
  punchIn: '2026-08-13 09:30:00',
  punchOut: '2026-08-13 18:00:00',
  status: 'Punched Out',
  workingHours: 8.5,
  ...over,
});

/** Granted needs BOTH approvals for an ordinary rep. */
const leave = (p: string, over: Partial<FieldLeaveRequest> = {}): FieldLeaveRequest => ({
  id: `LV-${p}`,
  person: p,
  date: DAY,
  days: 1,
  halfDay: false,
  status: 'Approved',
  approverType: 'HR',
  requesterIsManager: false,
  managerApproved: true,
  hrApproved: true,
  ...over,
});

describe('a punch beats everything', () => {
  it('marks somebody present even when a leave request exists for the day', () => {
    // Cancelled their leave and came in; the request was never withdrawn.
    const r = rosterFor(DAY, PEOPLE, [log('Amjad Pr')], [leave('Amjad Pr')]);
    expect(r.find((x) => x.person.id === 'Amjad Pr')!.status).toBe('present');
  });

  it('needs both punches — one is still out, not a finished day', () => {
    const r = rosterFor(
      DAY,
      PEOPLE,
      [log('Amjad Pr', { punchOut: undefined, status: 'Punched In' })],
      [],
    );
    expect(r.find((x) => x.person.id === 'Amjad Pr')!.status).toBe('on_floor');
  });
});

describe('leave granted is not absence', () => {
  it('reports on_leave when both approvals are in', () => {
    const r = rosterFor(DAY, PEOPLE, [], [leave('Jaimon D')]);
    expect(r.find((x) => x.person.id === 'Jaimon D')!.status).toBe('on_leave');
  });

  it('keeps an undecided request separate from granted leave', () => {
    // The distinction that matters: an undecided request is not time off, and
    // folding it into "on leave" would hide unapproved absence.
    const pending = leave('Jaimon D', {
      status: 'Pending Approval',
      managerApproved: false,
      hrApproved: false,
    });
    expect(rosterFor(DAY, PEOPLE, [], [pending]).find((x) => x.person.id === 'Jaimon D')!.status)
      .toBe('leave_pending');
  });

  it('does not treat a half-granted request as leave', () => {
    const half = leave('Jaimon D', { status: 'Pending Approval', hrApproved: false });
    expect(rosterFor(DAY, PEOPLE, [], [half]).find((x) => x.person.id === 'Jaimon D')!.status)
      .toBe('leave_pending');
  });

  it('does not treat a rejected request as leave', () => {
    const no = leave('Jaimon D', { status: 'Rejected' });
    expect(rosterFor(DAY, PEOPLE, [], [no]).find((x) => x.person.id === 'Jaimon D')!.status)
      .toBe('absent');
  });

  it('carries the half-day flag through', () => {
    const r = rosterFor(DAY, PEOPLE, [], [leave('Jaimon D', { halfDay: true, days: 0.5 })]);
    expect(r.find((x) => x.person.id === 'Jaimon D')!.halfDay).toBe(true);
  });

  it('prefers a granted request over a pending one on the same day', () => {
    const pending = { ...leave('Jaimon D'), id: 'LV-p', status: 'Pending Approval' as const, managerApproved: false, hrApproved: false };
    const granted = leave('Jaimon D');
    expect(rosterFor(DAY, PEOPLE, [], [pending, granted]).find((x) => x.person.id === 'Jaimon D')!.status)
      .toBe('on_leave');
  });
});

describe('Sunday is nobody’s absence', () => {
  it('reports weekly_off rather than absent', () => {
    const r = rosterFor(SUNDAY, PEOPLE, [], []);
    expect(r.every((x) => x.status === 'weekly_off')).toBe(true);
    expect(rosterCounts(r).absent).toBe(0);
  });

  it('still reports somebody who worked the Sunday', () => {
    const sundayLog = log('Amjad Pr', { date: SUNDAY });
    const r = rosterFor(SUNDAY, PEOPLE, [sundayLog], []);
    expect(r.find((x) => x.person.id === 'Amjad Pr')!.status).toBe('present');
  });
});

describe('absent is the last resort', () => {
  it('is reached only with no punch, no leave and not a Sunday', () => {
    const r = rosterFor(DAY, PEOPLE, [], []);
    expect(r.every((x) => x.status === 'absent')).toBe(true);
  });

  it('counts a full mixed day correctly', () => {
    const r = rosterFor(
      DAY,
      PEOPLE,
      [log('Amjad Pr'), log('Jaimon D', { punchOut: undefined, status: 'Punched In' })],
      [leave('Prashanth')],
    );
    const c = rosterCounts(r);
    expect(c).toMatchObject({ present: 1, on_floor: 1, on_leave: 1, absent: 0 });
  });
});

describe('what HR has to chase', () => {
  it('groups unapproved absence with undecided leave', () => {
    const pending = leave('Jaimon D', {
      status: 'Pending Approval',
      managerApproved: false,
      hrApproved: false,
    });
    const r = rosterFor(DAY, PEOPLE, [log('Amjad Pr')], [pending]);
    expect(unexplained(r).map((x) => x.person.id).sort()).toEqual(['Jaimon D', 'Prashanth']);
  });
});

describe('the roster covers everyone active', () => {
  it('lists every active person exactly once, sorted by name', () => {
    const r = rosterFor(DAY, PEOPLE, [], []);
    expect(r.map((x) => x.person.id)).toEqual(['Amjad Pr', 'Jaimon D', 'Prashanth']);
  });

  it('leaves out disabled people and group nodes', () => {
    const extra = [
      ...PEOPLE,
      { ...person('Gone'), enabled: false },
      { ...person('Team Node'), isGroup: true },
    ];
    expect(rosterFor(DAY, extra, [], []).map((x) => x.person.id)).toEqual([
      'Amjad Pr',
      'Jaimon D',
      'Prashanth',
    ]);
  });

  it('ignores logs and leave from other days', () => {
    const r = rosterFor(DAY, PEOPLE, [log('Amjad Pr', { date: '2026-08-12' })], [
      leave('Jaimon D', { date: '2026-08-12' }),
    ]);
    expect(rosterCounts(r).absent).toBe(3);
  });
});
