/**
 * Weekly compilation of dispatched orders (3.4).
 *
 * Dispatched orders are bucketed by customer and by week. Compiling a bucket
 * folds those orders into one group; the rep then sees a single expandable row
 * for the week on their order list.
 */

import { Fragment, useState } from 'react';
import { formatDate } from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  selectUser,
  selectWeeklyBuckets,
  selectWeeklyGroups,
} from '@/store/selectors';
import { compileWeeklyGroup } from '@/store/slices/ordersSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';

export function WeeklyCompilePage() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const buckets = useAppSelector(selectWeeklyBuckets);
  const groups = useAppSelector(selectWeeklyGroups);
  const saving = useAppSelector((s) => s.orders.saving);
  const [expanded, setExpanded] = useState<string | null>(null);

  if (!user) return null;

  const compile = async (index: number) => {
    const bucket = buckets[index];
    const result = await dispatch(compileWeeklyGroup({ bucket, user }));
    if (compileWeeklyGroup.fulfilled.match(result)) {
      dispatch(
        pushToast(
          `${bucket.orders.length} orders compiled for ${bucket.customerName}, week of ${formatDate(
            bucket.weekStart,
          )}.`,
          'success',
        ),
      );
    }
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Weekly compile</div>
          <div className="page-head__sub">
            Group a customer's dispatched orders for the week into one compiled order
          </div>
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <Alert tone="info">
          Only dispatched orders appear here. Once compiled, the rep sees the week as a single row
          they can expand to see every order inside.
        </Alert>
      </div>

      <div className="stack gap-4">
        <Card title={`Ready to compile (${buckets.length})`} flush>
          {buckets.length === 0 ? (
            <Empty icon="🗂" title="Nothing to compile">
              Dispatch some orders first — they will bucket by customer and week here.
            </Empty>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Customer</th>
                    <th>Week</th>
                    <th className="right">Orders</th>
                    <th className="right">Lines</th>
                    <th className="right">Value</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {buckets.map((bucket, i) => {
                    const key = `${bucket.customerId}-${bucket.weekStart}`;
                    const open = expanded === key;
                    return (
                      <Fragment key={key}>
                        <tr>
                          <td>
                            <button
                              className="btn btn--ghost btn--sm"
                              onClick={() => setExpanded(open ? null : key)}
                              style={{ marginRight: 6 }}
                              aria-label={open ? 'Collapse' : 'Expand'}
                            >
                              {open ? '▾' : '▸'}
                            </button>
                            <strong>{bucket.customerName}</strong>
                          </td>
                          <td className="small">
                            {formatDate(bucket.weekStart)} – {formatDate(bucket.weekEnd)}
                          </td>
                          <td className="right num">{bucket.orders.length}</td>
                          <td className="right num">
                            {bucket.orders.reduce((s, o) => s + o.items.length, 0)}
                          </td>
                          <td className="right num strong">{money(bucket.totalValue)}</td>
                          <td className="right">
                            <Button
                              size="sm"
                              variant="primary"
                              loading={saving}
                              onClick={() => void compile(i)}
                            >
                              Compile week
                            </Button>
                          </td>
                        </tr>
                        {open &&
                          bucket.orders.map((o) => (
                            <tr key={o.id}>
                              <td style={{ paddingLeft: 44 }} className="mono small">
                                {o.orderNo}
                              </td>
                              <td className="small dim">
                                dispatched {o.dispatchedAt ? formatDate(o.dispatchedAt.slice(0, 10)) : '—'}
                              </td>
                              <td />
                              <td className="right num">{o.items.length}</td>
                              <td className="right num">{money(orderTotal(o.items))}</td>
                              <td />
                            </tr>
                          ))}
                      </Fragment>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Card>

        <Card title={`Compiled groups (${groups.length})`} flush>
          {groups.length === 0 ? (
            <Empty icon="📚" title="No groups yet" />
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Customer</th>
                    <th>Week</th>
                    <th className="right">Orders</th>
                    <th className="right">Value</th>
                    <th>Compiled</th>
                  </tr>
                </thead>
                <tbody>
                  {groups.map((g) => (
                    <tr key={g.id}>
                      <td className="strong">{g.customerName}</td>
                      <td className="small">
                        {formatDate(g.weekStart)} – {formatDate(g.weekEnd)}
                      </td>
                      <td className="right num">{g.orderIds.length}</td>
                      <td className="right num strong">{money(g.totalValue)}</td>
                      <td className="small">
                        <Badge tone="ok">by {g.compiledBy}</Badge>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
