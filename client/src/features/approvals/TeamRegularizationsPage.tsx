/**
 * Attendance regularizations — the sales manager's queue.
 *
 * A rep's correction is decided by **their manager**, not by HR. HR sees every
 * regularization because they run payroll, but they may only act on a
 * *manager's own* request; the reverse holds here. `arQueueFor` encodes that,
 * and this screen only ever shows what this manager can actually decide —
 * listing work somebody cannot do is worse than not listing it.
 *
 * Scoped to the manager's own team on top of that. `team_manager` on the
 * request carries the short token (`Pareeth`), the same one that groups the
 * Sales Person tree.
 *
 * **What a regularization actually is**: a rep saying "my punch is wrong, it
 * should have been these times". Approving here also rewrites the attendance
 * log, in one action — they used to be two, which is how twelve approved
 * corrections ended up with the hours never moved. `completion_status` still
 * flags those older ones, because a day never written up counts as nothing.
 */

import { useEffect, useMemo, useState } from 'react';
import type { AttendanceRegularization, SalesPerson } from '@/domain/types';
import { arCanRevoke, arQueueFor, canDecideAr } from '@/domain/approvals';
import { clockOf } from '@/domain/attendance';
import { teamOf, teamTokenOf } from '@/domain/sales';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './approvals.css';

type Tab = 'pending' | 'decided' | 'all';

