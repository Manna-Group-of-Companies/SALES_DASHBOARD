/**
 * Leave requests — every request, and HR's half of the decision.
 *
 * Leave takes **two independent approvals**: the team manager and HR each
 * decide for themselves, in any order, and the rep only has the day off once
 * both have said yes. Neither waits for the other, so this screen never blocks
 * HR on the manager — it just shows, per row, which of the two is still
 * outstanding.
 *
 * The whole list is shown, not just the queue, because HR is asked "was that
 * approved?" about requests they have already handled.
 */

import { useEffect, useMemo, useState } from 'react';
import type { FieldLeaveRequest } from '@/domain/types';
import {
  isGranted,
  LEAVE_STAGE_LABEL,
  hrHasApproved,
  leaveCanRevoke,
  leaveNeedsDecisionFrom,
  managerHasApproved,
  leaveStage,
  requiredApprovals,
  type LeaveStage,
} from '@/domain/approvals';
import { duplicateLeaveKeys, leaveKey } from '@/domain/attendance';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Segmented } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

type Filter = 'mine' | 'open' | 'all';

export function LeaveRequestsPage() {
  const user = useAppSelector(selectUser);
  const [leave, setLeave] = useState<FieldLeaveRequest[]>([]);
  const [filter, setFilter] = useState<Filter>('mine');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => {
    setLoading(true);
    setError(null);
    Api.attendance
      .listLeaveRequests()
      .then(setLeave)
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not read leave requests.'),
      )
      .finally(() => setLoading(false));
  };

  useEffect(load, []);

  const dupes = useMemo(() => duplicateLeaveKeys(leave), [leave]);

  const rows = useMemo(() => {
    const sorted = [...leave].sort((a, b) => b.date.localeCompare(a.date));
    if (filter === 'all') return sorted;
    if (filter === 'open') return sorted.filter((l) => leaveStage(l) !== 'granted' && l.status !== 'Rejected');
    return sorted.filter((l) => leaveNeedsDecisionFrom(l, 'hr'));
  }, [leave, filter]);

  const counts = useMemo(
    () => ({
      mine: leave.filter((l) => leaveNeedsDecisionFrom(l, 'hr')).length,
      waitingManager: leave.filter((l) => leaveStage(l) === 'awaiting_manager').length,
      granted: leave.filter(isGranted).length,
      total: leave.length,
    }),
    [leave],
  );

  const revoke = async (l: FieldLeaveRequest) => {
    setBusy(l.id);
    try {
      const updated = await Api.attendance.revokeLeave({ id: l.id, as: 'hr' });
      setLeave((cur) => cur.map((x) => (x.id === updated.id ? updated : x)));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not revoke the decision.');
    } finally {
      setBusy(null);
    }
  };

  const decide = async (l: FieldLeaveRequest, approve: boolean) => {
    if (!user) return;
    setBusy(l.id);
    try {
      const updated = await Api.attendance.decideLeave({
        id: l.id,
        as: 'hr',
        approve,
        by: user.email,
      });
      setLeave((cur) => cur.map((x) => (x.id === updated.id ? updated : x)));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Leave requests</div>
          <div className="page-head__sub">
            Manager and HR approve independently — the day is granted only when both have
          </div>
        </div>
        <RefreshButton onClick={load} loading={loading} />
        <Segmented
          ariaLabel="Filter"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'mine', label: `Needs HR (${counts.mine})` },
            { value: 'open', label: 'Open' },
            { value: 'all', label: `All (${counts.total})` },
          ]}
        />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Waiting on you"
          value={String(counts.mine)}
          tone={counts.mine ? 'warn' : undefined}
          foot="HR has not decided"
        />
        <Tile
          label="Waiting on a manager"
          value={String(counts.waitingManager)}
          foot="You have approved, they have not"
        />
        <Tile label="Granted" value={String(counts.granted)} tone="ok" foot="Both approvals in" />
        <Tile label="All requests" value={String(counts.total)} foot="Every record" />
      </div>

      {loading && <Empty icon="◔" title="Reading leave requests…" />}

      {!loading && !error && (
        <Card flush>
          {rows.length === 0 ? (
            <Empty icon="✓" title={filter === 'mine' ? 'Nothing waiting on HR' : 'No requests match'} />
          ) : (
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Request</th>
                    <th>Sales person</th>
                    <th>Date</th>
                    <th className="right">Days</th>
                    <th>Reason</th>
                    <th>Manager</th>
                    <th>HR</th>
                    <th>State</th>
                    <th className="right">Decide</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((l) => {
                    const stage = leaveStage(l);
                    const canAct = leaveNeedsDecisionFrom(l, 'hr');
                    return (
                      <tr key={l.id}>
                        <td className="mono small">{l.id}</td>
                        <td>
                          {l.person}
                          {l.requesterIsManager && (
                            <>
                              {' '}
                              <Badge tone="accent" title="A manager cannot approve their own leave">
                                manager
                              </Badge>
                            </>
                          )}
                        </td>
                        <td className="num">{formatDate(l.date)}</td>
                        <td className="right num">
                          {dupes.has(leaveKey(l)) ? <Badge tone="danger">dup?</Badge> : l.days}
                        </td>
                        <td className="dim small">{l.reason || '—'}</td>
                        <td>
                          {requiredApprovals(l).manager ? (
                            <ApprovalMark
                              done={managerHasApproved(l)}
                              by={l.managerApprovedBy ?? (l.managerApproved ? undefined : l.decidedBy)}
                              who={l.teamManager}
                            />
                          ) : (
                            <span className="dim small" title="A manager's own leave needs HR only">
                              not required
                            </span>
                          )}
                        </td>
                        <td>
                          <ApprovalMark done={hrHasApproved(l)} by={l.hrApprovedBy} who="HR" />
                        </td>
                        <td>
                          <StageBadge stage={stage} />
                        </td>
                        <td className="right">
                          {canAct ? (
                            <span className="lv__actions">
                              <Button
                                size="sm"
                                onClick={() => decide(l, true)}
                                loading={busy === l.id}
                                disabled={busy !== null}
                              >
                                Approve
                              </Button>
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => decide(l, false)}
                                disabled={busy !== null}
                              >
                                Reject
                              </Button>
                            </span>
                          ) : leaveCanRevoke(l, 'hr') ? (
                            <Button
                              size="sm"
                              variant="ghost"
                              onClick={() => revoke(l)}
                              loading={busy === l.id}
                              disabled={busy !== null}
                              title="Take back HR's approval and return this to pending"
                            >
                              Revoke
                            </Button>
                          ) : (
                            <span className="dim small">—</span>
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
      )}

      <p className="note" style={{ marginTop: 12 }}>
        Approving here records HR's decision only. If the manager has not approved yet the request
        stays open and the rep does not have the day — the two columns above show which side is
        outstanding.
      </p>
    </div>
  );
}

function ApprovalMark({ done, by, who }: { done: boolean; by?: string; who?: string }) {
  if (done) {
    return (
      <Badge tone="ok" title={by ? `Approved by ${by}` : undefined}>
        ✓ {by ? by.split('@')[0] : 'approved'}
      </Badge>
    );
  }
  return <span className="dim small">{who ? `${who} —` : '—'}</span>;
}

function StageBadge({ stage }: { stage: LeaveStage }) {
  const tone =
    stage === 'granted' ? 'ok' : stage === 'rejected' ? 'danger' : 'warn';
  return <Badge tone={tone}>{LEAVE_STAGE_LABEL[stage]}</Badge>;
}
