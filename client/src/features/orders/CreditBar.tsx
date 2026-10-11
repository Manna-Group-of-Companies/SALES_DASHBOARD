/**
 * How far an order takes a customer past their credit limit, drawn.
 *
 * The GM decides escalated orders on one question — how far over, and by how
 * much of it is this order — and the four figures in a table answer it only
 * after some arithmetic. The bar shows it at a glance: what is already owed,
 * what this order adds, and where the limit falls across them.
 *
 * Display only. The figures are `creditPicture`'s, passed in.
 */

import type { CreditPicture } from '@/domain/orderStatus';
import { moneyShort } from '@/components/common/format';
import './orders.css';

export function CreditBar({ picture, compact = false }: { picture: CreditPicture; compact?: boolean }) {
  const { outstanding, orderTotal, projected, creditLimit, over } = picture;
  // The scale runs to whichever is further right, plus a little air.
  const scale = Math.max(projected, creditLimit, 1) * 1.04;
  const pct = (n: number) => `${Math.max(0, Math.min(100, (n / scale) * 100))}%`;
  const usage = creditLimit > 0 ? Math.round((projected / creditLimit) * 100) : null;

  return (
    <div className={`cbar${compact ? ' cbar--compact' : ''}`}>
      <div
        className="cbar__track"
        role="img"
        aria-label={`Outstanding ${moneyShort(outstanding)}, this order ${moneyShort(orderTotal)}, limit ${
          creditLimit ? moneyShort(creditLimit) : 'not set'
        }`}
      >
        <span className="cbar__seg cbar__seg--owed" style={{ width: pct(outstanding) }} />
        <span className={`cbar__seg cbar__seg--order${over > 0 ? ' is-over' : ''}`} style={{ width: pct(orderTotal) }} />
        {creditLimit > 0 && (
          <span className="cbar__limit" style={{ left: pct(creditLimit) }}>
            <span className="cbar__limit-label">Limit {moneyShort(creditLimit)}</span>
          </span>
        )}
      </div>
      <div className="cbar__legend">
        <span>
          <i className="cbar__key cbar__key--owed" /> Owed {moneyShort(outstanding)}
        </span>
        <span>
          <i className={`cbar__key cbar__key--order${over > 0 ? ' is-over' : ''}`} /> This order {moneyShort(orderTotal)}
        </span>
        {usage != null && (
          <span className={`cbar__usage${usage > 100 ? ' is-over' : ''}`}>{usage}% of limit</span>
        )}
      </div>
    </div>
  );
}
