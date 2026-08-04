/**
 * The HR landing page.
 *
 * Same idea as the sales dashboard: answer "what needs me right now?" without
 * anyone having to ask around. For HR that is three questions — who is not on
 * the floor today, who has not been marked yet, and what leave is waiting on a
 * decision — so the roster is markable straight from here rather than being a
 * read-only summary that sends you somewhere else to act.
 */

import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import type { AttendanceStatus, Employee } from '@/domain/types';
import { ATTENDANCE_LABEL, LEAVE_TYPE_LABEL } from '@/domain/types';
import { formatDate, toIsoDate } from '@/domain/orderRules';
import {
  attendanceByEmployee,
  attendanceTrend,
  newJoiners,
  upcomingAnniversaries,
} from '@/domain/hrRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  selectActiveEmployees,
  selectAttendance,
  selectHeadcountByDepartment,
  selectPendingLeave,
  selectTodayAttendance,
  selectUser,
} from '@/store/selectors';
import { markAttendance } from '@/store/slices/hrSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Badge, Button, Card, Empty, Meter, Select } from '@/components/ui';
import { greeting, initials, relativeTime } from '@/components/common/format';
import { AttendanceBadge } from '@/components/common/StatusBadge';
import { Tile } from '@/components/common/Tile';
import '@/components/layout/layout.css';

/** The four an HR executive actually marks. `holiday` is a property of the day. */
const MARKABLE: AttendanceStatus[] = ['present', 'half_day', 'on_leave', 'absent'];

