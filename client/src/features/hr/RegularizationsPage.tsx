/**
 * Attendance regularizations — all of them, but HR only decides some.
 *
 * A rep's missed punch is their manager's business: HR sees it, because HR
 * reconciles the log and runs payroll, but there is no decision for them to
 * make and therefore no buttons. Only a **manager's own** regularization comes
 * to HR, since a manager cannot approve themselves.
 *
 * The third tab is the one that matters most. A regularization can be
 * `Approved` and still `Not Completed` — the decision was made and the
 * attendance was never rewritten, so the rep is short hours somebody already
 * granted them. That is HR's work regardless of who approved it.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { AttendanceRegularization } from '@/domain/types';
import { arApprover, arCanRevoke, canDecideAr } from '@/domain/approvals';
import { clockOf } from '@/domain/attendance';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Segmented } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './attendance.css';

type Tab = 'mine' | 'all';

export function RegularizationsPage() {
  const user = useAppSelector(selectUser);
  const [ars, setArs] = useState<AttendanceRegularization[]>([]);
  const [tab, setTab] = useState<Tab>('mine');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => {
    setLoading(true);
    setError(null);
    Api.attendance
      .listRegularizations()
      .then(setArs)
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not read regularizations.'),
      )
      .finally(() => setLoading(false));
  };

  useEffect(load, []);

  const mine = useMemo(() => ars.filter((a) => canDecideAr(a, 'hr')), [ars]);

  const rows = useMemo(() => {
    if (tab === 'mine') return mine;
    return [...ars].sort((a, b) => b.date.localeCompare(a.date));
  }, [tab, ars, mine]);

  const revoke = async (ar: AttendanceRegularization) => {
    if (!user) return;
    setBusy(ar.id);
    try {
      const updated = await Api.attendance.revokeRegularization({ id: ar.id, by: user.email });
      setArs((cur) => cur.map((x) => (x.id === updated.id ? updated : x)));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not revoke the decision.');
    } finally {
      setBusy(null);
    }
  };

  const decide = async (ar: AttendanceRegularization, approve: boolean) => {
    if (!user) return;
    setBusy(ar.id);
    try {
      const updated = await Api.attendance.decideRegularization({
        id: ar.id,
        approve,
        by: user.email,
      });
      setArs((cur) => cur.map((x) => (x.id === updated.id ? updated : x)));
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
          <div className="page-head__title">Attendance regularizations</div>
          <div className="page-head__sub">
            Corrections to missed punches — HR decides only a manager's own
          </div>
        </div>
        <RefreshButton onClick={load} loading={loading} />
        <Segmented
          ariaLabel="View"
          value={tab}
          onChange={setTab}
          options={[
            { value: 'mine', label: `Needs HR (${mine.length})` },
            { value: 'all', label: `All (${ars.length})` },
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
          value={String(mine.length)}
          tone={mine.length ? 'warn' : undefined}
          foot="Managers' own requests"
        />
        <Tile
          label="With managers"
          value={String(ars.filter((a) => canDecideAr(a, 'sales_manager')).length)}
          foot="Not yours to decide"
        />
        <Tile label="All records" value={String(ars.length)} foot="Every regularization" />
      </div>

      {loading && <Empty icon="◔" title="Reading regularizations…" />}

      {!loading && !error && (
        <Card flush>
          {rows.length === 0 ? (
            <Empty
              icon="✓"
              title={
                tab === 'mine'
                  ? 'Nothing waiting on HR'
                  : 'No regularizations'
              }
            />
          ) : (
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Request</th>
                    <th>Sales person</th>
                    <th>Date</th>
                    <th className="right">Requested in</th>
                    <th className="right">Requested out</th>
                    <th>Reason</th>
                    <th>Decides</th>
                    <th>Status</th>
                    <th className="right">Action</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((ar) => {
                    const owner = arApprover(ar);
                    const canAct = canDecideAr(ar, 'hr');
                    return (
                      <tr key={ar.id}>
                        <td className="mono small">{ar.id}</td>
                        <td>
                          {ar.person}
                          {ar.requesterIsManager && (
                            <>
                              {' '}
                              <Badge tone="accent" title="A manager cannot approve their own">
                                manager
                              </Badge>
                            </>
                          )}
                        </td>
                        <td className="num">{formatDate(ar.date)}</td>
                        <td className="right num">{clockOf(ar.requestedPunchIn)}</td>
                        <td className="right num">{clockOf(ar.requestedPunchOut)}</td>
                        <td className="dim small">{ar.reason || '—'}</td>
                        <td className="dim small">
                          {owner === 'hr' ? 'HR' : ar.teamManager || 'Manager'}
                        </td>
                        <td>
                          <Badge
                            tone={
                              ar.status === 'Approved'
                                ? 'ok'
                                : ar.status === 'Rejected'
                                  ? 'danger'
                                  : 'warn'
                            }
                          >
                            {ar.status}
                          </Badge>
                        </td>
                        <td className="right">
                          {canAct ? (
                            <span className="lv__actions">
                              <Button
                                size="sm"
                                onClick={() => decide(ar, true)}
                                loading={busy === ar.id}
                                disabled={busy !== null}
                              >
                                Approve
                              </Button>
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => decide(ar, false)}
                                disabled={busy !== null}
                              >
                                Reject
                              </Button>
                            </span>
                          ) : arCanRevoke(ar, 'hr') ? (
                            <Button
                              size="sm"
                              variant="ghost"
                              onClick={() => revoke(ar)}
                              loading={busy === ar.id}
                              disabled={busy !== null}
                              title="Return this to pending"
                            >
                              Revoke
                            </Button>
                          ) : (
                            <Link to="/hr/calendar" className="small">
                              Calendar
                            </Link>
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
        <b>Approving writes the attendance log.</b> The requested punch times replace that day's
        record — creating it if the rep never punched at all — in the same action. If the write
        fails you will see the error here rather than a silent half-done approval.
      </p>
      <p className="note" style={{ marginTop: 8 }}>
        A rep's own regularization is decided by their team manager, so it appears here without
        buttons — visible because HR reconciles the log, not because it needs a decision. Only a
        manager's own request comes to HR.
      </p>
    </div>
  );
}
