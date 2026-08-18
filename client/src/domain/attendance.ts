/**
 * Field-force attendance — the real HR model on this ERPNext site.
 *
 * This is deliberately *not* a classic HR module. Verified against the live
 * site on 7 Aug 2026:
 *
 *   - People are `Sales Person` records. `Employee` holds one disabled test row
 *     and is not used. Frappe HR (`hrms`) is not installed at all, so the
 *     doctypes `Attendance` and `Leave Application` do not exist.
 *   - Nobody marks anybody present. Reps punch themselves in and out from the
 *     field-sales app, with GPS, into `Attendance Log`.
 *   - A missed punch is corrected by an `Attendance Regularization`, which is a
 *     separate document — approving it does NOT change the attendance log.
 *
 * Everything here is pure: no React, no Redux, no Axios.
 */

import type { AttendanceLog, FieldLeaveRequest, SalesPerson } from './types';
import { isGranted } from './approvals';
import { isWeeklyOff } from './hrRules';

// ---------------------------------------------------------------- people ---

/**
 * Who actually counts as staff.
 *
 * `Sales Team` is a group node in the Sales Person tree, not a person, and
 * disabled rows are ex-staff. Both would otherwise inflate every headcount and
 * every turnout percentage.
 */
export function activeSalesPeople(people: SalesPerson[]): SalesPerson[] {
  return people.filter((p) => p.enabled && !p.isGroup);
}

export interface Team {
  /** The manager's name, as held in `custom_team_manager`. */
  manager: string;
  /** Business unit — `custom_company`, e.g. "Manna Treads". */
  unit: string;
  members: SalesPerson[];
}

export function teamsOf(people: SalesPerson[]): Team[] {
  const byManager = new Map<string, Team>();
  for (const p of activeSalesPeople(people)) {
    const key = p.teamManager || '—';
    let team = byManager.get(key);
    if (!team) {
      team = { manager: key, unit: p.unit || '—', members: [] };
      byManager.set(key, team);
    }
    team.members.push(p);
  }
  return [...byManager.values()].sort((a, b) => a.manager.localeCompare(b.manager));
}

// ------------------------------------------------------------ attendance ---

/** What a single day looks like for one person. */
export type DayState =
  /** Punched in and out — the only state that yields measured hours. */
  | 'worked'
  /** Punched in, never punched out. No hours can be trusted. */
  | 'open'
  /** Approved leave, full day. */
  | 'leave'
  /** Approved leave, half day. */
  | 'half'
  /** Neither a punch nor approved leave. */
  | 'none'
  /** Later than today — not yet knowable. */
  | 'future';

export interface Day {
  iso: string;
  state: DayState;
  /** Measured hours. Only ever non-zero for `worked`. */
  hours: number;
  log?: AttendanceLog;
  leave?: FieldLeaveRequest;
}

export function isOpenShift(log: AttendanceLog): boolean {
  return log.status === 'Punched In';
}

/**
 * Shifts left open on a day that has already ended.
 *
 * Today's punch-ins are excluded: someone still on the floor has not missed
 * anything yet. Bounded by `withinDays` because this is a working queue, not a
 * historical record — the calendar is where history lives.
 */
export function openShifts(
  logs: AttendanceLog[],
  today: string,
  withinDays = 21,
): AttendanceLog[] {
  const from = shiftIso(today, -withinDays);
  return logs
    .filter((l) => isOpenShift(l) && l.date < today && l.date >= from)
    .sort((a, b) => b.date.localeCompare(a.date));
}

// -------------------------------------------------------------- calendar ---

// ------------------------------------------------------- the day's roster ---

/**
 * Where one person stood on one day.
 *
 * `absent` is deliberately the last resort. Calling somebody absent is a
 * payroll consequence and, on a bad day, an accusation — so every innocent
 * explanation is checked first: they worked, they are still out, their leave
 * was granted, they asked for leave, or nobody works Sundays.
 */
export type DayStatus =
  | 'present'
  | 'on_floor'
  | 'on_leave'
  | 'leave_pending'
  | 'weekly_off'
  | 'absent';

export interface RosterEntry {
  person: SalesPerson;
  status: DayStatus;
  log?: AttendanceLog;
  leave?: FieldLeaveRequest;
  /** True when the leave covering this day is a half day. */
  halfDay: boolean;
}

export const DAY_STATUS_LABEL: Record<DayStatus, string> = {
  present: 'Present',
  on_floor: 'Still out',
  on_leave: 'On leave',
  leave_pending: 'Leave not yet granted',
  weekly_off: 'Weekly off',
  absent: 'Absent',
};

