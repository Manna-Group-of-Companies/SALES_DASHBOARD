/**
 * Temporary credit extensions (16 Nov 2026). A separate workflow from order
 * approval: on an order that takes a customer past their SAP credit limit,
 * the manager approves a temporary additional credit within their authority,
 * with a payment commitment of at most 10 days, and pushes it to SAP; the SAP
 * job counts the customer's payments and puts the limit back. A missed
 * commitment comes to the GM. The rule: domain/creditExtension.ts; enforced by
 * the manna_credit_extension Server Script.
 */
import { useEffect, useMemo, useState } from 'react';
import {
  actOnCreditExtension,
  getCreditExtension,
  listCreditExtensions,
  listEligibleOrders,
  requestCreditExtension,
  type CreditExtension,
  type EligibleOrder,
  type ExtensionDetail,
} from '@/api/creditExtensions';
import { XT, XT_MESSAGES, xtCheckGm, xtCheckManager } from '@/domain/creditExtension';
import { Alert, Badge, Button, Card, Empty, Input, Modal, Select, Skeleton, Tabs, Textarea } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '../accounts/accounts.css';

type Show = 'waiting' | 'running' | 'closed' | 'all';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (v: string) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : '';
};
const rs = (v: number) => `₹${Math.round(v).toLocaleString('en-IN')}`;
const iso = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const waiting = (x: CreditExtension) => x.canApprove || x.canReject || x.canEscalate || x.canRetry;
const RUNNING: string[] = [XT.pendingManager, XT.pendingGm, XT.sending, XT.pushFailed, XT.active, XT.overdue];

function StatusBadge({ status }: { status: string }) {
  const tone =
    status === XT.paid
      ? 'ok'
      : status === XT.rejected || status === XT.rejectedByGm || status === XT.overdue || status === XT.pushFailed
        ? 'danger'
        : status === XT.active || status === XT.sending
          ? 'info'
          : 'warn';
  return <Badge tone={tone}>{status}</Badge>;
}

const line = (k: string, v: string) =>
  v ? (
    <div className="ir-line">
      <span className="dim">{k}</span>
      <span>{v}</span>
    </div>
  ) : null;

export function CreditExtensionsPage() {
  const [rows, setRows] = useState<CreditExtension[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [show, setShow] = useState<Show>('waiting');
  const [rep, setRep] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [asking, setAsking] = useState(false);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listCreditExtensions()
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
        ? byRep.filter(waiting)
        : s === 'running'
          ? byRep.filter((r) => RUNNING.includes(r.status))
          : byRep.filter((r) => !RUNNING.includes(r.status));
  const shown = pick(show);
  const done = () => {
    setOpen(null);
    setAsking(false);
    setTick((t) => t + 1);
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Temporary Credit</div>
          <div className="tiny dim">
            Extra credit on an order over the limit, against a payment commitment of up to 10 days. A missed commitment goes
            to the GM.
          </div>
        </div>
        <Button onClick={() => setAsking(true)}>New request</Button>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      <Card flush>
        <div className="ir-tools">
          <Tabs<Show>
            tabs={[
              { id: 'waiting', label: 'Waiting for you', count: pick('waiting').length },
              { id: 'running', label: 'Open', count: pick('running').length },
              { id: 'closed', label: 'Closed', count: pick('closed').length },
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
                  <th>Order</th>
                  <th>Over limit by</th>
                  <th>Extra credit</th>
                  <th>Commitment</th>
                  <th>Paid</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.name}>
                    <td className="nowrap">{day(r.requestedOn)}</td>
                    <td className="nowrap">{r.salesPerson}</td>
                    <td>
                      {r.customerName}
                      <div className="tiny dim mono">{r.bpCode}</div>
                    </td>
                    <td className="nowrap">{r.salesOrder}</td>
                    <td className="nowrap">{rs(r.excess)}</td>
                    <td className="nowrap">{r.amount ? rs(r.amount) : '—'}</td>
                    <td className="nowrap">{day(r.commitmentDate) || '—'}</td>
                    <td className="nowrap">{r.amount ? `${rs(r.paid)} · ${r.paymentStatus}` : '—'}</td>
                    <td>
                      <StatusBadge status={r.status} />
                    </td>
                    <td className="right">
                      <Button size="sm" variant={waiting(r) ? 'primary' : 'default'} onClick={() => setOpen(r.name)}>
                        {waiting(r) ? 'Review' : 'View'}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {open && <ReviewModal name={open} onClose={() => setOpen(null)} onDone={done} />}
      {asking && <AskModal onClose={() => setAsking(false)} onDone={done} />}
    </div>
  );
}

function AskModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [orders, setOrders] = useState<EligibleOrder[] | null>(null);
  const [pick, setPick] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    listEligibleOrders()
      .then(setOrders)
      .catch((e: unknown) => setErr(e instanceof Error && e.message ? e.message : 'Could not load.'));
  }, []);

  async function send() {
    if (!pick) return setErr('Choose the order.');
    setBusy(true);
    setErr(null);
    try {
      await requestCreditExtension(pick, note.trim());
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not send.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal onClose={onClose} title="New temporary credit request">
      {err && <Alert tone="danger">{err}</Alert>}
      {orders === null ? (
        <Skeleton height={80} />
      ) : orders.length === 0 ? (
        <Empty title="No waiting order takes its customer past the credit limit" />
      ) : (
        <>
          <label className="tiny dim">Order over the credit limit</label>
          <Select value={pick} onChange={(e) => setPick(e.target.value)} disabled={busy}>
            <option value="">Choose…</option>
            {orders.map((o) => (
              <option key={o.salesOrder} value={o.salesOrder} disabled={o.hasRequest}>
                {o.customerName} · {o.salesOrder} · over by {rs(o.excess)}
                {o.hasRequest ? ' (already requested)' : ''}
              </option>
            ))}
          </Select>
          <label className="tiny dim" style={{ marginTop: 10, display: 'block' }}>
            What has the customer promised?
          </label>
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} disabled={busy} />
          <div className="ir-actions">
            <Button variant="primary" onClick={send} loading={busy}>
              Send request
            </Button>
          </div>
        </>
      )}
    </Modal>
  );
}

