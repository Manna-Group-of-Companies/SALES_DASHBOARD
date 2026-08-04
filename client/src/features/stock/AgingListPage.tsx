/**
 * The aging list as its own page (1.6) — browsed to find old stock worth
 * offering as a substitution before it goes stale.
 */

import { useNavigate } from 'react-router-dom';
import { AGE_BAND_LABEL, ageBand, batchAgeDays, sortedByAge } from '@/domain/aging';
import { formatDate } from '@/domain/orderRules';
import { useAppSelector } from '@/store/hooks';
import { selectAgingList, selectMinStockItems, selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { BatchBar } from './AgingPanel';

export function AgingListPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const items = useAppSelector(selectMinStockItems);
  const priority = useAppSelector(selectAgingList);

  // Only the Sales Manager can act on this directly; production reads it.
  const canTakeOrder = user?.role === 'sales_manager';

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Aging stock</div>
          <div className="page-head__sub">
            Oldest batches first — clear these before they go stale
          </div>
        </div>
        {canTakeOrder && <Button variant="primary" onClick={() => navigate('/customers')}>Take an order</Button>}
      </div>

      <div style={{ marginBottom: 14 }}>
        <Alert tone="info">
          Stock is tracked in dated batches. When a customer asks for an item, check whether an
          aged batch of the same product can be offered instead — confirm the substitution with
          them first.
        </Alert>
      </div>

      {priority.length === 0 ? (
        <Card>
          <Empty icon="🕰" title="No aged stock">
            Everything on the minimum-stock list has turned over recently.
          </Empty>
        </Card>
      ) : (
        <div className="stack gap-3">
          {priority.map(({ item, agedQty, oldestDays }) => {
            const batches = sortedByAge(item.batches);
            return (
              <Card
                key={item.itemCode}
                title={
                  <span className="row gap-2">
                    <span>{item.itemName}</span>
                    <Badge tone={oldestDays >= 120 ? 'danger' : 'warn'}>
                      oldest {oldestDays} days
                    </Badge>
                  </span>
                }
                actions={
                  <span className="small muted">
                    {round(agedQty)} of {round(item.onHand)} {item.uom} is aged
                  </span>
                }
              >
                <BatchBar batches={item.batches} />

                <div className="table-wrap" style={{ marginTop: 12 }}>
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Batch</th>
                        <th>Stocked on</th>
                        <th className="right">Age</th>
                        <th className="right">Remaining</th>
                        <th className="right">Original</th>
                        <th>Band</th>
                      </tr>
                    </thead>
                    <tbody>
                      {batches.map((b) => {
                        const band = ageBand(b);
                        return (
                          <tr key={b.id}>
                            <td className="mono small">{b.id}</td>
                            <td className="small">{formatDate(b.stockedOn)}</td>
                            <td className="right num">{batchAgeDays(b)} d</td>
                            <td className="right num strong">
                              {round(b.remaining)} {item.uom}
                            </td>
                            <td className="right num dim">{round(b.original)}</td>
                            <td>
                              <Badge
                                tone={
                                  band === 'stale'
                                    ? 'danger'
                                    : band === 'aged'
                                      ? 'warn'
                                      : band === 'aging'
                                        ? 'neutral'
                                        : 'ok'
                                }
                              >
                                {AGE_BAND_LABEL[band]}
                              </Badge>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </Card>
            );
          })}
        </div>
      )}

      {items.length === 0 && (
        <Card>
          <Empty icon="📦" title="No minimum-stock items configured" />
        </Card>
      )}
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
