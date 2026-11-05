/**
 * Pick Lists — what the sales manager's reps picked from Hi-Tech's stock
 * (3 Nov 2026).
 *
 * A rep makes a pick list on the phone from a manager-approved order, ticking
 * only the products Hi-Tech has in stock; the rest stay on the order to be
 * picked later. This page lists every one for the manager's team, newest
 * first. Read-only: making and checking a list is the phone's and the
 * `manna_pick_list_submit` Server Script's job.
 */

import { useEffect, useMemo, useState } from 'react';
import { listPickLists, type PickList } from '@/api/pickLists';
import { Alert, Badge, Card, Empty, Input } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';

const qty = (v: number) => (Number.isInteger(v) ? String(v) : v.toFixed(2));

export function PickListsPage() {
  const [lists, setLists] = useState<PickList[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [query, setQuery] = useState('');

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listPickLists()
      .then((l) => {
        if (live) setLists(l);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error && e.message ? e.message : 'Could not read the pick lists.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return lists;
    return lists.filter((l) =>
      [l.name, l.salesOrder, l.customerName, l.salesPerson, ...l.items.map((i) => i.itemName)]
        .join(' ')
        .toLowerCase()
        .includes(q),
    );
  }, [lists, query]);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Pick Lists</div>
          <div className="tiny dim">
            What your reps picked from Hi-Tech stock on approved orders. The rest of each order stays to be picked later.
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not load the pick lists">
          {error}
        </Alert>
      )}

      {lists.length > 0 && (
        <div style={{ marginBottom: 12, maxWidth: 360 }}>
          <Input
            compact
            placeholder="Search customer, order, rep or product…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
      )}

      {!loading && !error && lists.length === 0 && <Empty icon="—" title="No pick lists yet" />}

      <div style={{ display: 'grid', gap: 12 }}>
        {shown.map((l) => (
          <Card
            key={l.name}
            title={
              <>
                {l.customerName} <span className="dim">· {l.salesOrder}</span>
              </>
            }
            actions={
              l.status === 'Submitted' ? <Badge tone="ok">{l.name}</Badge> : <Badge tone="danger">Cancelled</Badge>
            }
            flush
          >
            <div className="tiny dim" style={{ padding: '8px 16px 0' }}>
              {l.salesPerson} · {l.pickedOn.slice(0, 16)}
            </div>
            {l.sapError ? (
              <div className="tiny" style={{ padding: '4px 16px 0', color: 'var(--danger, #c0392b)' }}>
                SAP: {l.sapError}
              </div>
            ) : l.sapPickList ? (
              <div className="tiny dim" style={{ padding: '4px 16px 0' }}>
                SAP pick list {l.sapPickList}
                {l.hitechInvoice && <> · Hi-Tech invoice {l.hitechInvoice}</>}
                {l.mtGoodsReceipt && <> · goods receipt {l.mtGoodsReceipt}</>}
                {l.mtDelivery && <> · delivery {l.mtDelivery}</>}
              </div>
            ) : null}
            <div className="scroll-x">
              <table className="table">
                <thead>
                  <tr>
                    <th>Product</th>
                    <th className="right">Picked</th>
                    <th className="right">Kg</th>
                    <th className="right">Ordered</th>
                    <th className="right">Hi-Tech stock then</th>
                  </tr>
                </thead>
                <tbody>
                  {l.items.map((i) => (
                    <tr key={i.salesOrderItem}>
                      <td>{i.itemName}</td>
                      <td className="right">
                        <strong>
                          {qty(i.pickedQty)} {i.unit}
                        </strong>
                      </td>
                      <td className="right">{i.pickedKg > 0 ? qty(i.pickedKg) : '—'}</td>
                      <td className="right">{qty(i.orderedQty)}</td>
                      <td className="right dim">{qty(i.availableQty)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}
