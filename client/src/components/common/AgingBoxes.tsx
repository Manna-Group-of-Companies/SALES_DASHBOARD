/**
 * A customer's outstanding, in SAP's four age buckets.
 *
 * One component, used wherever the outstanding is shown, so the four boxes
 * read identically on the order review, the customer list and the customer
 * detail. The phone shows the same four in the same order; the rules behind
 * them are in `domain/credit.ts`, paired with `app/lib/core/credit.dart`.
 *
 * Two states this must never blur:
 *
 *   - **Not synced.** SAP has not sent a breakdown, and four zeros beside a
 *     real balance would read as "nothing is overdue" — a statement nobody has
 *     the data to make. It says so instead.
 *   - **Doesn't add up.** The buckets and the balance disagree by more than
 *     rounding. Said out loud rather than smoothed over: it means the sync
 *     wrote one and not the other, and quietly picking a winner hides that for
 *     months.
 */

import {
  agingOf,
  bucketsOf,
  AGING_MISMATCH,
  AGING_NOT_SYNCED,
  AGING_NO_DATA,
  type CustomerRow,
} from '@/domain/credit';
import { money } from './format';
import './aging.css';

export function AgingBoxes({
  customer,
  compact = false,
}: {
  /** The raw customer row, or anything carrying the six fields. */
  customer: CustomerRow;
  /** Drops the total row — for a list, where the total is already a column. */
  compact?: boolean;
}) {
  const a = agingOf(customer);

  /*
   * An unsynced customer used to render as a single line of explanation and no
   * boxes at all. Since 21 August 2026 the boxes are always drawn, reading a
   * dash — a reader can then see WHICH bands are unknown, and the four labels
   * stay in the same place whether or not the sync has run, so a list does not
   * reflow row by row. The explanation still follows underneath.
   */
  return (
    <div className="aging">
      <div className="aging__boxes">
        {bucketsOf(a).map((b) => (
          <div
            key={b.key}
            className={`aging__box${b.overdue && a.bucketsKnown ? ' aging__box--overdue' : ''}`}
          >
            <span className="aging__label">{b.label}</span>
            <span className="aging__amount">
              {a.bucketsKnown ? money(b.amount, 0) : AGING_NO_DATA}
            </span>
          </div>
        ))}
      </div>

      {!a.bucketsKnown && <p className="aging__warn">{AGING_NOT_SYNCED}</p>}

      {!compact && (
        <div className="aging__foot">
          <span>Total outstanding</span>
          {/* The total is real even when the breakdown is not — SAP sends it
              separately, and dashing it out would hide a live balance. */}
          <b>{money(a.total, 0)}</b>
        </div>
      )}

      {a.mismatch && <p className="aging__warn">{AGING_MISMATCH}</p>}
    </div>
  );
}
