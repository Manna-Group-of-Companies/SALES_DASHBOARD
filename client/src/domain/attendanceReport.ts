/**
 * The attendance calendar as a downloadable sheet.
 *
 * HR reconciles salary against this, so the sheet has to answer the questions
 * a payroll query actually raises — not just "how many days", but *which* day,
 * what the clock said, and whether somebody changed it afterwards.
 *
 * **Every day of the month gets a row, including the empty ones.** A sheet that
 * only listed days with a punch would make an absence indistinguishable from a
 * day nobody exported, and those have opposite payroll consequences.
 *
 * **A regularised day is marked as such.** A punch pair that a manager wrote in
 * after the fact is not the same evidence as one the phone recorded, and the
 * person checking the sheet is entitled to know which they are looking at. The
 * completion status comes with it, because on this site a regularisation can be
 * `Approved` and still `Not Completed` — approved but never actually written
 * back into the log, so the hours never moved.
 */

import type {
  AttendanceLog,
  AttendanceRegularization,
  FieldLeaveRequest,
  SalesPerson,
} from './types';
import { clockOf, periodFor, type Day, type PersonMonth } from './attendance';

/**
 * One row of the sheet. Keys are the column headers, in the order they appear.
 *
 * The index signature is what lets this satisfy the exporter's `SheetRow`
 * without a cast — the named fields still hold, so a typo in a header is
 * still caught.
 */
export interface AttendanceReportRow {
  [column: string]: string | number | null | undefined;
  Representative: string;
  Team: string;
  Date: string;
  Weekday: string;
  Status: string;
  'Punch in': string;
  'Punch out': string;
  Hours: number | '';
  Regularised: string;
  'Regularisation status': string;
  Notes: string;
}

const WEEKDAY = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** Read as a local date — `new Date('2026-08-17')` is UTC and shifts the day. */
function weekdayOf(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  if (!y || !m || !d) return '';
  return WEEKDAY[new Date(y, m - 1, d).getDay()] ?? '';
}

/**
 * What the day is called in the sheet.
 *
 * Deliberately plain English rather than the internal state name: this file is
 * opened by whoever runs payroll, not by whoever wrote the calendar.
 */
export function statusLabel(day: Day): string {
  switch (day.state) {
    case 'worked':
      return 'Present';
    case 'open':
      return 'Open shift — no punch out';
    case 'leave':
      return 'On leave';
    case 'half':
      return 'On leave — half day';
    /*
     * "Unaccounted", not "Absent". The calendar uses that word deliberately:
     * no punch and no approved leave is a gap in the record, and the person
     * reading this sheet is the one who decides what it means. A column that
     * called it absent would have made that decision for them.
     */
    case 'none':
      return 'Unaccounted — no punch, no leave';
    // Later than today. Nothing is knowable yet, so the row stays blank
    // rather than claiming somebody failed to turn up tomorrow.
    case 'future':
      return '';
    default:
      return day.state;
  }
}

/**
 * The regularisations that apply to a day, newest decision first.
 *
 * Only `Approved` ones count as having changed anything. A rejected or pending
 * request is somebody asking, not a correction — marking the day "regularised"
 * on the strength of one would overstate what happened to it.
 */
function approvedOn(
  regs: AttendanceRegularization[],
  person: string,
  iso: string,
): AttendanceRegularization | undefined {
  return regs.find((r) => r.person === person && r.date === iso && r.status === 'Approved');
}

/** One person's month, a row per day. */
export function personRows(
  month: PersonMonth,
  person: SalesPerson,
  regs: AttendanceRegularization[],
): AttendanceReportRow[] {
  return month.days.map((day) => {
    const reg = approvedOn(regs, person.id, day.iso);
    const notes: string[] = [];
    if (day.leave?.reason) notes.push(day.leave.reason);
    if (reg?.reason) notes.push(`Regularisation: ${reg.reason}`);

    return {
      Representative: person.name,
      Team: person.teamManager || '',
      Date: day.iso,
      Weekday: weekdayOf(day.iso),
      Status: statusLabel(day),
      'Punch in': clockOf(day.log?.punchIn),
      'Punch out': clockOf(day.log?.punchOut),
      // Blank, not 0, on a day nobody worked. A zero in an hours column reads
      // as a measured nothing; an empty cell reads as nothing to measure, and
      // only one of those is true of a Sunday.
      Hours: day.state === 'worked' ? day.hours : '',
      Regularised: reg ? 'Yes' : 'No',
      /*
       * Carried because on this site a regularisation can be Approved and
       * still Not Completed — signed off but never written back into the log,
       * so the hours never moved. Whoever runs payroll needs to see that the
       * approval exists and the correction did not land.
       */
      'Regularisation status': reg ? reg.completionStatus : '',
      Notes: notes.join(' · '),
    };
  });
}

/**
 * Every selected person's month, one sheet.
 *
 * Sorted by person then date so a reader can scan one name at a time; an
 * export of everyone is read person by person, not day by day.
 */
export function attendanceReport(input: {
  people: SalesPerson[];
  /** Inclusive ISO bounds. A month is just the month's own bounds. */
  from: string;
  to: string;
  logs: AttendanceLog[];
  leave: FieldLeaveRequest[];
  regularizations: AttendanceRegularization[];
  today: string;
}): AttendanceReportRow[] {
  const ordered = [...input.people].sort((a, b) => a.name.localeCompare(b.name));
  return ordered.flatMap((p) =>
    personRows(
      periodFor(p, input.from, input.to, input.logs, input.leave, input.today),
      p,
      input.regularizations,
    ),
  );
}

/**
 * `attendance-2026-08-01-to-2026-08-31-Amjad-Pr.xlsx`.
 *
 * The dates are in the name because these files are mailed around and end up
 * in somebody's downloads folder next to four others. A name that only said
 * the month would not distinguish a pay cycle from the calendar month it
 * overlaps.
 */
export function reportFilename(from: string, to: string, personName?: string): string {
  const who = personName ? personName.replace(/[^\w]+/g, '-') : 'all-representatives';
  return `attendance-${from}-to-${to}-${who}.xlsx`;
}

/** Shown on screen when everybody is selected, since a grid cannot be. */
export interface PersonSummary {
  person: SalesPerson;
  worked: number;
  hours: number;
  open: number;
  unaccounted: number;
  leave: number;
  regularised: number;
}

export function summarise(
  people: SalesPerson[],
  from: string,
  to: string,
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
  regs: AttendanceRegularization[],
  today: string,
): PersonSummary[] {
  return [...people]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((person) => {
      const m = periodFor(person, from, to, logs, leave, today);
      const count = (s: Day['state']) => m.days.filter((d) => d.state === s).length;
      return {
        person,
        worked: m.worked,
        hours: Math.round(m.hours * 10) / 10,
        open: m.open,
        // The calendar's own figure, so the summary and the grid cannot
        // disagree about how many days are unexplained.
        unaccounted: m.unaccounted,
        leave: count('leave') + count('half'),
        regularised: m.days.filter((d) => approvedOn(regs, person.id, d.iso)).length,
      };
    });
}
