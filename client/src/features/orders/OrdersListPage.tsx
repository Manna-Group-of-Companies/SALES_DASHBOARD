/**
 * The order list.
 *
 * Weekly groups collapse into a single expandable row (3.4): once production has
 * compiled a customer's week, the list shows one line for the week and it can be
 * opened to see the individual orders inside.
 */

import { Fragment, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Order, OrderStatus } from '@/domain/types';
import { effectiveDeliveryDate, formatDate, formatDateTime } from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { useAppSelector } from '@/store/hooks';
import { selectVisibleOrders, selectWeeklyGroups } from '@/store/selectors';
import { Badge, Card, Empty, Input, Tabs, type TabDef } from '@/components/ui';
import { money } from '@/components/common/format';
import { FreezeChip, StatusBadge } from '@/components/common/StatusBadge';
import './orders.css';

type Filter = 'active' | 'pending' | 'production' | 'done' | 'all';

export function OrdersListPage() {
  const navigate = useNavigate();
  const orders = useAppSelector(selectVisibleOrders);
  const groups = useAppSelector(selectWeeklyGroups);

  const [filter, setFilter] = useState<Filter>('active');
  const [search, setSearch] = useState('');
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const matches = (o: Order, statuses: OrderStatus[]) => statuses.includes(o.status);

  const searched = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return orders;
    return orders.filter((o) =>
      `${o.orderNo} ${o.customerName} ${o.destination}`.toLowerCase().includes(q),
    );
  }, [orders, search]);

  const byFilter = useMemo(() => {
    switch (filter) {
      case 'active':
        return searched.filter((o) =>
          matches(o, ['pending_approval', 'approved', 'in_production']),
        );
      case 'pending':
        return searched.filter((o) => matches(o, ['pending_approval']));
      case 'production':
        return searched.filter((o) => matches(o, ['approved', 'in_production']));
      case 'done':
        return searched.filter((o) => matches(o, ['dispatched', 'grouped']));
      case 'all':
        return searched;
    }
  }, [searched, filter]);

  // Grouped orders roll up under their weekly compilation row.
  const { standalone, groupRows } = useMemo(() => {
    const grouped = byFilter.filter((o) => o.weeklyGroupId);
    const rest = byFilter.filter((o) => !o.weeklyGroupId);

    const rows = groups
      .map((g) => ({ group: g, orders: grouped.filter((o) => o.weeklyGroupId === g.id) }))
      .filter((r) => r.orders.length > 0);

    return { standalone: rest, groupRows: rows };
  }, [byFilter, groups]);

  const tabs: TabDef<Filter>[] = [
    { id: 'active', label: 'Active', count: orders.filter((o) => matches(o, ['pending_approval', 'approved', 'in_production'])).length },
    { id: 'pending', label: 'Awaiting approval', count: orders.filter((o) => o.status === 'pending_approval').length },
    { id: 'production', label: 'In production', count: orders.filter((o) => matches(o, ['approved', 'in_production'])).length },
    { id: 'done', label: 'Dispatched', count: orders.filter((o) => matches(o, ['dispatched', 'grouped'])).length },
    { id: 'all', label: 'All', count: orders.length },
  ];

  const toggle = (id: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            All orders
          </div>
          <div className="page-head__sub">{orders.length} total</div>
        </div>
        <Input
          placeholder="Search order no, customer…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ maxWidth: 260 }}
        />
      </div>

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={filter} onChange={setFilter} />
        </div>

        {standalone.length === 0 && groupRows.length === 0 ? (
          <Empty icon="📄" title="No orders here">
            Nothing matches this filter.
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Customer</th>
                  <th>Status</th>
                  <th>Delivery</th>
                  <th>Edit window</th>
                  <th className="right">Items</th>
                  <th className="right">Value</th>
                </tr>
              </thead>
              <tbody>
                {/* --- weekly compilations (3.4) ------------------------- */}
                {groupRows.map(({ group, orders: inner }) => {
                  const open = expanded.has(group.id);
                  return (
                    <Fragment key={group.id}>
                      <tr className="is-clickable" onClick={() => toggle(group.id)}>
                        <td>
                          <span aria-hidden style={{ marginRight: 6 }}>
                            {open ? '▾' : '▸'}
                          </span>
                          <strong>Week of {formatDate(group.weekStart)}</strong>
                          <div className="tiny dim">
                            {inner.length} order{inner.length === 1 ? '' : 's'} compiled
                          </div>
                        </td>
                        <td>{group.customerName}</td>
                        <td>
                          <Badge tone="neutral" dot>
                            Weekly group
                          </Badge>
                        </td>
                        <td className="small">
                          {formatDate(group.weekStart)} – {formatDate(group.weekEnd)}
                        </td>
                        <td className="dim small">Closed</td>
                        <td className="right num">
                          {inner.reduce((s, o) => s + o.items.length, 0)}
                        </td>
                        <td className="right num strong">{money(group.totalValue)}</td>
                      </tr>

                      {open &&
                        inner.map((o) => (
                          <tr
                            key={o.id}
                            className="is-clickable"
                            onClick={() => navigate(`/orders/${o.id}`)}
                          >
                            <td style={{ paddingLeft: 34 }}>
                              <span className="mono small">{o.orderNo}</span>
                            </td>
                            <td className="small dim">{o.destination}</td>
                            <td>
                              <StatusBadge status={o.status} />
                            </td>
                            <td className="small">{formatDate(effectiveDeliveryDate(o))}</td>
                            <td className="dim small">—</td>
                            <td className="right num">{o.items.length}</td>
                            <td className="right num">{money(orderTotal(o.items))}</td>
                          </tr>
                        ))}
                    </Fragment>
                  );
                })}

                {/* --- ordinary orders ---------------------------------- */}
                {standalone.map((o) => (
                  <tr
                    key={o.id}
                    className="is-clickable"
                    onClick={() => navigate(`/orders/${o.id}`)}
                  >
                    <td>
                      <div className="mono small strong">{o.orderNo}</div>
                      <div className="tiny dim">{formatDateTime(o.createdAt)}</div>
                    </td>
                    <td>
                      <div className="small">{o.customerName}</div>
                      <div className="tiny dim">{o.destination}</div>
                    </td>
                    <td>
                      <StatusBadge status={o.status} />
                    </td>
                    <td className="small">
                      {formatDate(effectiveDeliveryDate(o))}
                      {o.revisedDeliveryDate && (
                        <div className="tiny" style={{ color: 'var(--warn)' }}>
                          moved from {formatDate(o.deliveryDate)}
                        </div>
                      )}
                    </td>
                    <td>
                      <FreezeChip order={o} />
                    </td>
                    <td className="right num">{o.items.length}</td>
                    <td className="right num strong">{money(orderTotal(o.items))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
