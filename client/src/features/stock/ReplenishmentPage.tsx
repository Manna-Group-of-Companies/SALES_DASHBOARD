/**
 * The replenishment loop (3.5).
 *
 * Production Manager raises a priority run → Stock Manager books the finished
 * quantity back into the ledger → the new number syncs to every rep and manager.
 * The book-in lands as a *new dated batch*, which is what keeps the aging split
 * ("8 from the older lot, 2 newly restocked") meaningful over time.
 */

import { useState } from 'react';
import type { ProductionOrder } from '@/domain/types';
import { formatDateTime } from '@/domain/orderRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectMinStockByCode, selectUser } from '@/store/selectors';
import { recordReplenishment } from '@/store/slices/minStockSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Input,
  Modal,
  Tabs,
  type TabDef,
} from '@/components/ui';
import { relativeTime } from '@/components/common/format';

type View = 'open' | 'completed';

export function ReplenishmentPage() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const orders = useAppSelector((s) => s.minStock.productionOrders);
  const minStockByCode = useAppSelector(selectMinStockByCode);

  const [view, setView] = useState<View>('open');
  const [booking, setBooking] = useState<ProductionOrder | null>(null);
  const [qty, setQty] = useState(0);

  const open = orders.filter((o) => o.status === 'open');
  const completed = orders.filter((o) => o.status === 'completed');
  const rows = view === 'open' ? open : completed;

  const tabs: TabDef<View>[] = [
    { id: 'open', label: 'Open runs', count: open.length },
    { id: 'completed', label: 'Completed', count: completed.length },
  ];

  const isStockManager = user?.role === 'stock_manager';

  const book = async () => {
    if (!booking || !user || qty <= 0) return;
    const result = await dispatch(
      recordReplenishment({
        itemCode: booking.itemCode,
        qty,
        user,
        productionOrderId: booking.id,
      }),
    );
    if (recordReplenishment.fulfilled.match(result)) {
      dispatch(
        pushToast(
          `${qty} booked into ${booking.itemName}. Every rep now sees the updated stock.`,
          'success',
        ),
      );
      setBooking(null);
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Replenishment</div>
          <div className="page-head__sub">
            {isStockManager
              ? 'Book completed production runs back into the minimum-stock ledger'
              : 'Priority runs raised against below-threshold items'}
          </div>
        </div>
      </div>

      {isStockManager && open.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="warn" title={`${open.length} run${open.length === 1 ? '' : 's'} awaiting book-in`}>
            Once you record the quantity, the minimum-stock list syncs to all sales reps and
            managers immediately.
          </Alert>
        </div>
      )}

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={view} onChange={setView} />
        </div>

        {rows.length === 0 ? (
          <Empty icon="↻" title={view === 'open' ? 'No open runs' : 'Nothing completed yet'}>
            {view === 'open'
              ? 'The Production Manager raises a run when an item falls below its threshold.'
              : 'Completed runs will be listed here.'}
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="right">Qty to produce</th>
                  <th className="right">Current on hand</th>
                  <th>Raised</th>
                  <th>Reason</th>
                  {view === 'open' && isStockManager && <th />}
                  {view === 'completed' && <th>Completed</th>}
                </tr>
              </thead>
              <tbody>
                {rows.map((o) => {
                  const stock = minStockByCode.get(o.itemCode);
                  return (
                    <tr key={o.id}>
                      <td>
                        <div className="strong small">{o.itemName}</div>
                        <div className="tiny dim mono">{o.itemCode}</div>
                      </td>
                      <td className="right num strong">
                        {o.qty} {stock?.uom ?? ''}
                      </td>
                      <td className="right num">
                        {stock ? (
                          <>
                            {round(stock.onHand)} {stock.uom}
                            {stock.onHand < stock.threshold && (
                              <div className="tiny" style={{ color: 'var(--danger)' }}>
                                below {round(stock.threshold)}
                              </div>
                            )}
                          </>
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="small">
                        {o.raisedBy}
                        <div className="tiny dim">{relativeTime(o.raisedAt)}</div>
                      </td>
                      <td>
                        <Badge tone={o.reason === 'replenishment' ? 'warn' : 'neutral'}>
                          {o.reason === 'replenishment' ? 'Below minimum' : 'Order-driven'}
                        </Badge>
                      </td>
                      {view === 'open' && isStockManager && (
                        <td className="right">
                          <Button
                            size="sm"
                            variant="primary"
                            onClick={() => {
                              setBooking(o);
                              setQty(o.qty);
                            }}
                          >
                            Book in
                          </Button>
                        </td>
                      )}
                      {view === 'completed' && (
                        <td className="small">
                          {o.completedAt ? formatDateTime(o.completedAt) : '—'}
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

      {booking && (
        <Modal
          title={`Book in — ${booking.itemName}`}
          onClose={() => setBooking(null)}
          footer={
            <>
              <Button onClick={() => setBooking(null)}>Cancel</Button>
              <Button variant="primary" disabled={qty <= 0} onClick={() => void book()}>
                Add to minimum stock
              </Button>
            </>
          }
        >
          <div className="stack gap-3">
            <Alert tone="info">
              This lands as a new dated batch, so the aging list keeps showing which stock is old
              and which is fresh.
            </Alert>
            <Field
              label="Quantity produced"
              hint={`Run was raised for ${booking.qty}. Enter what was actually made.`}
            >
              <Input
                numeric
                type="number"
                min={0}
                value={qty}
                onChange={(e) => setQty(Number(e.target.value) || 0)}
              />
            </Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
