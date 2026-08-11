/**
 * HR rules.
 *
 * The same shape as `orderRules` and `aging`: plain functions over plain data,
 * no React and no Redux, so "who is on the floor today" and "does this leave
 * clash" can be reasoned about — and tested — without rendering anything.
 *
 * Two decisions worth knowing about:
 *  - Sunday is the weekly off, so it never counts as a leave day and never
 *    counts against attendance.
 *  - A day with no attendance row is *unmarked*, not absent. Treating a missing
 *    row as an absence would quietly mark the whole company absent at 9am.
 */

import type {
  AttendanceRecord,
  AttendanceStatus,
  Department,
  Employee,
  LeaveRequest,
} from './types';
import { toIsoDate } from './orderRules';

// ------------------------------------------------------------- employees ---

/** Employed on `onIso` — joined on or before it, and not yet relieved. */
export function isActiveOn(employee: Employee, onIso: string): boolean {
  if (employee.joinedOn > onIso) return false;
  return !employee.leftOn || employee.leftOn > onIso;
}

export function activeEmployees(employees: Employee[], onIso: string): Employee[] {
  return employees.filter((e) => isActiveOn(e, onIso));
}

export interface DepartmentCount {
  department: Department;
  count: number;
}

/** Headcount per department, largest first. Empty departments are dropped. */
export function headcountByDepartment(employees: Employee[]): DepartmentCount[] {
  const counts = new Map<Department, number>();
  employees.forEach((e) => counts.set(e.department, (counts.get(e.department) ?? 0) + 1));
  return [...counts.entries()]
    .map(([department, count]) => ({ department, count }))
    .sort((a, b) => b.count - a.count);
}

/** Whole years served, as of `todayIso`. */
export function tenureYears(employee: Employee, todayIso: string): number {
  const end = employee.leftOn && employee.leftOn < todayIso ? employee.leftOn : todayIso;
  return Math.max(0, Math.floor(daysBetween(employee.joinedOn, end) / 365));
}

/**
 * Joined within the last `days` — the "still settling in" list. A future
 * joining date is someone who has not started yet, not a new joiner.
 */
export function newJoiners(employees: Employee[], todayIso: string, days = 90): Employee[] {
  return employees
    .filter((e) => {
      if (e.leftOn) return false;
      const since = daysBetween(e.joinedOn, todayIso);
      return since >= 0 && since <= days;
    })
    .sort((a, b) => b.joinedOn.localeCompare(a.joinedOn));
}

export interface Anniversary {
  employee: Employee;
  /** Years completed on this anniversary. */
  years: number;
  /** ISO date it falls on. */
  on: string;
  /** Days from today; 0 is today. */
  inDays: number;
}

/**
 * Work anniversaries falling within the next `withinDays`. Day-and-month
 * comparison only, and it rolls into next year near the end of December so the
 * list does not go empty every Christmas.
 */
export function upcomingAnniversaries(
  employees: Employee[],
  todayIso: string,
  withinDays = 30,
): Anniversary[] {
  const year = Number(todayIso.slice(0, 4));

  return employees
    .filter((e) => !e.leftOn)
    .map((e) => {
      const md = e.joinedOn.slice(5);
      // 29 Feb in a non-leap year lands on 1 Mar via the Date rollover.
      let on = `${year}-${md}`;
      if (on < todayIso) on = `${year + 1}-${md}`;
      const inDays = daysBetween(todayIso, on);
      return { employee: e, years: Number(on.slice(0, 4)) - Number(e.joinedOn.slice(0, 4)), on, inDays };
    })
    .filter((a) => a.years > 0 && a.inDays >= 0 && a.inDays <= withinDays)
    .sort((a, b) => a.inDays - b.inDays);
}

// ------------------------------------------------------------ attendance ---

/** Employee id → today's row, for O(1) lookups while rendering the roster. */
export function attendanceByEmployee(
  records: AttendanceRecord[],
  dateIso: string,
): Map<string, AttendanceRecord> {
  return new Map(records.filter((r) => r.date === dateIso).map((r) => [r.employeeId, r]));
}

export interface AttendanceSummary {
  date: string;
  /** Active headcount on this date — the denominator. */
  total: number;
  present: number;
  halfDay: number;
  absent: number;
  onLeave: number;
  /** Active employees with no row yet. Not absent — just not marked. */
  unmarked: number;
  /** 0–1. Half days count as half. Excluded: unmarked, holidays. */
  rate: number;
}

