/** Accountant: the reps' item requests. Create the item in SAP, then answer with its code, or reject. */
import { useEffect, useMemo, useState } from 'react';
import { decideItemRequest, listItemRequests, type ItemRequest, type ItemRequestStatus } from '@/api/itemRequests';
import { Alert, Badge, Button, Card, Empty, Icon, Input, Modal, Select, Skeleton, Tabs, Textarea } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
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
  const [show, setShow] = useState<Show>('Pending');
  const [rep, setRep] = useState('');
  const [open, setOpen] = useState<ItemRequest | null>(null);

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
          <div className="tiny dim">New products the reps asked for</div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      <Card flush>
        <div className="ir-tools">
          <Tabs<Show>
            tabs={[
              { id: 'Pending', label: 'Pending', count: count('Pending') },
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
          <Empty title={show === 'Pending' ? 'Nothing waiting' : 'No requests'} />
        ) : (
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Rep</th>
                  <th>Customer</th>
                  <th>Product</th>
                  <th>Pattern</th>
                  <th>Size</th>
                  <th className="right">Qty</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.name}>
                    <td className="nowrap">{day(r.requestedOn)}</td>
                    <td className="nowrap">{r.salesPerson}</td>
                    <td>{r.customerName || '—'}</td>
                    <td className="nowrap">
                      {r.productLine}
                      <div className="tiny dim">{r.itemType}</div>
                    </td>
                    <td>{r.pattern || '—'}</td>
                    <td className="nowrap">{r.size || '—'}</td>
                    <td className="right nowrap">{qty(r)}</td>
                    <td>
                      {r.status === 'Done' ? (
                        <>
                          <Badge tone="ok">Done</Badge>
                          <div className="tiny mono">{r.itemCode}</div>
                        </>
                      ) : r.status === 'Rejected' ? (
                        <Badge tone="danger">Rejected</Badge>
                      ) : (
                        <Badge tone="warn">Pending</Badge>
                      )}
                    </td>
                    <td className="right">
                      <Button size="sm" variant={r.status === 'Pending' ? 'primary' : 'default'} onClick={() => setOpen(r)}>
                        {r.status === 'Pending' ? 'Answer' : 'View'}
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
        <AnswerModal
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

function AnswerModal({ r, onClose, onDone }: { r: ItemRequest; onClose: () => void; onDone: () => void }) {
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
      </div>
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
    </Modal>
  );
}
