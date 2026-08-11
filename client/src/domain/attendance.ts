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
export function monthFor(
  person: SalesPerson,
  year: number,
  month: number, // 0-based
  logs: AttendanceLog[],
  leave: FieldLeaveRequest[],
  today: string,
): PersonMonth {
  const logByDate = new Map(logs.filter((l) => l.person === person.id).map((l) => [l.date, l]));
  const leaveByDate = new Map(
    leave.filter((l) => l.person === person.id && l.status === 'Approved').map((l) => [l.date, l]),
  );

  const total = new Date(year, month + 1, 0).getDate();
  const days: Day[] = [];
  let worked = 0;
  let hours = 0;
  let leaveDays = 0;
  let open = 0;
  let unaccounted = 0;

  for (let d = 1; d <= total; d++) {
    const iso = isoOf(year, month, d);
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

  return {
    person,
    days,
    worked,
    hours: round1(hours),
    leaveDays,
    open,
    unaccounted,
  };
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
