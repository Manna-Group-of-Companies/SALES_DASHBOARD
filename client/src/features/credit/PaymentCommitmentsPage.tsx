/**
 * Payment commitments (17 Nov 2026): every 10-day payment commitment given on
 * an order, by the Manager or the GM, and what became of it - the
 * customer-wise history the user asked for. Commitments are given on the
 * order itself (the Manager's Decision card, the GM's approval); this page is
 * where they are followed. It replaces the temporary credit extension's page:
 * the two were merged on the user's choice, and nothing here changes SAP.
 *
 * The rule is domain/paymentCommitment.ts; the manna_payment_commitment
 * Server Scripts enforce and track it.
 */
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  getCommitmentHistory,
  listCommitments,
  listLadderAlerts,
  markLadderAlertsSeen,
  type CommitmentHistory,
  type CommitmentRow,
  type LadderAlert,
} from '@/api/paymentCommitments';
import { PC } from '@/domain/paymentCommitment';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Modal, Select, Skeleton, Tabs } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import { ApprovalAuthorityModal } from './ApprovalAuthorityModal';
import '@/components/layout/layout.css';
import '../accounts/accounts.css';

type Show = 'open' | 'missed' | 'all';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (v: string) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v ?? '');
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : '';
};
const rs = (v: number) => `₹${Math.round(v).toLocaleString('en-IN')}`;
const OPEN: string[] = [PC.running, PC.unchecked];

function StatusBadge({ r }: { r: CommitmentRow }) {
  if (r.status === PC.kept) return <Badge tone="ok">Kept</Badge>;
  if (r.status === PC.missed) return <Badge tone="danger">{r.clearedOn ? 'Missed · cleared' : 'Missed'}</Badge>;
  if (r.status === PC.cancelled) return <Badge tone="neutral">Cancelled</Badge>;
  if (r.status === PC.unchecked) return <Badge tone="warn">Payment pending · not yet checked</Badge>;
  return <Badge tone="warn">Payment pending</Badge>;
}

