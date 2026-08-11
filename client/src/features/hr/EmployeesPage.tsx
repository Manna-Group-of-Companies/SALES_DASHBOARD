/**
 * The people roster.
 *
 * These are `Sales Person` records, not `Employee` — see `domain/attendance`.
 * Each row carries the identity HR needs (team, business unit, login) plus
 * this month's attendance so far, because "who is this person and how have
 * they been working" is one question, not two.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { AttendanceLog, FieldLeaveRequest, SalesPerson } from '@/domain/types';
import {
  activeSalesPeople,
  isoOf,
  monthFor,
  teamsOf,
  todayLocalIso,
} from '@/domain/attendance';
import { Api } from '@/api/client';
import { Alert, Badge, Card, Empty, Input, Segmented } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

export function EmployeesPage() {
  const today = todayLocalIso();
  const now = new Date();
  const monthStart = isoOf(now.getFullYear(), now.getMonth(), 1);

  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [logs, setLogs] = useState<AttendanceLog[]>([]);
  const [leave, setLeave] = useState<FieldLeaveRequest[]>([]);
  const [team, setTeam] = useState<string>('all');
  const [query, setQuery] = useState('');
  /** Bumped to re-run the load effect — the Refresh button's only job. */
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.attendance.listSalesPeople(),
      Api.attendance.listAttendanceLogs(monthStart),
      Api.attendance.listLeaveRequests(),
    ])
      .then(([p, l, lv]) => {
        if (!live) return;
        setPeople(p);
        setLogs(l);
        setLeave(lv);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the roster.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [monthStart, tick]);

  const staff = useMemo(() => activeSalesPeople(people), [people]);
  const teams = useMemo(() => teamsOf(people), [people]);

  /** Identity plus this month's attendance, per person. */
  const rows = useMemo(
    () =>
      staff
        .map((person) => ({
          person,
          month: monthFor(person, now.getFullYear(), now.getMonth(), logs, leave, today),
          onFloorToday: logs.some(
            (l) => l.person === person.id && l.date === today && l.status === 'Punched In',
          ),
        }))
        .filter((r) => (team === 'all' ? true : r.person.teamManager === team))
        .filter((r) => {
          const q = query.trim().toLowerCase();
          if (!q) return true;
          return (
            r.person.name.toLowerCase().includes(q) ||
            (r.person.unit ?? '').toLowerCase().includes(q) ||
            (r.person.userId ?? '').toLowerCase().includes(q)
          );
        })
        .sort((a, b) => a.person.name.localeCompare(b.person.name)),
    [staff, logs, leave, today, team, query, now],
  );

  const disabled = useMemo(() => people.filter((p) => !p.isGroup && !p.enabled), [people]);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Sales people</div>
          <div className="page-head__sub">
            {staff.length} active across {teams.length} {teams.length === 1 ? 'team' : 'teams'} ·
            attendance shown for this month
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the roster">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="Active" value={String(staff.length)} foot="On the books" />
        {teams.map((t) => (
          <Tile
            key={t.manager}
            label={t.manager}
            value={String(t.members.length)}
            foot={t.unit}
          />
        ))}
      </div>

      <div className="cal__toolbar">
        <Input
          placeholder="Search name, unit or login…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search people"
        />
        <Segmented
          ariaLabel="Team"
          value={team}
          onChange={setTeam}
          options={[
            { value: 'all', label: 'All teams' },
            ...teams.map((t) => ({ value: t.manager, label: t.manager })),
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Reading roster…" />}

      {!loading && !error && (
        <Card flush>
          {rows.length === 0 ? (
            <Empty icon="—" title="Nobody matches" />
          ) : (
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Team manager</th>
                    <th>Business unit</th>
                    <th>Login</th>
                    <th>Today</th>
                    <th className="right">Worked</th>
                    <th className="right">Hours</th>
                    <th className="right">Leave</th>
                    <th className="right">Open</th>
                    <th className="right">Calendar</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map(({ person, month, onFloorToday }) => (
                    <tr key={person.id}>
                      <td>{person.name}</td>
                      <td className="dim">{person.teamManager || '—'}</td>
                      <td className="dim">{person.unit || '—'}</td>
                      <td className="mono small">
                        {person.userId ? person.userId.split('@')[0] : <span className="dim">no login</span>}
                      </td>
                      <td>
                        {onFloorToday ? (
                          <Badge tone="ok" dot>
                            On floor
                          </Badge>
                        ) : (
                          <span className="dim small">—</span>
                        )}
                      </td>
                      <td className="right num">{month.worked}</td>
                      <td className="right num">{month.hours}</td>
                      <td className="right num">{month.leaveDays || <span className="dim">—</span>}</td>
                      <td className="right num">
                        {month.open ? (
                          <span style={{ color: 'var(--danger)', fontWeight: 650 }}>{month.open}</span>
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right">
                        <Link to="/hr/calendar" className="small">
                          Open
                        </Link>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      )}

      {disabled.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          {disabled.length} disabled record{disabled.length === 1 ? '' : 's'} hidden (
          {disabled.map((d) => d.name).join(', ')}), along with the “Sales Team” group node — those
          are not people and would inflate every headcount.
        </p>
      )}
    </div>
  );
}
