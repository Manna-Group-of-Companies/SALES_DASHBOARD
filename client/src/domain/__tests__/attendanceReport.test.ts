/**
 * The attendance calendar as a sheet HR reconciles salary against.
 *
 * The rules that matter are all about not letting the file say something the
 * data does not: a blank day and a zero-hour day are different, an approved
 * regularisation that was never written back is different from one that was,
 * and a rejected request is not a correction at all.
 */

import { describe, expect, it } from 'vitest';
import type {
  AttendanceLog,
  AttendanceRegularization,
  FieldLeaveRequest,
  SalesPerson,
} from '../types';
import { attendanceReport, personRows, reportFilename, summarise } from '../attendanceReport';
import { monthFor } from '../attendance';

const AMJAD: SalesPerson = {
  id: 'Amjad Pr',
  name: 'Amjad Pr',
  teamManager: 'Pareeth',
  unit: 'Manna Treads',
  enabled: true,
  isGroup: false,
};
const JAIMON: SalesPerson = { ...AMJAD, id: 'Jaimon D', name: 'Jaimon D' };

const log = (person: string, date: string, inAt?: string, outAt?: string): AttendanceLog => ({
  id: `${person}-${date}`,
  person,
  date,
  punchIn: inAt ? `${date} ${inAt}:00` : undefined,
  punchOut: outAt ? `${date} ${outAt}:00` : undefined,
  status: outAt ? 'Punched Out' : 'Punched In',
  workingHours: inAt && outAt ? 8 : 0,
});

const reg = (
  person: string,
  date: string,
  status: AttendanceRegularization['status'],
  completion: AttendanceRegularization['completionStatus'] = 'Completed',
): AttendanceRegularization => ({
  id: `AR-${person}-${date}`,
  person,
  date,
  status,
  completionStatus: completion,
  approverType: 'Sales Manager',
  requesterIsManager: false,
  reason: 'Phone was dead',
});

/** August 2026, viewed from the 20th so the month is part past, part future. */
const Y = 2026;
const M = 7; // 0-based
const TODAY = '2026-08-20';

const rowsFor = (logs: AttendanceLog[], regs: AttendanceRegularization[] = []) =>
  personRows(monthFor(AMJAD, Y, M, logs, [], TODAY), AMJAD, regs);

describe('every day of the month gets a row', () => {
  it('includes the days nobody punched', () => {
    // A sheet listing only days with a punch makes an absence look identical
    // to a day nobody exported, and those have opposite payroll consequences.
    const rows = rowsFor([]);
    expect(rows).toHaveLength(31);
    expect(rows[0].Date).toBe('2026-08-01');
    expect(rows[30].Date).toBe('2026-08-31');
  });

  it('names the person and their team on every row, so the sheet can be filtered', () => {
    const rows = rowsFor([]);
    expect(rows.every((r) => r.Representative === 'Amjad Pr')).toBe(true);
    expect(rows.every((r) => r.Team === 'Pareeth')).toBe(true);
  });

  it('carries the weekday, read as a local date', () => {
    // `new Date('2026-08-01')` is parsed as UTC and lands on the previous day
    // in India — which would put every weekday in the sheet one out.
    const rows = rowsFor([]);
    expect(rows[0]).toMatchObject({ Date: '2026-08-01', Weekday: 'Saturday' });
  });
});

describe('the hours column', () => {
  it('is blank on a day nobody worked, never zero', () => {
    // A zero reads as a measured nothing; an empty cell reads as nothing to
    // measure. Only one of those is true of a Sunday.
    const rows = rowsFor([]);
    const sunday = rows.find((r) => r.Weekday === 'Sunday')!;
    expect(sunday.Hours).toBe('');
  });

  it('carries measured hours on a completed shift', () => {
    const rows = rowsFor([log('Amjad Pr', '2026-08-03', '09:00', '17:30')]);
    const d = rows.find((r) => r.Date === '2026-08-03')!;
    expect(d.Status).toBe('Present');
    expect(d['Punch in']).toBe('09:00');
    expect(d['Punch out']).toBe('17:30');
    expect(Number(d.Hours)).toBeGreaterThan(0);
  });

  it('gives an open shift no hours, and says why', () => {
    // Punched in, never out: no measured end, so counting it would pay
    // somebody on the strength of a missing punch.
    const rows = rowsFor([log('Amjad Pr', '2026-08-04', '09:00')]);
    const d = rows.find((r) => r.Date === '2026-08-04')!;
    expect(d.Hours).toBe('');
    expect(d['Punch out']).toBe('—');
    expect(d.Status).toContain('no punch out');
  });
});

