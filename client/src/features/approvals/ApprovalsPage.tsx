/**
 * Phase 2 — Sales Manager approval queue (2.1 – 2.3).
 */

import { useState } from 'react';
import type { Order } from '@/domain/types';
import { effectiveDeliveryDate, formatDate } from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { useAppSelector } from '@/store/hooks';
import { selectCustomers, selectPendingApproval } from '@/store/selectors';
import { checkCredit } from '@/api/client';
import { Badge, Button, Card, Empty } from '@/components/ui';
import { money } from '@/components/common/format';
import { relativeTime } from '@/components/common/format';
import { ApprovalReviewModal } from './ApprovalReviewModal';

export function ApprovalsPage() {
  const pending = useAppSelector(selectPendingApproval);
  const customers = useAppSelector(selectCustomers);
  const [reviewing, setReviewing] = useState<Order | null>(null);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Approvals</div>
          <div className="page-head__sub">
            {pending.length} order{pending.length === 1 ? '' : 's'} waiting. Rates are locked
            permanently at approval.
          </div>
        </div>
      </div>

      {pending.length === 0 ? (
        <Card>
          <Empty icon="✅" title="Queue is clear">
            Nothing is waiting for your approval.
          </Empty>
        </Card>
      ) : (
        <Card flush>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Customer</th>
                  <th>Rep</th>
                  <th>Delivery</th>
                  <th className="right">Items</th>
                  <th className="right">Quoted value</th>
                  <th>Credit</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {pending.map((order) => {
                  const customer = customers.find((c) => c.id === order.customerId);
                  const value = orderTotal(order.items);
                  const credit = customer ? checkCredit(customer, value) : null;
                  return (
                    <tr key={order.id}>
                      <td>
                        <div className="mono small strong">{order.orderNo}</div>
                        <div className="tiny dim">{relativeTime(order.createdAt)}</div>
                      </td>
                      <td>
                        <div className="small">{order.customerName}</div>
                        <div className="tiny dim">{order.destination}</div>
                      </td>
                      <td className="small">{order.repName}</td>
                      <td className="small">{formatDate(effectiveDeliveryDate(order))}</td>
                      <td className="right num">{order.items.length}</td>
                      <td className="right num strong">{money(value)}</td>
                      <td>
                        {credit ? (
                          credit.breaches ? (
                            <Badge tone="danger">Over limit</Badge>
                          ) : credit.utilisation > 0.8 ? (
                            <Badge tone="warn">Tight</Badge>
                          ) : (
                            <Badge tone="ok">OK</Badge>
                          )
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right">
                        <Button size="sm" variant="primary" onClick={() => setReviewing(order)}>
                          Review
                        </Button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      {reviewing && (
        <ApprovalReviewModal
          order={reviewing}
          onClose={() => setReviewing(null)}
        />
      )}
    </div>
  );
}
