/**
 * The minimum-stock ledger, visible to everyone (3.5).
 *
 * Reps read it to know what they can sell; the Production Manager reads it to
 * see what has fallen below threshold and raise a replenishment run; the Stock
 * Manager books completed runs back in. Because it is one ledger, an update by
 * any of them is visible to all the others on the next poll.
 */

import { useMemo, useState } from 'react';
import type { MinStockItem } from '@/domain/types';
import { CATEGORY_LABEL } from '@/domain/types';
import {
  availableQty,
  describeBatches,
  hasAgedStock,
  isBelowThreshold,
  stockLevel,
} from '@/domain/aging';
import { formatDate } from '@/domain/orderRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectMinStockItems, selectReservations, selectUser } from '@/store/selectors';
import { raiseReplenishment } from '@/store/slices/minStockSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Input,
  Meter,
  Modal,
  Tabs,
  type TabDef,
} from '@/components/ui';
import { relativeTime } from '@/components/common/format';
import { BatchBar } from './AgingPanel';

type View = 'all' | 'low' | 'aged';

export function MinStockPage() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const items = useAppSelector(selectMinStockItems);
  const reservations = useAppSelector(selectReservations);
  const lastSynced = useAppSelector((s) => s.minStock.lastSyncedAt);

  const [view, setView] = useState<View>('all');
  const [replenishing, setReplenishing] = useState<MinStockItem | null>(null);
  const [qty, setQty] = useState(0);

  const low = useMemo(() => items.filter(isBelowThreshold), [items]);
  const aged = useMemo(() => items.filter((i) => hasAgedStock(i)), [items]);

  const rows = view === 'low' ? low : view === 'aged' ? aged : items;

  const tabs: TabDef<View>[] = [
    { id: 'all', label: 'All items', count: items.length },
    { id: 'low', label: 'Below minimum', count: low.length },
    { id: 'aged', label: 'Has aged stock', count: aged.length },
  ];

  const canReplenish = user?.role === 'production_manager';

  const raise = async () => {
    if (!replenishing || !user || qty <= 0) return;
    const result = await dispatch(raiseReplenishment({ item: replenishing, qty, user }));
    if (raiseReplenishment.fulfilled.match(result)) {
      dispatch(
        pushToast(
          `Priority production order raised for ${replenishing.itemName} (${qty} ${replenishing.uom}).`,
          'success',
        ),
      );
      setReplenishing(null);
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Minimum stock</div>
          <div className="page-head__sub">
            Shared ledger · {lastSynced ? `synced ${relativeTime(lastSynced)}` : 'syncing…'}
          </div>
        </div>
      </div>

      {low.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <Alert
            tone="warn"
            title={`${low.length} item${low.length === 1 ? ' is' : 's are'} below minimum stock`}
            actions={
              view !== 'low' ? (
                <Button size="sm" onClick={() => setView('low')}>
                  Show them
                </Button>
              ) : undefined
            }
          >
            {canReplenish
              ? 'Raise a priority production order to replenish.'
              : 'The Production Manager has been alerted.'}
          </Alert>
        </div>
      )}

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={view} onChange={setView} />
        </div>

        {rows.length === 0 ? (
          <Empty icon="📦" title="Nothing here">
            Minimum-stock items are configured against the product master.
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Item</th>
                  <th className="right">On hand</th>
                  <th className="right">Booked</th>
                  <th className="right">Available</th>
                  <th className="right">Threshold</th>
                  <th style={{ width: 160 }}>Level</th>
                  <th style={{ minWidth: 220 }}>Batches</th>
                  {canReplenish && <th />}
                </tr>
              </thead>
              <tbody>
                {rows.map((item) => {
                  const below = isBelowThreshold(item);
                  const free = availableQty(item);
                  const holders = reservations.filter((r) => r.itemCode === item.itemCode);

                  return (
                    <tr key={item.itemCode}>
                      <td>
                        <div className="strong small">{item.itemName}</div>
                        <div className="tiny dim mono">
                          {item.itemCode} · {CATEGORY_LABEL[item.category]}
                        </div>
                        {item.replenishmentRaised && (
                          <div style={{ marginTop: 3 }}>
                            <Badge tone="info">Replenishment raised</Badge>
                          </div>
                        )}
                      </td>
                      <td className="right num">
                        {round(item.onHand)} {item.uom}
                      </td>
                      <td className="right num">
                        {item.reserved > 0 ? (
                          <span title={holders.map((h) => `${h.repName}: ${h.qty}`).join('\n')}>
                            {round(item.reserved)}
                            <div className="tiny dim">
                              {holders.length} rep{holders.length === 1 ? '' : 's'}
                            </div>
                          </span>
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right num strong">
                        <span style={{ color: free <= 0 ? 'var(--danger)' : undefined }}>
                          {round(free)}
                        </span>
                      </td>
                      <td className="right num dim">{round(item.threshold)}</td>
                      <td>
                        <Meter
                          value={stockLevel(item)}
                          tone={below ? 'danger' : stockLevel(item) < 1.2 ? 'warn' : 'ok'}
                          label={`Stock level for ${item.itemName}`}
                        />
                        <div className="tiny dim" style={{ marginTop: 3 }}>
                          {below ? (
                            <span style={{ color: 'var(--danger)', fontWeight: 600 }}>
                              {round(item.threshold - item.onHand)} {item.uom} short
                            </span>
                          ) : (
                            `${Math.round(stockLevel(item) * 100)}% of minimum`
                          )}
                        </div>
                      </td>
                      <td>
                        <div className="tiny">{describeBatches(item)}</div>
                        <BatchBar batches={item.batches} />
                        {item.lastRestockedOn && (
                          <div className="tiny dim" style={{ marginTop: 3 }}>
                            last restocked {formatDate(item.lastRestockedOn)}
                          </div>
                        )}
                      </td>
                      {canReplenish && (
                        <td className="right">
                          <Button
                            size="sm"
                            variant={below ? 'primary' : 'default'}
                            disabled={item.replenishmentRaised}
                            onClick={() => {
                              setReplenishing(item);
                              setQty(Math.max(0, Math.ceil(item.threshold * 1.5 - item.onHand)));
                            }}
                          >
                            Replenish
                          </Button>
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

      {replenishing && (
        <Modal
          title={`Raise replenishment — ${replenishing.itemName}`}
          onClose={() => setReplenishing(null)}
          footer={
            <>
              <Button onClick={() => setReplenishing(null)}>Cancel</Button>
              <Button variant="primary" disabled={qty <= 0} onClick={() => void raise()}>
                Raise priority production order
              </Button>
            </>
          }
        >
          <div className="stack gap-3">
            <Alert tone="info">
              The Stock Manager books the quantity back into this ledger once the run is complete,
              and every rep sees the new number immediately.
            </Alert>
            <div className="row gap-4">
              <Metric label="On hand" value={`${round(replenishing.onHand)} ${replenishing.uom}`} />
              <Metric label="Threshold" value={`${round(replenishing.threshold)} ${replenishing.uom}`} />
              <Metric
                label="Shortfall"
                value={`${round(Math.max(0, replenishing.threshold - replenishing.onHand))} ${replenishing.uom}`}
              />
            </div>
            <Field label="Quantity to produce" hint="Defaults to 150% of the threshold.">
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

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="detail-item__label">{label}</div>
      <div className="num" style={{ fontSize: 16, fontWeight: 650 }}>
        {value}
      </div>
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
