/**
 * Customers → Take Order (1.1). The entry point into the whole order flow.
 *
 * Outstanding balance and credit headroom are on the row rather than buried, so
 * a rep can see before they start that a customer is over their limit and the
 * manager will query the order (2.1).
 */

import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAppSelector } from '@/store/hooks';
import { selectCustomers, selectOrders, selectUser } from '@/store/selectors';
import { Badge, Button, Card, Empty, Input, Meter } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';

export function CustomersPage() {
  const navigate = useNavigate();
  const customers = useAppSelector(selectCustomers);
  const orders = useAppSelector(selectOrders);
  const user = useAppSelector(selectUser);
  const [search, setSearch] = useState('');

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return customers
      .filter((c) => !q || `${c.name} ${c.destination} ${c.gstin}`.toLowerCase().includes(q))
      .map((c) => ({
        customer: c,
        openOrders: orders.filter(
          (o) =>
            o.customerId === c.id &&
            o.status !== 'grouped' &&
            o.status !== 'rejected',
        ).length,
      }));
  }, [customers, orders, search]);

  const canTakeOrder = user?.role === 'sales_manager';

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Customers</div>
          <div className="page-head__sub">
            {customers.length} assigned · select one to take an order
          </div>
        </div>
        <Input
          placeholder="Search name, destination or GSTIN…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ maxWidth: 280 }}
        />
      </div>

      <Card flush>
        {rows.length === 0 ? (
          <Empty icon="👥" title="No customers">
            Customers arrive via the Excel import.
          </Empty>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Customer</th>
                  <th>Destination</th>
                  <th>GSTIN</th>
                  <th className="right">Outstanding</th>
                  <th style={{ width: 150 }}>Credit used</th>
                  <th className="right">Open orders</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map(({ customer, openOrders }) => {
                  const utilisation =
                    customer.creditLimit > 0
                      ? customer.outstandingBalance / customer.creditLimit
                      : 0;
                  const over = utilisation > 1;
                  return (
                    <tr key={customer.id}>
                      <td>
                        <div className="strong">{customer.name}</div>
                        <div className="tiny dim mono">{customer.id}</div>
                      </td>
                      <td className="small">{customer.destination}</td>
                      <td className="mono small">{customer.gstin || '—'}</td>
                      <td className="right num">{money(customer.outstandingBalance)}</td>
                      <td>
                        <Meter
                          value={utilisation}
                          tone={over ? 'danger' : utilisation > 0.8 ? 'warn' : 'ok'}
                          label={`Credit utilisation for ${customer.name}`}
                        />
                        <div className="tiny dim" style={{ marginTop: 3 }}>
                          {Math.round(utilisation * 100)}% of {moneyShort(customer.creditLimit)}
                          {over && (
                            <>
                              {' '}
                              <Badge tone="danger">Over limit</Badge>
                            </>
                          )}
                        </div>
                      </td>
                      <td className="right num">{openOrders || '—'}</td>
                      <td className="right">
                        {canTakeOrder && (
                          <Button
                            size="sm"
                            variant="primary"
                            onClick={() => navigate(`/orders/new/${customer.id}`)}
                          >
                            Take order
                          </Button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
