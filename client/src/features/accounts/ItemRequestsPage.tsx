/**
 * The reps' item requests. The rep's manager (or the GM) approves a new one
 * first (12 Nov 2026); the accountant then creates the item in SAP and answers
 * with its code, or rejects - the accounts staff, from 12 Nov 2026 (the
 * accountant before; the accountant no longer has this page). HR sees the
 * same list, read-only.
 */
import { useEffect, useMemo, useState } from 'react';
import {
  WITH_ACCOUNTANT,
  WITH_MANAGER,
  accountantAnswers,
  approveItemRequest,
  decideItemRequest,
  itemRequestLabel,
  listItemRequests,
  type ItemRequest,
  type ItemRequestStatus,
} from '@/api/itemRequests';
import { Alert, Badge, Button, Card, Empty, Icon, Input, Modal, Select, Skeleton, Tabs, Textarea } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import '@/components/layout/layout.css';
import './accounts.css';

type Show = ItemRequestStatus | 'all';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (v: string) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : '';
};
const qty = (r: ItemRequest) => (r.quantity > 0 ? `${Number.isInteger(r.quantity) ? r.quantity : r.quantity.toFixed(2)} ${r.unit}`.trim() : '—');

export function ItemRequestsPage() {
  const [rows, setRows] = useState<ItemRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const role = useAppSelector(selectUser)?.role;
  // manna_item_request refuses anyone else's answer, so nobody else is offered one.
  // Accounts staff answer (12 Nov 2026; the accountant until then) - the only ones manna_item_request lets.
  const answersRequests = role === 'accounts_staff';
  const isManager = role === 'sales_manager' || role === 'general_manager';
  const [show, setShow] = useState<Show>(isManager ? WITH_MANAGER : WITH_ACCOUNTANT);
  const [rep, setRep] = useState('');
  const [open, setOpen] = useState<ItemRequest | null>(null);
  const canAnswer = (r: ItemRequest) => answersRequests && accountantAnswers(r.status);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listItemRequests()
      .then((r) => live && setRows(r))
      .catch((e: unknown) => live && setError(e instanceof Error && e.message ? e.message : 'Could not load.'))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [tick]);

  const reps = useMemo(() => [...new Set(rows.map((r) => r.salesPerson).filter(Boolean))].sort(), [rows]);
  const byRep = rows.filter((r) => !rep || r.salesPerson === rep);
  const shown = show === 'all' ? byRep : byRep.filter((r) => r.status === show);
  const count = (s: ItemRequestStatus) => byRep.filter((r) => r.status === s).length;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Item Requests</div>
          <div className="tiny dim">
            New products the reps asked for: the manager approves, then accounts make it in SAP
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      <Card flush>
        <div className="ir-tools">
          <Tabs<Show>
            tabs={[
              { id: WITH_MANAGER, label: 'With manager', count: count(WITH_MANAGER) },
              { id: WITH_ACCOUNTANT, label: 'With accountant', count: count(WITH_ACCOUNTANT) },
              { id: 'Done', label: 'Done', count: count('Done') },
              { id: 'Rejected', label: 'Rejected', count: count('Rejected') },
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
          <Empty title={show === WITH_MANAGER || show === WITH_ACCOUNTANT ? 'Nothing waiting' : 'No requests'} />
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Rep</th>
                  <th>Product</th>
                  <th>Pattern</th>
                  <th>Size</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.name}>
                    <td className="nowrap">{day(r.requestedOn)}</td>
                    <td className="nowrap">{r.salesPerson}</td>
                    <td className="nowrap">
                      {r.productLine}
                      <div className="tiny dim">{r.itemType}</div>
                    </td>
                    <td>{r.pattern || '—'}</td>
                    <td className="nowrap">{r.size || '—'}</td>
                    <td>
                      {r.status === 'Done' ? (
                        <>
                          <Badge tone="ok">Done</Badge>
                          <div className="tiny mono">{r.itemCode}</div>
                        </>
                      ) : r.status === 'Rejected' ? (
                        <Badge tone="danger">Rejected</Badge>
                      ) : (
                        <Badge tone="warn">{itemRequestLabel(r.status)}</Badge>
                      )}
                    </td>
                    <td className="right">
                      <Button
                        size="sm"
                        variant={canAnswer(r) || r.canApprove ? 'primary' : 'default'}
                        onClick={() => setOpen(r)}
                      >
                        {canAnswer(r) ? 'Answer' : r.canApprove ? 'Approve' : 'View'}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {open &&
        (open.canApprove ? (
          <ApproveModal
            r={open}
            onClose={() => setOpen(null)}
            onDone={() => {
              setOpen(null);
              setTick((t) => t + 1);
            }}
          />
        ) : (
          <AnswerModal
            r={open}
            readOnly={!canAnswer(open)}
            onClose={() => setOpen(null)}
            onDone={() => {
              setOpen(null);
              setTick((t) => t + 1);
            }}
          />
        ))}
    </div>
  );
}