export function HrDashboardPage() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();

  const user = useAppSelector(selectUser);
  const employees = useAppSelector(selectActiveEmployees);
  const attendance = useAppSelector(selectAttendance);
  const today = useAppSelector(selectTodayAttendance);
  const byDepartment = useAppSelector(selectHeadcountByDepartment);
  const pending = useAppSelector(selectPendingLeave);

  const todayIso = toIsoDate(new Date());

  const marked = useMemo(
    () => attendanceByEmployee(attendance, todayIso),
    [attendance, todayIso],
  );
  const trend = useMemo(
    () => attendanceTrend(employees, attendance, todayIso, 7),
    [employees, attendance, todayIso],
  );
  const joiners = useMemo(() => newJoiners(employees, todayIso), [employees, todayIso]);
  const anniversaries = useMemo(
    () => upcomingAnniversaries(employees, todayIso),
    [employees, todayIso],
  );

  if (!user) return null;

  const mark = async (employee: Employee, status: AttendanceStatus) => {
    const result = await dispatch(
      markAttendance({
        employeeId: employee.id,
        date: todayIso,
        status,
        markedBy: user,
      }),
    );
    if (markAttendance.fulfilled.match(result)) {
      dispatch(pushToast(`${employee.name} marked ${ATTENDANCE_LABEL[status].toLowerCase()}.`));
    }
  };

  const largest = byDepartment[0]?.count ?? 1;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {greeting()}, {user.name.split(' ')[0]}
          </div>
          <div className="page-head__sub">
            {formatDate(todayIso)} · {today.total} on the books
          </div>
        </div>
      </div>

      {/* --- what cannot wait ------------------------------------------- */}
      <div className="stack gap-3" style={{ marginBottom: 16 }}>
        {pending.length > 0 && (
          <Alert
            tone="warn"
            title={`${pending.length} leave request${pending.length === 1 ? '' : 's'} waiting on you`}
            actions={
              <Button size="sm" onClick={() => navigate('/hr/leave')}>
                Open queue
              </Button>
            }
          >
            The earliest starts {formatDate(pending[0]!.fromDate)}.
          </Alert>
        )}
        {today.unmarked > 0 && (
          <Alert
            tone="info"
            title={`${today.unmarked} ${today.unmarked === 1 ? 'person has' : 'people have'} not been marked today`}
          >
            Unmarked is not the same as absent — mark them below so the day's record is complete.
          </Alert>
        )}
      </div>

      {/* --- tiles ------------------------------------------------------ */}
      <div className="tiles">
        <Tile
          label="Headcount"
          value={String(today.total)}
          foot={`${byDepartment.length} department${byDepartment.length === 1 ? '' : 's'}`}
          onClick={() => navigate('/hr/employees')}
        />
        <Tile
          label="Present today"
          value={String(today.present + today.halfDay)}
          tone="ok"
          foot={
            today.halfDay > 0
              ? `${today.halfDay} on half day`
              : `${Math.round(today.rate * 100)}% of those marked`
          }
        />
        <Tile
          label="On leave"
          value={String(today.onLeave)}
          foot={today.absent > 0 ? `${today.absent} absent without leave` : 'Nobody absent'}
          tone={today.absent > 0 ? 'warn' : undefined}
        />
        <Tile
          label="Leave to decide"
          value={String(pending.length)}
          tone={pending.length ? 'warn' : undefined}
          foot="Needs your decision"
          onClick={() => navigate('/hr/leave')}
        />
      </div>

      <div className="cols cols--sidebar">
        {/* --- the roster ---------------------------------------------- */}
        <Card
          title="Today's roster"
          actions={
            <Button size="sm" variant="ghost" onClick={() => navigate('/hr/employees')}>
              Employee list →
            </Button>
          }
          flush
        >
          {employees.length === 0 ? (
            <Empty icon="👥" title="No employees on file">
              Employee records come from the HR module.
            </Empty>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Employee</th>
                    <th>Department</th>
                    <th>Status</th>
                    <th>In / out</th>
                    <th style={{ width: 150 }}>Mark</th>
                  </tr>
                </thead>
                <tbody>
                  {/* Unmarked first — they are the only rows needing a decision. */}
                  {[...employees]
                    .sort(
                      (a, b) =>
                        Number(marked.has(a.id)) - Number(marked.has(b.id)) ||
                        a.name.localeCompare(b.name),
                    )
                    .map((employee) => {
                      const row = marked.get(employee.id);
                      return (
                        <tr key={employee.id}>
                          <td>
                            <div className="row gap-2">
                              <div className="avatar">{initials(employee.name)}</div>
                              <div style={{ minWidth: 0 }}>
                                <div className="small strong">{employee.name}</div>
                                <div className="tiny dim">{employee.designation}</div>
                              </div>
                            </div>
                          </td>
                          <td className="small">{employee.department}</td>
                          <td>
                            <AttendanceBadge status={row?.status} />
                          </td>
                          <td className="tiny dim mono">
                            {row?.checkIn ? `${row.checkIn} – ${row.checkOut ?? '…'}` : '—'}
                          </td>
                          <td>
                            {row?.status === 'holiday' ? (
                              <span className="tiny dim">Weekly off</span>
                            ) : (
                              <Select
                                compact
                                aria-label={`Mark attendance for ${employee.name}`}
                                value={row?.status ?? ''}
                                onChange={(e) =>
                                  void mark(employee, e.target.value as AttendanceStatus)
                                }
                              >
                                <option value="" disabled>
                                  Not marked
                                </option>
                                {MARKABLE.map((s) => (
                                  <option key={s} value={s}>
                                    {ATTENDANCE_LABEL[s]}
                                  </option>
                                ))}
                              </Select>
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

        {/* --- the sidebar ---------------------------------------------- */}
        <div className="stack gap-3">
          <Card title="Headcount by department">
            <div className="stack gap-3">
              {byDepartment.map(({ department, count }) => (
                <div key={department}>
                  <div className="row gap-2">
                    <span className="small grow">{department}</span>
                    <span className="small strong num">{count}</span>
                  </div>
                  <div style={{ marginTop: 4 }}>
                    <Meter value={count / largest} label={`${count} in ${department}`} />
                  </div>
                </div>
              ))}
            </div>
          </Card>

          <Card title="Attendance, last 7 days">
            <div className="stack gap-2">
              {trend.map((day) => (
                <div key={day.date} className="row gap-2">
                  <span className="tiny dim" style={{ width: 52 }}>
                    {shortDate(day.date)}
                  </span>
                  <span className="grow">
                    <Meter
                      value={day.rate}
                      tone={day.rate >= 0.9 ? 'ok' : day.rate >= 0.75 ? 'warn' : 'danger'}
                      label={`${Math.round(day.rate * 100)}% present`}
                    />
                  </span>
                  <span className="tiny num" style={{ width: 34, textAlign: 'right' }}>
                    {day.present + day.halfDay + day.absent + day.onLeave === 0
                      ? '—'
                      : `${Math.round(day.rate * 100)}%`}
                  </span>
                </div>
              ))}
            </div>
          </Card>

          <Card title="Leave to decide" flush>
            {pending.length === 0 ? (
              <Empty icon="🗓" title="Nothing pending">
                Every request has been decided.
              </Empty>
            ) : (
              <div style={{ padding: 14 }} className="stack gap-3">
                {pending.slice(0, 4).map((request) => (
                  <div key={request.id}>
                    <div className="row gap-2">
                      <span className="small strong grow">{request.employeeName}</span>
                      <Badge tone="warn">{request.days}d</Badge>
                    </div>
                    <div className="tiny dim">
                      {LEAVE_TYPE_LABEL[request.type]} · {formatDate(request.fromDate)} –{' '}
                      {formatDate(request.toDate)} · applied {relativeTime(request.appliedAt)}
                    </div>
                  </div>
                ))}
                <Button size="sm" block onClick={() => navigate('/hr/leave')}>
                  Open the queue
                </Button>
              </div>
            )}
          </Card>

          {(joiners.length > 0 || anniversaries.length > 0) && (
            <Card title="Coming up">
              <div className="stack gap-3">
                {joiners.map((employee) => (
                  <div key={`join-${employee.id}`} className="row gap-2">
                    <span className="small grow">{employee.name}</span>
                    <Badge tone="info">joined {formatDate(employee.joinedOn)}</Badge>
                  </div>
                ))}
                {anniversaries.map((a) => (
                  <div key={`anniv-${a.employee.id}`} className="row gap-2">
                    <span className="small grow">{a.employee.name}</span>
                    <Badge tone="accent">
                      {a.years}
                      {ordinal(a.years)} year {a.inDays === 0 ? 'today' : `in ${a.inDays}d`}
                    </Badge>
                  </div>
                ))}
              </div>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}

/** "04 Aug" — the trend rows have room for nothing longer. */
function shortDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y ?? 1970, (m ?? 1) - 1, d ?? 1).toLocaleDateString('en-IN', {
    day: '2-digit',
    month: 'short',
  });
}

function ordinal(n: number): string {
  if (n % 100 >= 11 && n % 100 <= 13) return 'th';
  return ['th', 'st', 'nd', 'rd'][n % 10] ?? 'th';
}