function ReviewModal({ name, onClose, onDone }: { name: string; onClose: () => void; onDone: () => void }) {
  const [d, setD] = useState<ExtensionDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState('');
  const [reason, setReason] = useState('');
  const [remarks, setRemarks] = useState('');

  useEffect(() => {
    getCreditExtension(name)
      .then((r) => {
        setD(r);
        if (!r.extension.requestReason.startsWith('Renewal of')) setReason(r.extension.requestReason);
      })
      .catch((e: unknown) => setErr(e instanceof Error && e.message ? e.message : 'Could not load.'));
  }, [name]);

  if (!d) {
    return (
      <Modal onClose={onClose} title="Temporary credit">
        {err ? <Alert tone="danger">{err}</Alert> : <Skeleton height={160} />}
      </Modal>
    );
  }
  const x = d.extension;
  const h = d.history;
  const today = iso(new Date());
  const maxDate = x.actor === 'gm' ? undefined : iso(new Date(Date.now() + 10 * 86_400_000));

  async function act(action: 'approve' | 'reject' | 'escalate' | 'retry') {
    setErr(null);
    const amt = Number(amount.replace(/,/g, '')) || 0;
    if (action === 'approve') {
      const problem =
        x.actor === 'gm'
          ? xtCheckGm({ amount: amt, today, commitment: date, remarks })
          : xtCheckManager({ amount: amt, authority: d!.managerAuthority, approvedOn: today, commitment: date, reason, remarks });
      if (problem) return setErr(XT_MESSAGES[problem]);
      if (
        !window.confirm(
          `${x.customerName}'s credit limit in SAP goes up by ${rs(amt)} until ${day(date)}, then back to what it was. Approve and push to SAP?`,
        )
      )
        return;
    }
    if (action === 'reject' && !remarks.trim()) return setErr('Enter the rejection remarks.');
    setBusy(action);
    try {
      await actOnCreditExtension(
        x.name,
        action,
        action === 'approve' ? { amount: amt, commitment_date: date, reason: reason.trim(), remarks: remarks.trim() } : { remarks: remarks.trim() },
      );
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not save.');
    } finally {
      setBusy(null);
    }
  }

  const deciding = x.canApprove || x.canReject || x.canEscalate;
  return (
    <Modal onClose={onClose} title={`Temporary credit · ${x.customerName}`}>
      <div className="ir-detail">
        {line('Request', `${x.name} · ${x.status}`)}
        {line('Customer', `${x.customerName} (${x.bpCode})`)}
        {line('SAP credit limit', rs(d.customer.credit_limit || x.creditLimit))}
        {line('Outstanding', rs(d.customer.outstanding || x.outstanding))}
        {line('Overdue', rs(d.customer.overdue || x.overdue))}
        {line('Order', `${x.salesOrder} · ${rs(x.orderAmount)}`)}
        {line('Excess credit', rs(x.excess))}
        {line('Rep', x.salesPerson)}
        {line("Rep's note", x.requestReason)}
        {line('Escalated', x.escalationReason)}
        {x.amount > 0 && line('Additional credit', `${rs(x.amount)} until ${day(x.commitmentDate)}`)}
        {x.amount > 0 && line('Approved', `${day(x.approvedOn)} · ${x.approverRole === 'gm' ? 'GM' : 'Manager'}${x.remarks ? ` — ${x.remarks}` : ''}`)}
        {x.amount > 0 && line('Paid (SAP)', `${rs(x.paid)} · ${x.paymentStatus} · ${rs(x.remaining)} remaining`)}
        {line('SAP', x.sapReference)}
        {line('Restore', x.restoreStatus ? `${x.restoreStatus}${x.restoreReference ? ` · ${x.restoreReference}` : ''}` : '')}
        {line('Rejected', x.rejectionRemarks)}
      </div>
      {x.sapError && <Alert tone="danger">SAP: {x.sapError}</Alert>}

      <div className="tiny dim" style={{ marginTop: 10 }}>
        This customer: {h.total_extensions ?? 0} extension(s) · {h.missed_commitments ?? 0} missed · {h.gm_escalations ?? 0} to the GM ·{' '}
        {rs(h.total_additional_credit ?? 0)} approved · {rs(h.total_paid_against_commitments ?? 0)} paid against them ·{' '}
        {h.total_extension_days ?? 0} day(s)
      </div>
      {(h.extensions ?? []).filter((e) => e.name !== x.name).length > 0 && (
        <div className="ir-detail" style={{ marginTop: 6 }}>
          {(h.extensions ?? [])
            .filter((e) => e.name !== x.name)
            .map((e) =>
              line(String(e.name), `${String(e.status)} · ${rs(Number(e.amount) || 0)} · ${day(String(e.approved_on ?? ''))}${Number(e.missed) ? ' · missed' : ''}`),
            )}
        </div>
      )}
      {d.payments.length > 0 && (
        <div className="ir-detail" style={{ marginTop: 6 }}>
          {d.payments.map((p) => line(day(p.date), `${rs(p.amount)} · SAP payment ${p.doc_num}`))}
        </div>
      )}
      {d.invoices.length > 0 && (
        <div className="ir-detail" style={{ marginTop: 6 }}>
          {d.invoices.slice(0, 8).map((i) => line(day(i.posting_date), `Invoice ${i.invoice_no} · ${rs(i.total)} · paid ${rs(i.paid)} · ${i.status}`))}
        </div>
      )}
      <div className="ir-detail" style={{ marginTop: 6 }}>
        {d.log.map((l) => line(day(l.at), `${l.action} · ${l.role}${l.remarks ? ` · ${l.remarks}` : ''}`))}
      </div>

      {err && <Alert tone="danger">{err}</Alert>}
      {deciding && (
        <>
          {x.canApprove && (
            <>
              <label className="tiny dim">
                Temporary additional credit (₹){x.actor === 'manager' ? ` — your authority ${rs(d.managerAuthority)}` : ''}
              </label>
              <Input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" disabled={!!busy} />
              <label className="tiny dim" style={{ marginTop: 8, display: 'block' }}>
                Payment commitment date{x.actor === 'manager' ? ' (at most 10 days)' : ''}
              </label>
              <Input type="date" value={date} min={today} max={maxDate} onChange={(e) => setDate(e.target.value)} disabled={!!busy} />
              <label className="tiny dim" style={{ marginTop: 8, display: 'block' }}>
                Reason for extension
              </label>
              <Input value={reason} onChange={(e) => setReason(e.target.value)} disabled={!!busy} />
            </>
          )}
          <label className="tiny dim" style={{ marginTop: 8, display: 'block' }}>
            Remarks (required)
          </label>
          <Textarea value={remarks} onChange={(e) => setRemarks(e.target.value)} rows={2} disabled={!!busy} />
          <div className="ir-actions">
            {x.canReject && (
              <Button onClick={() => act('reject')} loading={busy === 'reject'} disabled={!!busy}>
                Reject
              </Button>
            )}
            {x.canEscalate && (
              <Button onClick={() => act('escalate')} loading={busy === 'escalate'} disabled={!!busy}>
                Send to GM
              </Button>
            )}
            {x.canApprove && (
              <Button variant="primary" onClick={() => act('approve')} loading={busy === 'approve'} disabled={!!busy}>
                Approve & Push to SAP
              </Button>
            )}
          </div>
        </>
      )}
      {x.canRetry && (
        <div className="ir-actions">
          <Button variant="primary" onClick={() => act('retry')} loading={busy === 'retry'} disabled={!!busy}>
            Push to SAP again
          </Button>
        </div>
      )}
    </Modal>
  );
}