/**
 * Everyone, and where they stood on `date`.
 *
 * The order of the checks is the whole design:
 *
 *   1. **A punch beats everything.** Somebody who turned up worked, whatever
 *      leave record exists — a rep who cancelled their leave and came in must
 *      not be marked absent because the request was never withdrawn.
 *   2. **Both punches, or they are still out.** A day counts as worked only
 *      with a punch in *and* out; an open shift is not a complete day and is
 *      not payroll-ready.
 *   3. **Granted leave, then requested leave.** These are different facts. A
 *      request nobody has decided is not time off, and treating it as such
 *      would let unapproved absence disappear into the leave column.
 *   4. **Sunday is nobody's absence.**
 *
 * Only what survives all four is absent.
 */
export function rosterFor(
  date: string,
  people: SalesPerson[],
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
): RosterEntry[] {
  const logByPerson = new Map<string, AttendanceLog>();
  for (const l of logs) {
    if (l.date !== date) continue;
    // Keep the earliest punch-in if a person somehow has two logs for a day.
    const prev = logByPerson.get(l.person);
    if (!prev || (l.punchIn ?? '') < (prev.punchIn ?? '')) logByPerson.set(l.person, l);
  }

  const leaveByPerson = new Map<string, FieldLeaveRequest>();
  for (const l of leave) {
    if (l.date !== date) continue;
    const prev = leaveByPerson.get(l.person);
    // A granted request outranks a pending one for the same day.
    if (!prev || (isGranted(l) && !isGranted(prev))) leaveByPerson.set(l.person, l);
  }

  const off = isWeeklyOff(date);

  return activeSalesPeople(people)
    .map<RosterEntry>((person) => {
      const log = logByPerson.get(person.id);
      const lv = leaveByPerson.get(person.id);
      const halfDay = Boolean(lv?.halfDay);

      if (log) {
        const worked = Boolean(log.punchIn && log.punchOut);
        return {
          person,
          log,
          leave: lv,
          halfDay,
          status: worked ? 'present' : 'on_floor',
        };
      }
      if (lv && isGranted(lv)) return { person, leave: lv, halfDay, status: 'on_leave' };
      /*
       * A rejected request is decided, and the answer was no — so it explains
       * nothing and must not sit in the pending column. The request is still
       * attached, because "asked, was refused, did not come in" is exactly the
       * context HR wants when they open the row.
       */
      if (lv && lv.status !== 'Rejected') {
        return { person, leave: lv, halfDay, status: 'leave_pending' };
      }
      if (off) return { person, leave: lv, halfDay: false, status: 'weekly_off' };
      return { person, leave: lv, halfDay: false, status: 'absent' };
    })
    .sort((a, b) => a.person.name.localeCompare(b.person.name));
}

/** How many people stand in each state. */
export function rosterCounts(roster: RosterEntry[]): Record<DayStatus, number> {
  const counts: Record<DayStatus, number> = {
    present: 0,
    on_floor: 0,
    on_leave: 0,
    leave_pending: 0,
    weekly_off: 0,
    absent: 0,
  };
  for (const r of roster) counts[r.status] += 1;
  return counts;
}

/**
 * Everyone who owes an explanation for the day.
 *
 * Unapproved absence and undecided leave, together — both are somebody not at
 * work without a decision behind it, which is the thing HR chases.
 */
export function unexplained(roster: RosterEntry[]): RosterEntry[] {
  return roster.filter((r) => r.status === 'absent' || r.status === 'leave_pending');
}

export interface PersonMonth {
  person: SalesPerson;
  days: Day[];
  /** Days with both punches. */
  worked: number;
  /** Sum of measured hours across `worked` days. */
  hours: number;
  /** Approved leave in days — half days count 0.5. */
  leaveDays: number;
  /** Days punched in but never out. */
  open: number;
  /** Working-past days with no punch and no approved leave. */
  unaccounted: number;
}

/**
 * One month, one row per person — what payroll is computed from.
 *
 * **A day only counts as worked when both punches exist.** An open shift has no
 * measured end, so counting it would pay someone on the strength of a missing
 * punch. Those days are reported separately in `open` and contribute nothing to
 * `hours`, which is what makes `payrollReady` meaningful.
 */
/**
 * One person's attendance across an arbitrary date range.
 *
 * `monthFor` is this with the range set to a calendar month. HR asked to be
 * able to pull a custom period — a pay cycle that runs mid-month to mid-month,
 * or the fortnight somebody queried — and a month was the only shape available.
 *
 * The rules are unchanged and deliberately live in one place: a day counts as
 * worked only with BOTH punches, an open shift yields no hours, approved leave
 * explains a day, and anything else is unaccounted. Two copies of that would
 * eventually pay two different figures for the same fortnight.
 */