export function PaymentCommitmentsPage() {
  const user = useAppSelector(selectUser);
  const [rows, setRows] = useState<CommitmentRow[]>([]);
  const [alerts, setAlerts] = useState<LadderAlert[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [show, setShow] = useState<Show>('open');
  const [customer, setCustomer] = useState('');
  const [alertsOpen, setAlertsOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [historyOf, setHistoryOf] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listCommitments()
      .then((r) => live && setRows(r))
      .catch((e: unknown) => live && setError(e instanceof Error && e.message ? e.message : 'Could not load.'))
      .finally(() => live && setLoading(false));
    // An alert that fails to load must not hide the commitments.
    listLadderAlerts()
      .then((a) => live && setAlerts(a))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [tick]);

  const customers = useMemo(
    () => [...new Map(rows.map((r) => [r.customer, r.customerName])).entries()].sort((a, b) => a[1].localeCompare(b[1])),
    [rows],
  );
  const byCustomer = rows.filter((r) => !customer || r.customer === customer);
  const pick = (s: Show) =>
    s === 'all'
      ? byCustomer
      : s === 'open'
        ? byCustomer.filter((r) => OPEN.includes(r.status))
        : byCustomer.filter((r) => r.status === PC.missed);
  const shown = pick(show);
  const unread = alerts.filter((a) => !a.read).length;
  const seen = () => {
    markLadderAlertsSeen()
      .then(() => setAlerts((a) => a.map((x) => ({ ...x, read: true }))))
      .catch(() => undefined);
  };
  const isGm = user?.role === 'general_manager';

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Payment Commitments</div>
          <div className="tiny dim">
            Orders of customers overdue more than 30 days past their terms, or over their credit limit, are approved
            with a payment commitment of up to 10 days. A missed commitment sends the customer&apos;s orders to the GM
            until the overdue is cleared.
          </div>
        </div>
        <Button variant={unread ? 'primary' : 'default'} onClick={() => setAlertsOpen((v) => !v)}>
          Alerts{unread ? ` (${unread})` : ''}
        </Button>
        <Button onClick={() => setSettingsOpen(true)}>Approval authority</Button>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      {alertsOpen && (
        <Card>
          {alerts.length === 0 ? (
            <Empty title="No alerts" />
          ) : (
            <>
              <div className="ir-detail">
                {alerts.map((a) => (
                  <div className="ir-line" key={a.name}>
                    <span className="dim nowrap">{day(a.at)}</span>
                    <span>
                      {!a.read && <Badge tone="warn">New</Badge>}{' '}
                      {a.doctype === 'Sales Order' ? (
                        <Link to={`${isGm ? '/gm' : ''}/orders/${a.docname}`}>{a.subject}</Link>
                      ) : (
                        a.subject
                      )}
                    </span>
                  </div>
                ))}
              </div>
              {unread > 0 && (
                <div className="ir-actions">
                  <Button size="sm" onClick={seen}>
                    Mark all read
                  </Button>
                </div>
              )}
            </>
          )}
        </Card>
      )}

      <Card flush>
        <div className="ir-tools">
          <Tabs<Show>
            tabs={[
              { id: 'open', label: 'Payment pending', count: pick('open').length },
              { id: 'missed', label: 'Missed', count: pick('missed').length },
              { id: 'all', label: 'All', count: byCustomer.length },
            ]}
            active={show}
            onChange={setShow}
          />
          <Select value={customer} onChange={(e) => setCustomer(e.target.value)} aria-label="Customer">
            <option value="">All customers</option>
            {customers.map(([id, name]) => (
              <option key={id} value={id}>
                {name}
              </option>
            ))}
          </Select>
        </div>

        {loading && rows.length === 0 ? (
          <div style={{ padding: 16 }}>
            <Skeleton height={120} />
          </div>
        ) : shown.length === 0 ? (
          <Empty title={show === 'open' ? 'No payment pending' : 'No commitments'} />
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Customer</th>
                  <th>Order</th>
                  <th>Given on</th>
                  <th>By</th>
                  <th>Days</th>
                  <th>Payment due</th>
                  <th>Outstanding / overdue then</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.name}>
                    <td>
                      {r.customerName}
                      <div className="tiny dim">{r.reason}</div>
                    </td>
                    <td className="nowrap">
                      <Link to={`${isGm ? '/gm' : ''}/orders/${r.salesOrder}`}>{r.salesOrder}</Link>
                      <div className="tiny dim">{rs(r.orderAmount)}</div>
                    </td>
                    <td className="nowrap">{day(r.approvedOn)}</td>
                    <td className="nowrap">{r.approverRole === 'gm' ? 'GM' : 'Manager'}</td>
                    <td className="nowrap">{r.days}</td>
                    <td className="nowrap">{day(r.commitmentDate)}</td>
                    <td className="nowrap">
                      {rs(r.outstandingAt)} / {rs(r.overdueAt)}
                      {r.overdueDaysAt > 0 && <div className="tiny dim">{r.overdueDaysAt} days late</div>}
                    </td>
                    <td>
                      <StatusBadge r={r} />
                      {r.keptOn && <div className="tiny dim">kept {day(r.keptOn)}</div>}
                      {r.missedOn && <div className="tiny dim">missed {day(r.missedOn)}</div>}
                    </td>
                    <td className="right">
                      <Button size="sm" onClick={() => setHistoryOf(r.customer)}>
                        History
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {settingsOpen && <ApprovalAuthorityModal onClose={() => setSettingsOpen(false)} />}
      {historyOf && <HistoryModal customer={historyOf} onClose={() => setHistoryOf(null)} />}
    </div>
  );
}

/** One customer's whole commitment history: counts, then every commitment. */
function HistoryModal({ customer, onClose }: { customer: string; onClose: () => void }) {
  const [h, setH] = useState<CommitmentHistory | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    getCommitmentHistory(customer)
      .then(setH)
      .catch((e: unknown) => setErr(e instanceof Error && e.message ? e.message : 'Could not load.'));
  }, [customer]);
  const name = h?.rows[0]?.customerName || customer;
  return (
    <Modal onClose={onClose} title={`Commitment history · ${name}`}>
      {err && <Alert tone="danger">{err}</Alert>}
      {!h ? (
        !err && <Skeleton height={120} />
      ) : (
        <>
          {h.gmLock && (
            <Alert tone="danger" title="Orders go to the GM">
              A missed commitment is not cleared yet.
            </Alert>
          )}
          <div className="ir-detail">
            <div className="ir-line">
              <span className="dim">Commitments given</span>
              <span>
                {h.given} ({h.byManager} by the Manager, {h.byGm} by the GM)
              </span>
            </div>
            <div className="ir-line">
              <span className="dim">Total days given</span>
              <span>{h.totalDays}</span>
            </div>
            <div className="ir-line">
              <span className="dim">Kept / missed / pending</span>
              <span>
                {h.kept} / {h.missed} / {h.running}
              </span>
            </div>
            <div className="ir-line">
              <span className="dim">Outstanding now</span>
              <span>
                {rs(h.outstandingNow)}
                {h.overdueNow > 1 && ` · ${rs(h.overdueNow)} overdue, oldest ${h.overdueDaysNow} days late`}
              </span>
            </div>
          </div>
          <div className="ir-detail" style={{ marginTop: 8 }}>
            {h.rows.map((r) => (
              <div className="ir-line" key={r.name}>
                <span className="dim nowrap">{day(r.approvedOn) || '—'}</span>
                <span>
                  {r.salesOrder} · {rs(r.orderAmount)} · {r.approverRole === 'gm' ? 'GM' : 'Manager'} ({r.approvedBy}) ·{' '}
                  {r.days} days to {day(r.commitmentDate)} · <StatusBadge r={r} />
                  {r.remarks && <div className="tiny dim">“{r.remarks}”</div>}
                </span>
              </div>
            ))}
          </div>
        </>
      )}
    </Modal>
  );
}
