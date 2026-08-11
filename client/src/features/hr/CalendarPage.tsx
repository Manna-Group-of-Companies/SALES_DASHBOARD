/**
 * The monthly attendance calendar — what HR computes salary from.
 *
 * One person at a time, laid out as an actual month so a pattern is visible at
 * a glance: which weeks are thin, whether absences cluster, whether Sundays are
 * being worked. Reads `Attendance Log` and `Leave Request`; the rules live in
 * `domain/attendance` and this file only renders them.
 *
 * The load-bearing rule, restated because it decides what people are paid:
 * **a day counts as worked only when it has both a punch-in and a punch-out.**
 * An open shift has no measured end, so counting it would pay someone on the
 * strength of a missing punch. Those days are red, excluded from the hours
 * total, and called out as blocking payroll.
 */

import { useEffect, useMemo, useRef, useState } from 'react';
import type { AttendanceLog, FieldLeaveRequest, SalesPerson } from '@/domain/types';
import {
  activeSalesPeople,
  clockOf,
  monthFor,
  shiftIso,
  todayLocalIso,
  type Day,
} from '@/domain/attendance';
import { Api, stampFor } from '@/api/client';
import { Alert, Button, Card, Empty, Field, Input, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/** Weeks run Monday-first, so Sunday — the usual off day — closes the row. */
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/** How far back the calendar can page — bounds the attendance read. */
const HISTORY_DAYS = 190;

export function CalendarPage() {
  const today = todayLocalIso();
  const now = new Date();

  const [cursor, setCursor] = useState({ y: now.getFullYear(), m: now.getMonth() });
  const [personId, setPersonId] = useState<string>('');
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [logs, setLogs] = useState<AttendanceLog[]>([]);
  const [leave, setLeave] = useState<FieldLeaveRequest[]>([]);
  /** Bumped to re-run the load effect — the Refresh button's only job. */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  /** The day HR is editing, if any. */
  const [editing, setEditing] = useState<Day | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.attendance.listSalesPeople(),
      Api.attendance.listAttendanceLogs(shiftIso(today, -HISTORY_DAYS)),
      Api.attendance.listLeaveRequests(),
    ])
      .then(([p, l, lv]) => {
        if (!live) return;
        setPeople(p);
        setLogs(l);
        setLeave(lv);
        // Land on somebody rather than an empty grid.
        const first = activeSalesPeople(p)[0];
        if (first) setPersonId((cur) => cur || first.id);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read attendance.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [today, tick]);

  const staff = useMemo(() => activeSalesPeople(people), [people]);
  const person = useMemo(() => staff.find((p) => p.id === personId), [staff, personId]);

  const month = useMemo(
    () => (person ? monthFor(person, cursor.y, cursor.m, logs, leave, today) : null),
    [person, cursor, logs, leave, today],
  );

  /**
   * Open shifts belonging to everyone else this month. Payroll is run for the
   * whole team, so a clean individual month is not the same as a payable one.
   */
  const otherOpen = useMemo(() => {
    if (!person) return 0;
    return staff
      .filter((p) => p.id !== person.id)
      .reduce((sum, p) => sum + monthFor(p, cursor.y, cursor.m, logs, leave, today).open, 0);
  }, [staff, person, cursor, logs, leave, today]);

  const shift = (delta: number) => {
    const d = new Date(cursor.y, cursor.m + delta, 1);
    setCursor({ y: d.getFullYear(), m: d.getMonth() });
  };

  // Blank cells so the 1st lands under its real weekday.
  const lead = (new Date(cursor.y, cursor.m, 1).getDay() + 6) % 7;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Monthly calendar</div>
          <div className="page-head__sub">One person, one month — the basis for payroll</div>
        </div>
      </div>

      <div className="cal__toolbar">
        <Select
          value={personId}
          onChange={(e) => setPersonId(e.target.value)}
          aria-label="Sales person"
        >
          {staff.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
              {p.teamManager ? ` — ${p.teamManager}` : ''}
            </option>
          ))}
        </Select>

        <div className="cal__nav">
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
          <Button size="sm" variant="ghost" onClick={() => shift(-1)} aria-label="Previous month">
            ‹
          </Button>
          <div className="cal__title">
            {MONTHS[cursor.m]} {cursor.y}
          </div>
          <Button size="sm" variant="ghost" onClick={() => shift(1)} aria-label="Next month">
            ›
          </Button>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read attendance">
          {error}
        </Alert>
      )}

      {loading && !error && <Empty icon="◔" title="Reading attendance…" />}

      {!loading && !error && !person && <Empty icon="—" title="No active sales people" />}

      {!loading && !error && person && month && (
        <>
          <div className="tiles" style={{ marginBottom: 14 }}>
            <Tile label="Days worked" value={String(month.worked)} tone="ok" foot="Both punches present" />
            <Tile label="Hours" value={String(month.hours)} foot="Measured, closed shifts only" />
            <Tile
              label="Leave"
              value={String(month.leaveDays)}
              foot="Approved, half days count 0.5"
            />
            <Tile
              label="Open shifts"
              value={String(month.open)}
              tone={month.open ? 'alert' : undefined}
              foot={month.open ? 'No hours counted' : 'None'}
            />
            <Tile
              label="No record"
              value={String(month.unaccounted)}
              tone={month.unaccounted ? 'warn' : undefined}
              foot="Neither punch nor leave"
            />
          </div>

          {month.open > 0 && (
            <div style={{ marginBottom: 14 }}>
              <Alert
                tone="warn"
                title={`${month.open} day${month.open === 1 ? '' : 's'} punched in but never out`}
              >
                Those days have no measured hours and are excluded from the total above. Clear them
                through a regularisation before running salary for {person.name}.
              </Alert>
            </div>
          )}

          {month.open === 0 && otherOpen > 0 && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="info" title={`${person.name} is clean, but the month is not`}>
                {otherOpen} open shift{otherOpen === 1 ? '' : 's'} remain across the rest of the
                team this month.
              </Alert>
            </div>
          )}

          {editing && (
            <DayEditor
              person={person}
              day={editing}
              onClose={() => setEditing(null)}
              onSaved={() => setTick((t) => t + 1)}
              onError={setError}
            />
          )}

          <Card flush>
            <div className="month">
              {WEEKDAYS.map((w) => (
                <div key={w} className={`month__dow ${w === 'Sun' ? 'is-off' : ''}`}>
                  {w}
                </div>
              ))}
              {Array.from({ length: lead }, (_, i) => (
                <div key={`lead-${i}`} className="month__cell is-blank" />
              ))}
              {month.days.map((d) => (
                <DayCell
                  key={d.iso}
                  day={d}
                  today={today}
                  onEdit={() => setEditing(d)}
                  active={editing?.iso === d.iso}
                />
              ))}
            </div>
          </Card>

          <div className="cal__legend">
            <LegendKey state="worked" label="Worked" />
            <LegendKey state="open" label="Punched in, never out" />
            <LegendKey state="leave" label="Approved leave" />
            <LegendKey state="half" label="Half day" />
            <LegendKey state="none" label="No record" />
          </div>
        </>
      )}
    </div>
  );
}

