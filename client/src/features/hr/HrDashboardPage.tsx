/**
 * The HR landing page.
 *
 * Answers "what needs me right now?" from the real doctypes — `Sales Person`,
 * `Attendance Log`, `Leave Request`, `Attendance Regularization`. See
 * `domain/attendance.ts` for why those and not the Frappe HR ones.
 *
 * Read-only on purpose. Approving belongs on the queue screens, where the
 * decision and the record are in one place; a dashboard that also decides is
 * a second place to miss something.
 */

import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type {
  AttendanceLog,
  AttendanceRegularization,
  FieldLeaveRequest,
  SalesPerson,
} from '@/domain/types';
import {
  activeSalesPeople,
  DAY_STATUS_LABEL,
  rosterCounts,
  rosterFor,
  clockOf,
  duplicateLeaveKeys,
  leaveKey,
  openShifts,
  shiftIso,
  teamsOf,
  todayLocalIso,
} from '@/domain/attendance';
import { arQueueFor } from '@/domain/approvals';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Meter } from '@/components/ui';
import { greeting } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

/** Enough history for the open-shift queue without dragging in months of rows. */
const LOOKBACK_DAYS = 21;

export function HrDashboardPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const today = todayLocalIso();

  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [logs, setLogs] = useState<AttendanceLog[]>([]);
  const [leave, setLeave] = useState<FieldLeaveRequest[]>([]);
  const [regs, setRegs] = useState<AttendanceRegularization[]>([]);
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
      Api.attendance.listAttendanceLogs(shiftIso(today, -LOOKBACK_DAYS)),
      Api.attendance.listLeaveRequests(),
      Api.attendance.listRegularizations(),
    ])
      .then(([p, l, lv, r]) => {
        if (!live) return;
        setPeople(p);
        setLogs(l);
        setLeave(lv);
        setRegs(r);
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
  const teams = useMemo(() => teamsOf(people), [people]);

  const todayLogs = useMemo(
    () => logs.filter((l) => l.date === today).sort((a, b) => (a.punchIn ?? '').localeCompare(b.punchIn ?? '')),
    [logs, today],
  );
  const onFloor = useMemo(() => todayLogs.filter((l) => l.status === 'Punched In'), [todayLogs]);
  /**
   * Everyone, and where they stood today.
   *
   * Replaces a naive "has no log" list, which counted people on approved leave
   * and on a weekly off as missing — and so reported absences that were fully
   * explained on the record.
   */
  const roster = useMemo(() => rosterFor(today, people, logs, leave), [today, people, logs, leave]);
  const counts = useMemo(() => rosterCounts(roster), [roster]);
  const notAtWork = useMemo(
    () => roster.filter((r) => r.status !== 'present' && r.status !== 'on_floor'),
    [roster],
  );

  const open = useMemo(() => openShifts(logs, today, LOOKBACK_DAYS), [logs, today]);

  const pendingLeave = useMemo(
    () =>
      leave
        .filter((l) => l.status === 'Pending Approval')
        .sort((a, b) => b.date.localeCompare(a.date)),
    [leave],
  );
  const dupes = useMemo(() => duplicateLeaveKeys(leave), [leave]);

  /**
   * Only the ones HR can actually decide — a rep's own regularization belongs
   * to their manager, so listing it here would be work HR cannot do.
   */
  const pendingRegs = useMemo(() => arQueueFor(regs, 'hr'), [regs]);

  if (!user) return null;

  const turnoutFor = (manager: string) => {
    const members = teams.find((t) => t.manager === manager)?.members ?? [];
    const ids = new Set(members.map((m) => m.id));
    const inCount = onFloor.filter((l) => ids.has(l.person)).length;
    return { inCount, total: members.length };
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {greeting()}, {user.name.split(' ')[0]}
          </div>
          <div className="page-head__sub">
            {formatDate(today)} · {staff.length} active sales {staff.length === 1 ? 'person' : 'people'} across{' '}
            {teams.length} {teams.length === 1 ? 'team' : 'teams'}
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read attendance from ERPNext">
          {error}
        </Alert>
      )}

      {loading && !error && <Empty icon="◔" title="Reading attendance…" />}

      {!loading && !error && (
        <>
          <div className="stack gap-3" style={{ marginBottom: 16 }}>
            {open.length > 0 && (
              <Alert tone="warn" title={`${open.length} open shift${open.length === 1 ? '' : 's'}`}>
                Punched in on an earlier day and never punched out. A day with no punch-out has no
                measured hours, so it counts as nothing on the calendar until it is regularised.
              </Alert>
            )}
          </div>

          <div className="tiles">
            <Tile
              label="On the floor"
              value={`${onFloor.length} / ${staff.length}`}
              tone={onFloor.length ? 'ok' : 'warn'}
              foot="Punched in today"
            />
            {/* Absent means unexplained: leave and weekly offs are excluded. */}
            <Tile
              label="No punch yet"
              value={String(counts.absent)}
              tone={counts.absent ? 'warn' : undefined}
              foot={
                counts.leave_pending
                  ? `+${counts.leave_pending} leave not yet granted`
                  : 'No punch and no leave today'
              }
            />
            <Tile
              label="On leave"
              value={String(counts.on_leave)}
              foot="Granted, not absence"
            />
            <Tile
              label="Open shifts"
              value={String(open.length)}
              tone={open.length ? 'alert' : undefined}
              foot="Punched in, never out"
            />
            <Tile
              label="Leave to decide"
              value={String(pendingLeave.length)}
              tone={pendingLeave.length ? 'warn' : undefined}
              foot={pendingLeave.length ? `Oldest ${formatDate(pendingLeave[pendingLeave.length - 1]!.date)}` : 'Queue clear'}
              onClick={() => navigate('/hr/leave')}
            />
            <Tile
              label="Regularisations"
              value={String(pendingRegs.length)}
              tone={pendingRegs.length ? 'warn' : undefined}
              foot="Managers' own, awaiting you"
              onClick={() => navigate('/hr/regularizations')}
            />
          </div>

          {/*
            Who is not at work, and why.
            Absent is the last resort: a punch, granted leave, an undecided
            request and a Sunday are all checked first, so nobody lands in this
            column who has an explanation on file. `leave_pending` is kept
            separate from `on_leave` because an undecided request is not time
            off — folding the two would let unapproved absence disappear into
            the leave column.
          */}
          <Card
            title={`Not at work — ${formatDate(today)}`}
            className="mt-16"
            actions={
              <span className="roster__legend">
                <Badge tone="ok">{counts.present} present</Badge>
                {counts.on_floor > 0 && <Badge tone="ok" dot>{counts.on_floor} still out</Badge>}
                {counts.on_leave > 0 && <Badge tone="neutral">{counts.on_leave} on leave</Badge>}
                {counts.weekly_off > 0 && <Badge tone="neutral">{counts.weekly_off} weekly off</Badge>}
                {counts.absent > 0 && <Badge tone="warn">{counts.absent} no punch yet</Badge>}
              </span>
            }
            flush
          >
            {notAtWork.length === 0 ? (
              <Empty icon="✓" title="Everyone is accounted for">
                {counts.weekly_off > 0
                  ? 'Today is a weekly off.'
                  : 'Every active representative has punched in or is on approved leave.'}
              </Empty>
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Sales person</th>
                      <th>Team</th>
                      <th>Status</th>
                      <th>Reason on file</th>
                    </tr>
                  </thead>
                  <tbody>
                    {notAtWork.map((r) => (
                      <tr key={r.person.id}>
                        <td>{r.person.name}</td>
                        <td className="dim small">{r.person.teamManager || '—'}</td>
                        <td>
                          {r.status === 'absent' ? (
                            /* The day is not over. Someone with no punch at
                               10am has not been absent — they have not punched
                               in yet, and the two are different accusations. */
                            <Badge tone="warn">No punch yet</Badge>
                          ) : r.status === 'leave_pending' ? (
                            <Badge tone="warn">Leave not yet granted</Badge>
                          ) : (
                            <Badge tone="neutral">
                              {DAY_STATUS_LABEL[r.status]}
                              {r.halfDay ? ' (half day)' : ''}
                            </Badge>
                          )}
                        </td>
                        <td className="dim small">
                          {r.status === 'absent'
                            ? 'No punch and no leave — today is still running'
                            : r.leave
                              ? r.leave.reason || 'No reason given'
                              : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <div className="cols cols--sidebar" style={{ marginTop: 16 }}>
            <Card
              title="Punched in today"
              actions={
                <Button size="sm" variant="ghost" onClick={() => navigate('/hr/calendar')}>
                  Monthly calendar →
                </Button>
              }
              flush
            >
              {todayLogs.length === 0 ? (
                <Empty icon="—" title="Nobody has punched in today" />
              ) : (
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Sales person</th>
                        <th className="right">In</th>
                        <th className="right">Out</th>
                        <th className="right">Hours</th>
                        <th className="right">Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {todayLogs.map((l) => {
                        const out = l.status === 'Punched Out';
                        return (
                          <tr key={l.id}>
                            <td>{l.person}</td>
                            <td className="right num">{clockOf(l.punchIn)}</td>
                            <td className="right num">{out ? clockOf(l.punchOut) : <span className="dim">—</span>}</td>
                            <td className="right num">{out ? `${l.workingHours}h` : <span className="dim">—</span>}</td>
                            <td className="right">
                              {out ? (
                                <Badge tone="neutral">Out</Badge>
                              ) : (
                                <Badge tone="ok" dot>
                                  On floor
                                </Badge>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>

            <Card title="Punched in today, by team" >
              <div className="stack gap-3">
                {teams.map((t) => {
                  const { inCount, total } = turnoutFor(t.manager);
                  const pct = total ? inCount / total : 0;
                  return (
                    <div key={t.manager}>
                      <div className="row-between small" style={{ marginBottom: 4 }}>
                        <span>
                          <b>{t.manager}</b> <span className="dim tiny">· {t.unit}</span>
                        </span>
                        <span className="num dim">
                          {inCount} / {total}
                        </span>
                      </div>
                      <Meter
                        value={pct}
                        tone={inCount === 0 ? 'danger' : pct < 0.6 ? 'warn' : 'accent'}
                        label={`${inCount} of ${total} punched in today`}
                      />
                    </div>
                  );
                })}
              </div>
            </Card>
          </div>

          <div className="cols cols--2" style={{ marginTop: 16 }}>
            <Card
              title="Leave awaiting a decision"
              actions={
                <Button size="sm" variant="ghost" onClick={() => navigate('/hr/leave')}>
                  Open queue →
                </Button>
              }
              flush
            >
              {pendingLeave.length === 0 ? (
                <Empty icon="✓" title="Nothing waiting" />
              ) : (
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Request</th>
                        <th>Sales person</th>
                        <th>Date</th>
                        <th className="right">Days</th>
                      </tr>
                    </thead>
                    <tbody>
                      {pendingLeave.slice(0, 8).map((l) => (
                        <tr key={l.id}>
                          <td className="mono small">{l.id}</td>
                          <td>{l.person}</td>
                          <td className="num">{formatDate(l.date)}</td>
                          <td className="right">
                            {dupes.has(leaveKey(l)) ? (
                              <Badge tone="danger">duplicate?</Badge>
                            ) : (
                              <span className="num">{l.days}</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>

            <Card
              title="Regularisations awaiting HR"
              actions={
                <Button size="sm" variant="ghost" onClick={() => navigate('/hr/regularizations')}>
                  All regularisations →
                </Button>
              }
              flush
            >
              {pendingRegs.length === 0 ? (
                <Empty icon="✓" title="Nothing waiting on HR">
                  Reps' own corrections are decided by their manager.
                </Empty>
              ) : (
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Request</th>
                        <th>Sales person</th>
                        <th>Date</th>
                        <th>Approver</th>
                      </tr>
                    </thead>
                    <tbody>
                      {pendingRegs.slice(0, 8).map((r) => (
                        <tr key={r.id}>
                          <td className="mono small">{r.id}</td>
                          <td>{r.person}</td>
                          <td className="num">{formatDate(r.date)}</td>
                          <td className="dim small">
                            {r.approverType}
                            {r.teamManager ? ` · ${r.teamManager}` : ''}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>
          </div>
        </>
      )}
    </div>
  );
}
