/**
 * The Production Manager's landing page.
 *
 * **The floor never learns who the customer is.** Every order on this page is
 * identified by number and destination, and the customer name is obtained
 * through `customerLabelFor` rather than read off the order — so a screen
 * cannot leak it by forgetting. The sales team asked for that boundary
 * explicitly; it is not a display preference.
 *
 * Note this is still the *view* holding the line. The stronger version strips
 * `customerName` in the API layer so a hidden field cannot be probed at all —
 * worth doing when this module moves onto the live site.
 *
 * As with the other dashboards: summarise and navigate, never decide. Stage
 * moves and acknowledgements happen on the production board, in one place.
 */

import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Order } from '@/domain/types';
import {
  customerLabelFor,
  effectiveDeliveryDate,
  formatDate,
  todayIso,
  unacknowledgedEdits,
  weekEndOf,
  weekStartOf,
} from '@/domain/orderRules';
import { useAppSelector } from '@/store/hooks';
import { selectProductionQueue, selectUser, selectVisibleOrders } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty } from '@/components/ui';
import { greeting } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { plural } from './dashboardRules';
import '@/components/layout/layout.css';
import './dashboard.css';

export function ProductionDashboardPage() {
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const queue = useAppSelector(selectProductionQueue);
  const visible = useAppSelector(selectVisibleOrders);

  const today = todayIso();
  const weekStart = weekStartOf(today);
  const weekEnd = weekEndOf(today);

  /**
   * Item changes made after approval that the floor has not acknowledged.
   * Work may already have started against the old quantities, so this outranks
   * everything else on the page.
   */
  const unacked = useMemo(
    () => visible.filter((o) => unacknowledgedEdits(o).length > 0),
    [visible],
  );

  const inProduction = useMemo(
    () => queue.filter((o) => o.status === 'in_production'),
    [queue],
  );

  const notStarted = useMemo(() => queue.filter((o) => o.status === 'approved'), [queue]);

  /** Everything due inside the current Monday–Sunday week, soonest first. */
  const dueThisWeek = useMemo(
    () =>
      queue
        .filter((o) => {
          const due = effectiveDeliveryDate(o);
          return due >= weekStart && due <= weekEnd;
        })
        .sort((a, b) => effectiveDeliveryDate(a).localeCompare(effectiveDeliveryDate(b))),
    [queue, weekStart, weekEnd],
  );

  /** Past its delivery date and still on the floor. */
  const overdue = useMemo(
    () => queue.filter((o) => effectiveDeliveryDate(o) < today),
    [queue, today],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {greeting()}, {user.name.split(' ')[0]}
          </div>
          <div className="page-head__sub">
            {formatDate(today)} · {queue.length} {plural(queue.length, 'order')} on the floor
          </div>
        </div>
      </div>

      {/* --- what cannot wait --------------------------------------------- */}
      <div className="stack gap-3" style={{ marginBottom: 16 }}>
        {unacked.length > 0 && (
          <Alert
            tone="danger"
            title={`${unacked.length} ${plural(unacked.length, 'order')} changed after approval`}
            actions={
              <Button size="sm" onClick={() => navigate('/production')}>
                Review on the board
              </Button>
            }
          >
            Quantities moved after the order was released to the floor. Acknowledge each one on the
            production board — work may already have started against the old figures.
          </Alert>
        )}
        {overdue.length > 0 && (
          <Alert tone="warn" title={`${overdue.length} past the delivery date`}>
            Still open after their due date. If a batch will not be ready, move the date on the
            order so the sales side sees it — production owns that date.
          </Alert>
        )}
      </div>

      {/* --- tiles -------------------------------------------------------- */}
      <div className="tiles">
        <Tile
          label="In production"
          value={String(inProduction.length)}
          foot="Work under way"
          onClick={() => navigate('/production')}
        />
        <Tile
          label="Not started"
          value={String(notStarted.length)}
          tone={notStarted.length ? 'warn' : undefined}
          foot="Approved, nothing moved yet"
          onClick={() => navigate('/production')}
        />
        <Tile
          label="Due this week"
          value={String(dueThisWeek.length)}
          foot={`${formatDate(weekStart)} – ${formatDate(weekEnd)}`}
          onClick={() => navigate('/production')}
        />
        <Tile
          label="Changes to acknowledge"
          value={String(unacked.length)}
          tone={unacked.length ? 'alert' : undefined}
          foot={unacked.length ? 'Must be acknowledged' : 'Nothing outstanding'}
          onClick={() => navigate('/production')}
        />
      </div>

      <div className="cols cols--sidebar">
        {/* --- the run order --------------------------------------------- */}
        <Card
          title="Due this week"
          actions={
            <Button size="sm" variant="ghost" onClick={() => navigate('/production')}>
              Production board →
            </Button>
          }
          flush
        >
          {dueThisWeek.length === 0 ? (
            <Empty icon="✓" title="Nothing due this week">
              Orders appear here once the Sales Manager releases them to the floor.
            </Empty>
          ) : (
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  {/* Destination, never the customer — see the note at the top. */}
                  <th>Destination</th>
                  <th className="right">Lines</th>
                  <th className="right">Due</th>
                </tr>
              </thead>
              <tbody>
                {dueThisWeek.slice(0, 8).map((o) => (
                  <FloorRow
                    key={o.id}
                    order={o}
                    label={customerLabelFor(o, user)}
                    today={today}
                    onOpen={() => navigate(`/orders/${o.id}`)}
                  />
                ))}
              </tbody>
            </table>
          )}
        </Card>

        {/* --- waiting to start ------------------------------------------ */}
        <Card title="Waiting to start">
          {notStarted.length === 0 ? (
            <Empty icon="✓" title="Everything released has been started" />
          ) : (
            <div className="stack gap-2">
              {notStarted.slice(0, 6).map((o) => (
                <button key={o.id} className="linkrow" onClick={() => navigate(`/orders/${o.id}`)}>
                  <span className="mono small">{o.orderNo}</span>
                  <span className="small dim">{customerLabelFor(o, user)}</span>
                  <Badge tone="neutral">{formatDate(effectiveDeliveryDate(o))}</Badge>
                </button>
              ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

function FloorRow({
  order,
  label,
  today,
  onOpen,
}: {
  order: Order;
  label: string;
  today: string;
  onOpen: () => void;
}) {
  const due = effectiveDeliveryDate(order);
  const late = due < today;
  return (
    <tr onClick={onOpen} style={{ cursor: 'pointer' }}>
      <td className="mono small">{order.orderNo}</td>
      <td className="small">{label}</td>
      <td className="right num">{order.items.length}</td>
      <td className="right num">
        <Badge tone={late ? 'danger' : 'neutral'}>{formatDate(due)}</Badge>
      </td>
    </tr>
  );
}