function DayCell({
  day,
  today,
  onEdit,
  active,
}: {
  day: Day;
  today: string;
  onEdit: () => void;
  active: boolean;
}) {
  const dayNo = Number(day.iso.slice(8, 10));
  const isToday = day.iso === today;

  // A future day has nothing to correct yet, so it is not clickable.
  if (day.state === 'future') {
    return (
      <div className={`month__cell s-future ${isToday ? 'is-today' : ''}`}>
        <div className="month__num">{dayNo}</div>
      </div>
    );
  }

  return (
    <button
      type="button"
      className={`month__cell s-${day.state} ${isToday ? 'is-today' : ''} ${active ? 'is-editing' : ''}`}
      onClick={onEdit}
      title="Edit this day's punch times"
    >
      <div className="month__num">{dayNo}</div>
      <div className="month__body">{detail(day)}</div>
    </button>
  );
}

/**
 * Correct one day's punch times.
 *
 * HR needs this because a rep cannot fix their own past attendance and a
 * regularization only covers days somebody thought to raise one for. The
 * change is written straight to `Attendance Log`, so it lands in the same
 * place a punch would and the calendar recomputes from it.
 */
function DayEditor({
  person,
  day,
  onClose,
  onSaved,
  onError,
}: {
  person: SalesPerson;
  day: Day;
  onClose: () => void;
  onSaved: () => void;
  onError: (m: string) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [inTime, setInTime] = useState(hhmmOf(day.log?.punchIn));
  const [outTime, setOutTime] = useState(hhmmOf(day.log?.punchOut));
  const [saving, setSaving] = useState(false);

  const hours =
    inTime && outTime
      ? Math.max(0, Math.round(((toMinutes(outTime) - toMinutes(inTime)) / 60) * 100) / 100)
      : 0;

  useEffect(() => {
    box.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [day.iso]);

  const save = async () => {
    setSaving(true);
    try {
      await Api.attendance.setAttendance({
        person: person.id,
        date: day.iso,
        punchIn: inTime ? stampFor(day.iso, inTime) : undefined,
        punchOut: outTime ? stampFor(day.iso, outTime) : undefined,
        remarks: `Corrected by HR on ${todayLocalIso()}`,
      });
      onSaved();
      onClose();
    } catch (e) {
      onError(e instanceof Error ? e.message : 'Could not save the attendance.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card title={`${person.name} — ${day.iso}`} className="dayedit__card">
      <div className="dayedit" ref={box}>
        <Field label="Punch in">
          <Input type="time" value={inTime} onChange={(e) => setInTime(e.target.value)} />
        </Field>
        <Field label="Punch out">
          <Input type="time" value={outTime} onChange={(e) => setOutTime(e.target.value)} />
        </Field>
        <Field label="Hours">
          <div className="dayedit__hours">{hours || '—'}</div>
        </Field>
        <div className="dayedit__actions">
          <Button size="sm" onClick={save} loading={saving} disabled={saving}>
            Save
          </Button>
          <Button size="sm" variant="ghost" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
        </div>
      </div>
      <p className="note" style={{ marginTop: 10 }}>
        {inTime && !outTime
          ? 'A punch-in with no punch-out stays an open shift and counts no hours.'
          : 'Saving overwrites this day for this person and recomputes the hours.'}
      </p>
    </Card>
  );
}

/** "2026-08-05 09:26:49" -> "09:26", for a time input. */
function hhmmOf(stamp?: string): string {
  if (!stamp) return '';
  const m = /(\d{2}):(\d{2})/.exec(stamp.slice(10));
  return m ? `${m[1]}:${m[2]}` : '';
}

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
}

/** What the cell says under the date. Kept short — the grid is the point. */
function detail(d: Day) {
  switch (d.state) {
    case 'worked':
      return (
        <>
          <div className="month__times">
            {clockOf(d.log?.punchIn)}–{clockOf(d.log?.punchOut)}
          </div>
          <div className="month__hours">{d.hours}h</div>
        </>
      );
    case 'open':
      return (
        <>
          <div className="month__times">in {clockOf(d.log?.punchIn)}</div>
          <div className="month__flag">no punch-out</div>
        </>
      );
    case 'leave':
      return <div className="month__tag">Leave{d.leave?.reason ? ` · ${d.leave.reason}` : ''}</div>;
    case 'half':
      return <div className="month__tag">Half day</div>;
    case 'future':
      return null;
    default:
      return <div className="month__muted">—</div>;
  }
}

function LegendKey({ state, label }: { state: string; label: string }) {
  return (
    <span className="cal__key">
      <i className={`cal__swatch s-${state}`} />
      {label}
    </span>
  );
}