describe('regularisation', () => {
  it('marks a day an approved regularisation covers', () => {
    const rows = rowsFor(
      [log('Amjad Pr', '2026-08-05', '09:00', '17:00')],
      [reg('Amjad Pr', '2026-08-05', 'Approved')],
    );
    const d = rows.find((r) => r.Date === '2026-08-05')!;
    expect(d.Regularised).toBe('Yes');
    expect(d['Regularisation status']).toBe('Completed');
  });

  it('reports an approval that was never written back', () => {
    /*
     * The gap this whole module exists to close: a regularisation can be
     * Approved and still Not Completed — signed off, but nobody rewrote the
     * log, so the hours never moved. Payroll has to see both facts.
     */
    const rows = rowsFor(
      [log('Amjad Pr', '2026-08-06', '09:00')],
      [reg('Amjad Pr', '2026-08-06', 'Approved', 'Not Completed')],
    );
    const d = rows.find((r) => r.Date === '2026-08-06')!;
    expect(d.Regularised).toBe('Yes');
    expect(d['Regularisation status']).toBe('Not Completed');
    // And the hours are still not there, which is the point.
    expect(d.Hours).toBe('');
  });

  it('does not call a rejected or pending request a regularisation', () => {
    // Somebody asking is not a correction. Marking the day regularised on the
    // strength of a request would overstate what happened to it.
    for (const status of ['Rejected', 'Pending Approval'] as const) {
      const rows = rowsFor([], [reg('Amjad Pr', '2026-08-07', status)]);
      const d = rows.find((r) => r.Date === '2026-08-07')!;
      expect(d.Regularised, status).toBe('No');
      expect(d['Regularisation status'], status).toBe('');
    }
  });

  it('does not attribute one person’s regularisation to another', () => {
    const rows = rowsFor([], [reg('Jaimon D', '2026-08-08', 'Approved')]);
    expect(rows.find((r) => r.Date === '2026-08-08')!.Regularised).toBe('No');
  });
});

describe('everybody in one sheet', () => {
  const people = [JAIMON, AMJAD]; // deliberately out of order
  const logs = [log('Amjad Pr', '2026-08-03', '09:00', '17:00')];

  it('sorts by person, so a reader can scan one name at a time', () => {
    const rows = attendanceReport({
      people,
      year: Y,
      month: M,
      logs,
      leave: [] as FieldLeaveRequest[],
      regularizations: [],
      today: TODAY,
    });
    expect(rows).toHaveLength(62);
    expect(rows[0].Representative).toBe('Amjad Pr');
    expect(rows[31].Representative).toBe('Jaimon D');
  });

  it('does not leak one person’s punches onto another', () => {
    const rows = attendanceReport({
      people,
      year: Y,
      month: M,
      logs,
      leave: [],
      regularizations: [],
      today: TODAY,
    });
    const jaimon = rows.find((r) => r.Representative === 'Jaimon D' && r.Date === '2026-08-03')!;
    expect(jaimon['Punch in']).toBe('—');
  });
});

describe('the summary shown when everybody is selected', () => {
  it('counts each state once, and the regularised days', () => {
    const s = summarise(
      [AMJAD],
      Y,
      M,
      [log('Amjad Pr', '2026-08-03', '09:00', '17:00'), log('Amjad Pr', '2026-08-04', '09:00')],
      [],
      [reg('Amjad Pr', '2026-08-04', 'Approved')],
      TODAY,
    )[0];
    expect(s.worked).toBe(1);
    expect(s.open).toBe(1);
    expect(s.regularised).toBe(1);
    expect(s.hours).toBeGreaterThan(0);
  });
});

describe('the file name', () => {
  it('says the month and who it is for', () => {
    expect(reportFilename(2026, 7, 'Amjad Pr')).toBe('attendance-2026-08-Amjad-Pr.xlsx');
    expect(reportFilename(2026, 7)).toBe('attendance-2026-08-all-representatives.xlsx');
  });
});
