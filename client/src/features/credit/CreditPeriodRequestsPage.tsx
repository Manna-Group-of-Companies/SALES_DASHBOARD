/**
 * Credit-period requests (16 Nov 2026). A rep asks on the phone for a
 * customer's new SAP payment term. Up to 30 days the team's manager approves
 * it here and pushes it to SAP; 31 to 40 days the manager escalates it (or
 * rejects it) and the GM approves and pushes it. The request moves to In SAP
 * by itself once the credit sync has changed the term in Manna Treads.
 * The rule: domain/creditPeriodRequest.ts; enforced by the Server Script.
 */
import { useEffect, useMemo, useState } from 'react';
import {
  actOnCreditPeriodRequest,
  listCreditPeriodRequests,
  type CreditPeriodRequest,
} from '@/api/creditPeriodRequests';
import { CPR_OPEN } from '@/domain/creditPeriodRequest';
import { Alert, Badge, Button, Card, Empty, Modal, Select, Skeleton, Tabs, Textarea } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '../accounts/accounts.css';

type Show = 'waiting' | 'open' | 'In SAP' | 'Rejected' | 'all';
type Act = 'approve' | 'reject' | 'escalate' | 'push';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (v: string) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : '';
};
const waitingOnMe = (r: CreditPeriodRequest) => r.canApprove || r.canReject || r.canEscalate || r.canPush;

function StatusBadge({ r }: { r: CreditPeriodRequest }) {
  const tone =
    r.label === 'In SAP' ? 'ok' : r.label === 'Rejected' ? 'danger' : r.label === 'Approved' || r.label === 'Sending to SAP' ? 'info' : 'warn';
  return <Badge tone={tone}>{r.label}</Badge>;
}

export function CreditPeriodRequestsPage() {
  const [rows, setRows] = useState<CreditPeriodRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [show, setShow] = useState<Show>('waiting');
  const [rep, setRep] = useState('');
  const [open, setOpen] = useState<CreditPeriodRequest | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listCreditPeriodRequests()
      .then((r) => live && setRows(r))
      .catch((e: unknown) => live && setError(e instanceof Error && e.message ? e.message : 'Could not load.'))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [tick]);

  const reps = useMemo(() => [...new Set(rows.map((r) => r.salesPerson).filter(Boolean))].sort(), [rows]);
  const byRep = rows.filter((r) => !rep || r.salesPerson === rep);
  const pick = (s: Show) =>
    s === 'all'
      ? byRep
      : s === 'waiting'
        ? byRep.filter(waitingOnMe)
        : s === 'open'
          ? byRep.filter((r) => (CPR_OPEN as string[]).includes(r.status))
          : byRep.filter((r) => r.status === s);
  const shown = pick(show);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Credit Period Requests</div>
          <div className="tiny dim">
            A customer&apos;s new payment term in SAP. Up to 30 days the manager decides and pushes it; 31&ndash;40 days
            go to the GM.
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      <Card flush>
        <div className="ir-tools">
          <Tabs<Show>
            tabs={[
              { id: 'waiting', label: 'Waiting for you', count: pick('waiting').length },
              { id: 'open', label: 'Open', count: pick('open').length },
              { id: 'In SAP', label: 'In SAP', count: pick('In SAP').length },
              { id: 'Rejected', label: 'Rejected', count: pick('Rejected').length },
              { id: 'all', label: 'All', count: byRep.length },
            ]}
            active={show}
            onChange={setShow}
          />
          <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Rep">
            <option value="">All reps</option>
            {reps.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </Select>
        </div>

        {loading && rows.length === 0 ? (
          <div style={{ padding: 16 }}>
            <Skeleton height={120} />
          </div>
        ) : shown.length === 0 ? (
          <Empty title={show === 'waiting' ? 'Nothing waiting for you' : 'No requests'} />
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Rep</th>
                  <th>Customer</th>
                  <th>Now</th>
                  <th>Asked for</th>
                  <th>Decides</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.name}>
                    <td className="nowrap">{day(r.requestedOn)}</td>
                    <td className="nowrap">{r.salesPerson}</td>
                    <td>{r.customerName}</td>
                    <td className="nowrap">{r.currentTerm || '—'}</td>
                    <td className="nowrap">
                      <strong>{r.requestedTerm}</strong>
                      <div className="tiny dim">{r.requestedDays} days</div>
                    </td>
                    <td className="nowrap">{r.needsGm ? 'GM' : 'Manager'}</td>
                    <td>
                      <StatusBadge r={r} />
                      {r.status === 'Approved' && r.sapError && <div className="tiny" style={{ color: 'var(--danger, #c62828)' }}>SAP refused</div>}
                    </td>
                    <td className="right">
                      <Button size="sm" variant={waitingOnMe(r) ? 'primary' : 'default'} onClick={() => setOpen(r)}>
                        {r.canPush ? 'Push to SAP' : r.canApprove || r.canEscalate || r.canReject ? 'Decide' : 'View'}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {open && (
        <RequestModal
          r={open}
          onClose={() => setOpen(null)}
          onDone={() => {
            setOpen(null);
            setTick((t) => t + 1);
          }}
        />
      )}
    </div>
  );
}

