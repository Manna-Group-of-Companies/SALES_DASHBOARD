/**
 * The employee directory.
 *
 * One row per person on the books, searchable by name, designation or phone
 * because that is how someone is actually looked for. Relieved staff are kept
 * behind a toggle rather than deleted — HR still needs to answer questions
 * about people who have left.
 */

import { useMemo, useState } from 'react';
import type { Department, Employee, LeaveRequest } from '@/domain/types';
import { DEPARTMENTS, EMPLOYMENT_TYPE_LABEL } from '@/domain/types';
import { formatDate, toIsoDate } from '@/domain/orderRules';
import { attendanceByEmployee, isActiveOn, tenureYears } from '@/domain/hrRules';
import { useAppSelector } from '@/store/hooks';
import { selectAttendance, selectEmployees, selectLeaveRequests } from '@/store/selectors';
import { Badge, Button, Card, Empty, Input, Modal, Select } from '@/components/ui';
import { initials } from '@/components/common/format';
import { AttendanceBadge, LeaveStatusBadge } from '@/components/common/StatusBadge';

export function EmployeesPage() {
  const employees = useAppSelector(selectEmployees);
  const attendance = useAppSelector(selectAttendance);
  const leave = useAppSelector(selectLeaveRequests);

  const [query, setQuery] = useState('');
  const [department, setDepartment] = useState<Department | 'all'>('all');
  const [includeLeavers, setIncludeLeavers] = useState(false);
  const [open, setOpen] = useState<Employee | null>(null);

  const todayIso = toIsoDate(new Date());
  const marked = useMemo(
    () => attendanceByEmployee(attendance, todayIso),
    [attendance, todayIso],
  );

  const rows = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return employees
      .filter((e) => includeLeavers || isActiveOn(e, todayIso))
      .filter((e) => department === 'all' || e.department === department)
      .filter(
        (e) =>
          !needle ||
          e.name.toLowerCase().includes(needle) ||
          e.designation.toLowerCase().includes(needle) ||
          (e.phone ?? '').includes(needle) ||
          e.id.toLowerCase().includes(needle),
      )
      .sort((a, b) => a.name.localeCompare(b.name));
  }, [employees, includeLeavers, department, query, todayIso]);

  const leavers = employees.filter((e) => !isActiveOn(e, todayIso)).length;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Employees</div>
          <div className="page-head__sub">
            {rows.length} of {employees.length} on file
            {leavers > 0 && ` · ${leavers} relieved`}
          </div>
        </div>
      </div>

      <Card flush>
        <div className="row gap-2" style={{ padding: 14, flexWrap: 'wrap' }}>
          <Input
            placeholder="Search name, designation or phone…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            style={{ maxWidth: 320 }}
            aria-label="Search employees"
          />
          <Select
            value={department}
            onChange={(e) => setDepartment(e.target.value as Department | 'all')}
            aria-label="Filter by department"
          >
            <option value="all">All departments</option>
            {DEPARTMENTS.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </Select>
          <div className="grow" />
          <Button
            size="sm"
            variant={includeLeavers ? 'primary' : 'ghost'}
            onClick={() => setIncludeLeavers((v) => !v)}
          >
            {includeLeavers ? 'Hide relieved' : 'Show relieved'}
          </Button>
        </div>

        {rows.length === 0 ? (
          <Empty icon="👥" title="Nobody matches">
            Try a different department, or clear the search.
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Employee</th>
                  <th>Department</th>
                  <th>Type</th>
                  <th>Joined</th>
                  <th>Today</th>
                  <th className="right">Leave balance</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((employee) => {
                  const active = isActiveOn(employee, todayIso);
                  return (
                    <tr key={employee.id} className="is-clickable" onClick={() => setOpen(employee)}>
                      <td>
                        <div className="row gap-2">
                          <div className="avatar">{initials(employee.name)}</div>
                          <div style={{ minWidth: 0 }}>
                            <div className="small strong">{employee.name}</div>
                            <div className="tiny dim">
                              {employee.designation} · <span className="mono">{employee.id}</span>
                            </div>
                          </div>
                        </div>
                      </td>
                      <td className="small">
                        {employee.department}
                        {employee.location && <div className="tiny dim">{employee.location}</div>}
                      </td>
                      <td className="small">{EMPLOYMENT_TYPE_LABEL[employee.employmentType]}</td>
                      <td className="small">
                        {formatDate(employee.joinedOn)}
                        <div className="tiny dim">
                          {tenureYears(employee, todayIso)} yr
                          {tenureYears(employee, todayIso) === 1 ? '' : 's'}
                        </div>
                      </td>
                      <td>
                        {active ? (
                          <AttendanceBadge status={marked.get(employee.id)?.status} />
                        ) : (
                          <Badge tone="neutral">Relieved {formatDate(employee.leftOn!)}</Badge>
                        )}
                      </td>
                      <td className="right num">
                        {active ? `${employee.leaveBalance} d` : <span className="dim">—</span>}
                      </td>
                      <td className="right">
                        <span className="tiny dim">View →</span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {open && (
        <EmployeeModal
          employee={open}
          manager={employees.find((e) => e.id === open.reportsTo)}
          leave={leave.filter((r) => r.employeeId === open.id)}
          todayIso={todayIso}
          onClose={() => setOpen(null)}
        />
      )}
    </div>
  );
}

function EmployeeModal({
  employee,
  manager,
  leave,
  todayIso,
  onClose,
}: {
  employee: Employee;
  manager?: Employee;
  leave: LeaveRequest[];
  todayIso: string;
  onClose: () => void;
}) {
  return (
    <Modal title={employee.name} onClose={onClose} width="wide">
      <div className="stack gap-4">
        <div className="row gap-4" style={{ flexWrap: 'wrap' }}>
          <Detail label="Employee ID" value={employee.id} mono />
          <Detail label="Designation" value={employee.designation} />
          <Detail label="Department" value={employee.department} />
          <Detail label="Type" value={EMPLOYMENT_TYPE_LABEL[employee.employmentType]} />
          <Detail
            label="Joined"
            value={`${formatDate(employee.joinedOn)} (${tenureYears(employee, todayIso)} yrs)`}
          />
          <Detail label="Reports to" value={manager?.name ?? '—'} />
          <Detail label="Phone" value={employee.phone ?? '—'} />
          <Detail label="Email" value={employee.email ?? '—'} />
          <Detail label="Location" value={employee.location ?? '—'} />
          <Detail label="Leave balance" value={`${employee.leaveBalance} days`} />
        </div>

        <div>
          <div className="detail-item__label" style={{ marginBottom: 6 }}>
            Leave history
          </div>
          {leave.length === 0 ? (
            <div className="small dim">No leave applied for.</div>
          ) : (
            <div className="stack gap-2">
              {leave.map((request) => (
                <div key={request.id} className="row gap-2">
                  <span className="small grow">
                    {formatDate(request.fromDate)} – {formatDate(request.toDate)}
                    <span className="dim"> · {request.days}d</span>
                  </span>
                  <LeaveStatusBadge status={request.status} />
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </Modal>
  );
}

function Detail({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div style={{ minWidth: 130 }}>
      <div className="detail-item__label">{label}</div>
      <div className={`small strong ${mono ? 'mono' : ''}`}>{value}</div>
    </div>
  );
}