export function summariseAttendance(
  employees: Employee[],
  records: AttendanceRecord[],
  dateIso: string,
): AttendanceSummary {
  const active = activeEmployees(employees, dateIso);
  const byEmployee = attendanceByEmployee(records, dateIso);

  const tally: Record<AttendanceStatus, number> = {
    present: 0,
    absent: 0,
    on_leave: 0,
    half_day: 0,
    holiday: 0,
  };
  let unmarked = 0;

  active.forEach((e) => {
    const row = byEmployee.get(e.id);
    if (!row) unmarked += 1;
    else tally[row.status] += 1;
  });

  const counted = tally.present + tally.half_day + tally.absent + tally.on_leave;

  return {
    date: dateIso,
    total: active.length,
    present: tally.present,
    halfDay: tally.half_day,
    absent: tally.absent,
    onLeave: tally.on_leave,
    unmarked,
    rate: counted === 0 ? 0 : (tally.present + tally.half_day * 0.5) / counted,
  };
}

/** Attendance rate per day over the last `days`, oldest first — the trend bar. */
export function attendanceTrend(
  employees: Employee[],
  records: AttendanceRecord[],
  todayIso: string,
  days = 7,
): AttendanceSummary[] {
  const out: AttendanceSummary[] = [];
  for (let i = days - 1; i >= 0; i -= 1) {
    out.push(summariseAttendance(employees, records, shiftDays(todayIso, -i)));
  }
  return out;
}

/** Who is not on the floor today, and why. Drives the dashboard's absence list. */
export function absentToday(
  employees: Employee[],
  records: AttendanceRecord[],
  dateIso: string,
): Array<{ employee: Employee; record: AttendanceRecord }> {
  const byEmployee = attendanceByEmployee(records, dateIso);
  return activeEmployees(employees, dateIso)
    .map((employee) => ({ employee, record: byEmployee.get(employee.id) }))
    .filter(
      (r): r is { employee: Employee; record: AttendanceRecord } =>
        r.record != null && (r.record.status === 'absent' || r.record.status === 'on_leave'),
    );
}

// ----------------------------------------------------------------- leave ---

export function pendingLeave(requests: LeaveRequest[]): LeaveRequest[] {
  return requests
    .filter((r) => r.status === 'pending')
    .sort((a, b) => a.fromDate.localeCompare(b.fromDate));
}

/** Approved leave covering `dateIso`. */
export function onLeaveOn(requests: LeaveRequest[], dateIso: string): LeaveRequest[] {
  return requests.filter(
    (r) => r.status === 'approved' && r.fromDate <= dateIso && r.toDate >= dateIso,
  );
}

/**
 * Other requests from the same department whose dates overlap this one.
 *
 * Approving two of the three people who run a process for the same week is the
 * mistake worth catching *before* the decision, so this is surfaced next to the
 * approve button rather than reported afterwards.
 */
export function clashingRequests(request: LeaveRequest, all: LeaveRequest[]): LeaveRequest[] {
  return all.filter(
    (r) =>
      r.id !== request.id &&
      r.department === request.department &&
      (r.status === 'approved' || r.status === 'pending') &&
      r.fromDate <= request.toDate &&
      r.toDate >= request.fromDate,
  );
}

/** Working days in an inclusive date range, Sundays excluded. */
export function workingDaysBetween(fromIso: string, toIso: string): number {
  if (toIso < fromIso) return 0;
  let days = 0;
  for (let cursor = fromIso; cursor <= toIso; cursor = shiftDays(cursor, 1)) {
    if (!isWeeklyOff(cursor)) days += 1;
  }
  return days;
}

/**
 * Whether a request can be granted out of the employee's paid balance. Unpaid
 * leave always can be — that is the point of it.
 */
export function withinBalance(request: LeaveRequest, employee: Employee | undefined): boolean {
  if (request.type === 'unpaid') return true;
  if (!employee) return false;
  return request.days <= employee.leaveBalance;
}

// ----------------------------------------------------------------- dates ---

/** Sunday is the weekly off. */
export function isWeeklyOff(iso: string): boolean {
  return parseIso(iso).getDay() === 0;
}

export function shiftDays(iso: string, by: number): string {
  const d = parseIso(iso);
  d.setDate(d.getDate() + by);
  return toIsoDate(d);
}

export function daysBetween(fromIso: string, toIso: string): number {
  const ms = parseIso(toIso).getTime() - parseIso(fromIso).getTime();
  return Math.round(ms / 86_400_000);
}

/** Parsed as local midnight — `new Date('2026-08-04')` would be UTC. */
function parseIso(iso: string): Date {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y ?? 1970, (m ?? 1) - 1, d ?? 1);
}