function AnswerModal({
  r,
  readOnly,
  onClose,
  onDone,
}: {
  r: ItemRequest;
  readOnly: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const [code, setCode] = useState(r.itemCode);
  const [reply, setReply] = useState(r.reply);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function save(status: 'Done' | 'Rejected') {
    if (status === 'Done' && !code.trim()) return setErr('Enter the item code created in SAP.');
    if (status === 'Rejected' && !reply.trim()) return setErr('Say why it is rejected.');
    setBusy(true);
    setErr(null);
    try {
      await decideItemRequest(r.name, status, code.trim(), reply.trim());
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not save.');
    } finally {
      setBusy(false);
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
    <Modal onClose={onClose} title="Item request">
      <div className="ir-detail">
        {line('Rep', r.salesPerson)}
        {line('Date', day(r.requestedOn))}
        {line('Customer', r.customerName)}
        {line('Product', `${r.productLine} · ${r.itemType}`)}
        {line('Pattern', r.pattern)}
        {line('Size', r.size)}
        {line('Quantity', r.quantity > 0 ? qty(r) : '')}
        {line('Note', r.note)}
        {r.photo && (
          <a href={r.photo} target="_blank" rel="noreferrer" className="ir-photo">
            <Icon name="file" size={14} /> Photo
          </a>
        )}
        {line("Manager's note", r.managerNote)}
        {readOnly && line('Status', itemRequestLabel(r.status))}
        {readOnly && line('Item code', r.itemCode)}
        {readOnly && line('Reply', r.reply)}
      </div>
      {!readOnly && (
        <>
          {err && <Alert tone="danger">{err}</Alert>}
          <label className="tiny dim">Item code created in SAP</label>
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="e.g. PMD00101002" disabled={busy} />
          <label className="tiny dim" style={{ marginTop: 10, display: 'block' }}>
            Reply to the rep
          </label>
          <Textarea value={reply} onChange={(e) => setReply(e.target.value)} rows={2} disabled={busy} />
          <div className="ir-actions">
            <Button onClick={() => save('Rejected')} disabled={busy}>
              Reject
            </Button>
            <Button variant="primary" onClick={() => save('Done')} loading={busy}>
              Done
            </Button>
          </div>
        </>
      )}
    </Modal>
  );
}

/** The manager's (or the GM's) decision on a new request (12 Nov 2026). */
function ApproveModal({ r, onClose, onDone }: { r: ItemRequest; onClose: () => void; onDone: () => void }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function save(approve: boolean) {
    if (!approve && !note.trim()) return setErr('Say why it is rejected.');
    setBusy(true);
    setErr(null);
    try {
      await approveItemRequest(r.name, approve, note.trim());
      onDone();
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not save.');
    } finally {
      setBusy(false);
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
    <Modal onClose={onClose} title="Approve item request">
      <div className="ir-detail">
        {line('Rep', r.salesPerson)}
        {line('Date', day(r.requestedOn))}
        {line('Product', `${r.productLine} · ${r.itemType}`)}
        {line('Pattern', r.pattern)}
        {line('Size', r.size)}
        {line('Customer', r.customerName)}
        {line('Note', r.note)}
      </div>
      {err && <Alert tone="danger">{err}</Alert>}
      <label className="tiny dim">Note (needed to reject; the rep sees it)</label>
      <Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} disabled={busy} />
      <div className="ir-actions">
        <Button onClick={() => save(false)} disabled={busy}>
          Reject
        </Button>
        <Button variant="primary" onClick={() => save(true)} loading={busy}>
          Approve → accountant
        </Button>
      </div>
    </Modal>
  );
}