export function periodFor(
  person: SalesPerson,
  fromIso: string,
  toIso: string,
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
  today: string,
): PersonMonth {
  const logByDate = new Map(logs.filter((l) => l.person === person.id).map((l) => [l.date, l]));
  const leaveByDate = new Map(
    leave.filter((l) => l.person === person.id && l.status === 'Approved').map((l) => [l.date, l]),
  );

  const days: Day[] = [];
  let worked = 0;
  let hours = 0;
  let leaveDays = 0;
  let open = 0;
  let unaccounted = 0;

  // A reversed range yields nothing rather than looping forever.
  for (let iso = fromIso; iso <= toIso; iso = shiftIso(iso, 1)) {
    const log = logByDate.get(iso);
    const lv = leaveByDate.get(iso);

    if (iso > today) {
      days.push({ iso, state: 'future', hours: 0 });
      continue;
    }
    if (log && log.status === 'Punched Out') {
      const h = Number.isFinite(log.workingHours) ? log.workingHours : 0;
      worked++;
      hours += h;
      days.push({ iso, state: 'worked', hours: h, log });
      continue;
    }
    if (log && log.status === 'Punched In') {
      open++;
      days.push({ iso, state: 'open', hours: 0, log });
      continue;
    }
    if (lv) {
      const half = lv.days === 0.5;
      leaveDays += lv.days || 1;
      days.push({ iso, state: half ? 'half' : 'leave', hours: 0, leave: lv });
      continue;
    }
    unaccounted++;
    days.push({ iso, state: 'none', hours: 0 });
  }

  return { person, days, worked, hours: round1(hours), leaveDays, open, unaccounted };
}

/** A calendar month, which is `periodFor` over the month's own bounds. */
export function monthFor(
  person: SalesPerson,
  year: number,
  month: number, // 0-based
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
  today: string,
): PersonMonth {
  const last = new Date(year, month + 1, 0).getDate();
  return periodFor(person, isoOf(year, month, 1), isoOf(year, month, last), logs, leave, today);
}

export function buildMonth(
  people: SalesPerson[],
  year: number,
  month: number,
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
  today: string,
): PersonMonth[] {
  return activeSalesPeople(people).map((p) => monthFor(p, year, month, logs, leave, today));
}

/**
 * A month can be signed off only when nothing is still open.
 *
 * An open shift means somebody's hours are unknown, so paying from this month
 * would be guesswork. Regularize them first.
 */
export function payrollReady(rows: PersonMonth[]): boolean {
  return rows.every((r) => r.open === 0);
}

export function totalOpen(rows: PersonMonth[]): number {
  return rows.reduce((sum, r) => sum + r.open, 0);
}

// ----------------------------------------------------------------- leave ---

/**
 * Two leave requests for the same person on the same date.
 *
 * Duplicates happen when a rep re-submits rather than waiting, and approving
 * both would deduct the day twice.
 */
export function duplicateLeaveKeys(leave: FieldLeaveRequest[]): Set<string> {
  const seen = new Map<string, number>();
  for (const l of leave) {
    const key = `${l.person}|${l.date}`;
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  return new Set([...seen.entries()].filter(([, n]) => n > 1).map(([k]) => k));
}

export function leaveKey(l: FieldLeaveRequest): string {
  return `${l.person}|${l.date}`;
}

// ----------------------------------------------------------------- dates ---

export function isoOf(year: number, month: number, day: number): string {
  const m = `${month + 1}`.padStart(2, '0');
  const d = `${day}`.padStart(2, '0');
  return `${year}-${m}-${d}`;
}

/** Local-time today. `toISOString` is UTC and reads as yesterday all evening. */
export function todayLocalIso(now: Date = new Date()): string {
  return isoOf(now.getFullYear(), now.getMonth(), now.getDate());
}

export function shiftIso(iso: string, days: number): string {
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(y ?? 1970, (m ?? 1) - 1, (d ?? 1) + days);
  return isoOf(dt.getFullYear(), dt.getMonth(), dt.getDate());
}

/** "2026-08-06 09:26:49" → "09:26". Frappe sends a space-separated stamp. */
export function clockOf(stamp?: string): string {
  if (!stamp) return '—';
  const m = /(\d{2}):(\d{2})/.exec(stamp.slice(10));
  return m ? `${m[1]}:${m[2]}` : '—';
}

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}