function RequestModal({ r, onClose, onDone }: { r: CreditPeriodRequest; onClose: () => void; onDone: () => void }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<Act | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const deciding = r.canApprove || r.canReject || r.canEscalate;

  async function act(a: Act) {
    if (a === 'reject' && !note.trim()) return setErr('Say why it is rejected.');
    if (
      a === 'push' &&
      !window.confirm(
        `${r.customerName}'s payment term in SAP (Manna Treads) becomes ${r.requestedTerm} (${r.requestedDays} days). The credit limit is not changed. Push it?`,
      )
    )
      return;
    setBusy(a);
    setErr(null);
    try {
      await actOnCreditPeriodRequest(r.name, a, note.trim());
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not save.');
    } finally {
      setBusy(null);
    }
  }

  const line = (k: string, v: string) =>
    v ? (
      <div className="ir-line">
        <span className="dim">{k}</span>
        <span>{v}</span>
      </div>
    ) : null;

  return (
    <Modal onClose={onClose} title={`Credit period · ${r.customerName}`}>
      <div className="ir-detail">
        {line('Request', r.name)}
        {line('Rep', r.salesPerson)}
        {line('Asked on', day(r.requestedOn))}
        {line('SAP code', r.bpCode)}
        {line('Now', r.currentTerm ? `${r.currentTerm}${r.currentDays ? ` (${r.currentDays} days)` : ''}` : 'no payment term')}
        {line('Asked for', `${r.requestedTerm} (${r.requestedDays} days)`)}
        {line('Decides', r.needsGm ? 'The GM (31–40 days), after the manager' : 'The manager (up to 30 days)')}
        {line('Reason', r.reason)}
        {line('Status', r.label)}
        {line('Sent to the GM', day(r.escalatedOn))}
        {line("Manager's note", r.managerNote)}
        {line(r.approverRole === 'gm' ? 'GM' : 'Decided', r.decidedOn ? `${day(r.decidedOn)}${r.decisionNote ? ` — ${r.decisionNote}` : ''}` : '')}
        {line('In SAP', r.sapPushedOn ? `${day(r.sapPushedOn)} · ${r.sapCompany} · was ${r.sapPreviousTerm || '—'}` : '')}
        {r.status === 'Sending to SAP' && line('SAP', 'Waiting for the credit sync. This changes by itself.')}
      </div>
      {r.status === 'Approved' && r.sapError && <Alert tone="danger">SAP: {r.sapError}</Alert>}
      {err && <Alert tone="danger">{err}</Alert>}
      {deciding && (
        <>
          <label className="tiny dim">
            {r.canEscalate ? 'Note (needed to reject; the rep sees it, the GM sees it if you send it on)' : 'Note (needed to reject; the rep sees it)'}
          </label>
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} disabled={!!busy} />
        </>
      )}
      {(deciding || r.canPush) && (
        <div className="ir-actions">
          {r.canReject && (
            <Button onClick={() => act('reject')} loading={busy === 'reject'} disabled={!!busy}>
              Reject
            </Button>
          )}
          {r.canEscalate && (
            <Button variant="primary" onClick={() => act('escalate')} loading={busy === 'escalate'} disabled={!!busy}>
              Send to GM
            </Button>
          )}
          {r.canApprove && (
            <Button variant="primary" onClick={() => act('approve')} loading={busy === 'approve'} disabled={!!busy}>
              Approve
            </Button>
          )}
          {r.canPush && (
            <Button variant="primary" onClick={() => act('push')} loading={busy === 'push'} disabled={!!busy}>
              Push to SAP
            </Button>
          )}
        </div>
      )}
    </Modal>
  );
}