export function TeamRegularizationsPage() {
  const user = useAppSelector(selectUser);

  const [regs, setRegs] = useState<AttendanceRegularization[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [tab, setTab] = useState<Tab>('pending');
  const [rep, setRep] = useState('');
  const [remark, setRemark] = useState<Record<string, string>>({});
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.attendance.listRegularizations(), Api.attendance.listSalesPeople()])
      .then(([r, p]) => {
        if (!live) return;
        setRegs(r);
        setPeople(p);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read regularizations.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const myTeam = useMemo(() => teamOf(people, user?.salesPerson), [people, user]);
  const myToken = useMemo(() => {
    const me = people.find((p) => p.id === user?.salesPerson);
    return teamTokenOf(me);
  }, [people, user]);

  /**
   * This manager's own team only.
   *
   * Matched on the person first and the request's `team_manager` token second:
   * the token is what the mobile app stamps, but a rep moved between teams
   * leaves old requests carrying the previous manager's name.
   */
  const mine = useMemo(
    () =>
      regs.filter(
        (r) =>
          myTeam.includes(r.person) ||
          (myToken && r.teamManager?.toLowerCase() === myToken.toLowerCase()),
      ),
    [regs, myTeam, myToken],
  );

  const queue = useMemo(() => arQueueFor(mine, 'sales_manager'), [mine]);

  const rows = useMemo(() => {
    let list =
      tab === 'pending'
        ? queue
        : tab === 'decided'
          ? mine.filter((r) => r.status !== 'Pending Approval')
          : mine;
    if (rep) list = list.filter((r) => r.person === rep);
    return [...list].sort((a, b) => b.date.localeCompare(a.date));
  }, [mine, queue, tab, rep]);

  const repOptions = useMemo(
    () =>
      people
        .filter((p) => p.enabled && !p.isGroup && myTeam.includes(p.id))
        .sort((a, b) => a.name.localeCompare(b.name)),
    [people, myTeam],
  );

  /**
   * Approved, but the attendance log was never rewritten.
   *
   * Only legacy records now — approving does both in one action — but a day
   * never written up still counts as nothing, so they stay visible.
   */
  const stranded = useMemo(
    () => mine.filter((r) => r.status === 'Approved' && r.completionStatus !== 'Completed'),
    [mine],
  );

  const decide = async (ar: AttendanceRegularization, approve: boolean) => {
    setBusy(ar.id);
    setError(null);
    try {
      const saved = await Api.attendance.decideRegularization({
        id: ar.id,
        approve,
        by: user?.name ?? user?.email ?? 'sales manager',
        remarks: remark[ar.id],
      });
      setRegs((cur) => cur.map((r) => (r.id === ar.id ? saved : r)));
      setDone(
        approve
          ? `${ar.person}'s ${formatDate(ar.date)} correction approved.`
          : `${ar.person}'s ${formatDate(ar.date)} correction rejected.`,
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  const revoke = async (ar: AttendanceRegularization) => {
    setBusy(ar.id);
    setError(null);
    try {
      const saved = await Api.attendance.revokeRegularization({
        id: ar.id,
        by: user?.name ?? user?.email ?? 'sales manager',
      });
      setRegs((cur) => cur.map((r) => (r.id === ar.id ? saved : r)));
      setDone(`${ar.person}'s ${formatDate(ar.date)} correction returned to pending.`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not revoke the decision.');
    } finally {
      setBusy(null);
    }
  };

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Attendance Corrections</div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not load or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      {stranded.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title={`${stranded.length} approved but not applied`}>
            These days are not yet counted on the calendar or in payroll.
          </Alert>
        </div>
      )}

      <div className="cal__toolbar">
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
        <Segmented
          ariaLabel="Status"
          value={tab}
          onChange={setTab}
          options={[
            { value: 'pending', label: `Waiting (${queue.length})` },
            { value: 'decided', label: 'Decided' },
            { value: 'all', label: `All (${mine.length})` },
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Loading…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title={tab === 'pending' ? 'No corrections waiting' : 'No corrections'} />
      )}

      <div className="loc__grid">
        {rows.map((ar) => {
          const canDecide = canDecideAr(ar, 'sales_manager');
          const canUndo = arCanRevoke(ar, 'sales_manager');
          return (
            <Card
              key={ar.id}
              title={
                <span className="odo__title">
                  <span>{ar.person}</span>
                  <Badge
                    tone={
                      ar.status === 'Approved' ? 'ok' : ar.status === 'Rejected' ? 'danger' : 'warn'
                    }
                  >
                    {ar.status}
                  </Badge>
                </span>
              }
            >
              <table className="table loc__facts">
                <tbody>
                  <tr>
                    <td className="dim">Day</td>
                    <td>
                      <b>{formatDate(ar.date)}</b>
                    </td>
                  </tr>
                  <tr>
                    <td className="dim">Requested</td>
                    <td className="num">
                      {clockOf(ar.requestedPunchIn)} → {clockOf(ar.requestedPunchOut)}
                    </td>
                  </tr>
                  <tr>
                    <td className="dim">Reason</td>
                    <td>{ar.reason || <span className="dim">—</span>}</td>
                  </tr>
                  {ar.decidedBy && (
                    <tr>
                      <td className="dim">Decided by</td>
                      <td>{ar.decidedBy}</td>
                    </tr>
                  )}
                  {ar.status === 'Approved' && (
                    <tr>
                      <td className="dim">Attendance log</td>
                      <td>
                        {ar.completionStatus === 'Completed' ? (
                          <Badge tone="ok">Applied</Badge>
                        ) : (
                          <Badge tone="warn">Not applied</Badge>
                        )}
                      </td>
                    </tr>
                  )}
                  <tr>
                    <td className="dim">Record</td>
                    <td className="mono tiny dim">{ar.id}</td>
                  </tr>
                </tbody>
              </table>

              {canDecide && (
                <>
                  <Input
                    compact
                    placeholder="Remark for the rep (optional)"
                    value={remark[ar.id] ?? ''}
                    onChange={(e) => setRemark((c) => ({ ...c, [ar.id]: e.target.value }))}
                    aria-label={`Remark for ${ar.person}`}
                  />
                  <div className="loc__actions">
                    <Button size="sm" onClick={() => decide(ar, true)} loading={busy === ar.id} disabled={!!busy}>
                      Approve
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => decide(ar, false)} disabled={!!busy}>
                      Reject
                    </Button>
                  </div>
                </>
              )}

              {!canDecide && canUndo && (
                <div className="loc__actions">
                  <Button size="sm" variant="ghost" onClick={() => revoke(ar)} disabled={!!busy}>
                    Undo decision
                  </Button>
                </div>
              )}

              {!canDecide && !canUndo && ar.requesterIsManager && (
                <p className="small dim" style={{ marginTop: 10, marginBottom: 0 }}>
                  Handled by HR
                </p>
              )}
            </Card>
          );
        })}
      </div>
    </div>
  );
}
