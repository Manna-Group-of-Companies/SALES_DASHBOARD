/**
 * The leave queue.
 *
 * The decision itself is one click, so the value of this screen is entirely in
 * what it puts in front of that click: whether the employee has the balance,
 * and who else from the same department is already off in the same week.
 * Both are checked before the approve button, not reported after it.
 */

import { useMemo, useState } from 'react';
import type { LeaveRequest, LeaveStatus } from '@/domain/types';
import { LEAVE_TYPE_LABEL } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import { clashingRequests, withinBalance, workingDaysBetween } from '@/domain/hrRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectEmployeeById, selectLeaveRequests, selectUser } from '@/store/selectors';
import { decideLeave } from '@/store/slices/hrSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Modal,
  Tabs,
  Textarea,
  type TabDef,
} from '@/components/ui';
import { relativeTime } from '@/components/common/format';
import { LeaveStatusBadge } from '@/components/common/StatusBadge';

type View = 'pending' | 'decided';

export function LeaveRequestsPage() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const requests = useAppSelector(selectLeaveRequests);
  const employeeById = useAppSelector(selectEmployeeById);

  const [view, setView] = useState<View>('pending');
  const [deciding, setDeciding] = useState<{ request: LeaveRequest; approve: boolean } | null>(null);
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);

  const pending = useMemo(
    () =>
      requests
        .filter((r) => r.status === 'pending')
        .sort((a, b) => a.fromDate.localeCompare(b.fromDate)),
    [requests],
  );
  const decided = useMemo(
    () =>
      requests
        .filter((r) => r.status !== 'pending')
        .sort((a, b) => (b.decidedAt ?? '').localeCompare(a.decidedAt ?? '')),
    [requests],
  );

  const tabs: TabDef<View>[] = [
    { id: 'pending', label: 'Waiting on you', count: pending.length },
    { id: 'decided', label: 'Decided', count: decided.length },
  ];

  const rows = view === 'pending' ? pending : decided;

  const confirm = async () => {
    if (!deciding || !user) return;
    setSaving(true);
    const result = await dispatch(
      decideLeave({
        request: deciding.request,
        approve: deciding.approve,
        decidedBy: user,
        note,
      }),
    );
    setSaving(false);

    if (decideLeave.fulfilled.match(result)) {
      dispatch(
        pushToast(
          `Leave ${deciding.approve ? 'approved' : 'rejected'} for ${deciding.request.employeeName}.`,
          deciding.approve ? 'success' : 'info',
        ),
      );
      setDeciding(null);
      setNote('');
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Leave requests</div>
          <div className="page-head__sub">
            {pending.length === 0
              ? 'Nothing waiting on a decision.'
              : `${pending.length} waiting on a decision.`}
          </div>
        </div>
      </div>

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={view} onChange={setView} />
        </div>

        {rows.length === 0 ? (
          <Empty icon="🗓" title={view === 'pending' ? 'Queue is clear' : 'Nothing decided yet'}>
            {view === 'pending'
              ? 'Every request has been decided.'
              : 'Approved and rejected requests appear here.'}
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Employee</th>
                  <th>Type</th>
                  <th>Dates</th>
                  <th className="right">Days</th>
                  <th>Reason</th>
                  <th>Status</th>
                  {view === 'pending' && <th style={{ width: 170 }} />}
                </tr>
              </thead>
              <tbody>
                {rows.map((request) => {
                  const employee = employeeById.get(request.employeeId);
                  const affordable = withinBalance(request, employee);
                  const clashes = clashingRequests(request, requests);

                  return (
                    <tr key={request.id}>
                      <td>
                        <div className="small strong">{request.employeeName}</div>
                        <div className="tiny dim">
                          {request.department} · applied {relativeTime(request.appliedAt)}
                        </div>
                      </td>
                      <td className="small">{LEAVE_TYPE_LABEL[request.type]}</td>
                      <td className="small">
                        {formatDate(request.fromDate)} – {formatDate(request.toDate)}
                      </td>
                      <td className="right num strong">{request.days}</td>
                      <td className="small" style={{ maxWidth: 260 }}>
                        {request.reason}
                        {request.decisionNote && (
                          <div className="tiny dim">↳ {request.decisionNote}</div>
                        )}
                      </td>
                      <td>
                        <LeaveStatusBadge status={request.status} />
                        {request.status === 'pending' && (
                          <div className="stack gap-1" style={{ marginTop: 4 }}>
                            {!affordable && (
                              <Badge tone="danger" title="More days than the paid balance allows">
                                {employee ? `${employee.leaveBalance}d balance` : 'No record'}
                              </Badge>
                            )}
                            {clashes.length > 0 && (
                              <Badge
                                tone="warn"
                                title={clashes
                                  .map((c) => `${c.employeeName}: ${c.fromDate} → ${c.toDate}`)
                                  .join('\n')}
                              >
                                {clashes.length} clash{clashes.length === 1 ? '' : 'es'}
                              </Badge>
                            )}
                          </div>
                        )}
                        {request.decidedAt && (
                          <div className="tiny dim" style={{ marginTop: 3 }}>
                            by {request.decidedBy} · {relativeTime(request.decidedAt)}
                          </div>
                        )}
                      </td>
                      {view === 'pending' && (
                        <td className="right">
                          <div className="row gap-2" style={{ justifyContent: 'flex-end' }}>
                            <Button
                              size="sm"
                              variant="danger"
                              onClick={() => {
                                setNote('');
                                setDeciding({ request, approve: false });
                              }}
                            >
                              Reject
                            </Button>
                            <Button
                              size="sm"
                              variant="primary"
                              onClick={() => {
                                setNote('');
                                setDeciding({ request, approve: true });
                              }}
                            >
                              Approve
                            </Button>
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {deciding && (
        <DecisionModal
          request={deciding.request}
          approve={deciding.approve}
          balance={employeeById.get(deciding.request.employeeId)?.leaveBalance}
          affordable={withinBalance(
            deciding.request,
            employeeById.get(deciding.request.employeeId),
          )}
          clashes={clashingRequests(deciding.request, requests)}
          note={note}
          onNote={setNote}
          saving={saving}
          onClose={() => setDeciding(null)}
          onConfirm={() => void confirm()}
        />
      )}
    </div>
  );
}

function DecisionModal({
  request,
  approve,
  balance,
  affordable,
  clashes,
  note,
  onNote,
  saving,
  onClose,
  onConfirm,
}: {
  request: LeaveRequest;
  approve: boolean;
  balance?: number;
  affordable: boolean;
  clashes: LeaveRequest[];
  note: string;
  onNote: (v: string) => void;
  saving: boolean;
  onClose: () => void;
  onConfirm: () => void;
}) {
  const working = workingDaysBetween(request.fromDate, request.toDate);

  return (
    <Modal
      title={`${approve ? 'Approve' : 'Reject'} leave — ${request.employeeName}`}
      onClose={onClose}
      footer={
        <>
          <Button onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button
            variant={approve ? 'primary' : 'danger'}
            loading={saving}
            // A rejection without a reason is the one thing the employee will
            // come back and ask about, so it is required.
            disabled={!approve && !note.trim()}
            onClick={onConfirm}
          >
            {approve ? 'Approve leave' : 'Reject leave'}
          </Button>
        </>
      }
    >
      <div className="stack gap-3">
        <div className="row gap-4" style={{ flexWrap: 'wrap' }}>
          <Metric label="Type" value={LEAVE_TYPE_LABEL[request.type]} />
          <Metric
            label="Dates"
            value={`${formatDate(request.fromDate)} – ${formatDate(request.toDate)}`}
          />
          <Metric label="Days claimed" value={String(request.days)} />
          <Metric label="Working days" value={String(working)} />
          <Metric label="Balance" value={balance == null ? '—' : `${balance} days`} />
        </div>

        <div className="small">{request.reason}</div>

        {approve && !affordable && (
          <Alert tone="warn" title="More than the paid balance">
            {balance ?? 0} day{balance === 1 ? '' : 's'} left against {request.days} claimed.
            Approving anyway will take the balance to zero, not negative — settle the difference as
            unpaid leave.
          </Alert>
        )}

        {approve && request.days !== working && (
          <Alert tone="info" title="Claim does not match the calendar">
            {request.days} day{request.days === 1 ? '' : 's'} claimed, {working} working day
            {working === 1 ? '' : 's'} in the range. Sundays are not counted.
          </Alert>
        )}

        {approve && clashes.length > 0 && (
          <Alert
            tone="warn"
            title={`${clashes.length} other ${request.department} request${clashes.length === 1 ? '' : 's'} overlap${clashes.length === 1 ? 's' : ''}`}
          >
            <div className="stack gap-1" style={{ marginTop: 4 }}>
              {clashes.map((c) => (
                <div key={c.id} className="tiny">
                  {c.employeeName} · {formatDate(c.fromDate)} – {formatDate(c.toDate)} ·{' '}
                  {statusWord(c.status)}
                </div>
              ))}
            </div>
          </Alert>
        )}

        {approve && (
          <Alert tone="info">
            Approving marks every working day in the range as on-leave on the attendance sheet.
          </Alert>
        )}

        <Field
          label={approve ? 'Note (optional)' : 'Reason for rejection'}
          hint={approve ? undefined : 'The employee will be told this.'}
        >
          <Textarea rows={3} value={note} onChange={(e) => onNote(e.target.value)} />
        </Field>
      </div>
    </Modal>
  );
}

function statusWord(status: LeaveStatus): string {
  return status === 'pending' ? 'also waiting' : status;
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="detail-item__label">{label}</div>
      <div className="small strong">{value}</div>
    </div>
  );
}
