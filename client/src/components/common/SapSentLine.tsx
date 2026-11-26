/**
 * What a Sales Order says about SAP, on every list row and every order page:
 * Sent to SAP (or Waiting for SAP), who approved it, and SAP's numbers.
 * The rule is `sapSent` (`shared/fixtures/sap_sent.json`); the phone draws the
 * same line from its twin.
 */
import { sapSent, type SapSentInput } from '@/domain/sapSent';
import { Badge } from '@/components/ui';

export function SapSentLine({
  order,
  compact = false,
  numbers = true,
  className,
}: {
  order: SapSentInput;
  compact?: boolean;
  /** False where the same screen already shows the numbers in its own line. */
  numbers?: boolean;
  /** For the wrapper, so a row with nothing to say leaves no empty block. */
  className?: string;
}) {
  const s = sapSent(order);
  if (!s.label && !s.approvedBy && !s.status && !(numbers && s.numbers)) return null;
  return (
    <div className={className} style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center' }}>
      {s.label && (
        <Badge
          tone={s.sent ? 'ok' : 'warn'}
          dot
          title={
            s.sent
              ? 'SAP has written its order number back'
              : 'Approved and asked for - SAP has not sent its order number back yet'
          }
        >
          {s.label}
        </Badge>
      )}
      {s.approvedBy && (
        <Badge
          tone={s.approvedBy === 'GM Approved' ? 'accent' : 'info'}
          title={s.approvedBy === 'GM Approved' && order.gmApprovedBy ? `Approved by ${order.gmApprovedBy}` : undefined}
        >
          {s.approvedBy}
        </Badge>
      )}
      {/* Where the order is in SAP (26 Nov 2026): B1iF's word, or Hi-Tech's document state. */}
      {s.status && (
        <Badge
          tone={s.status === 'Dispatched' ? 'ok' : s.status === 'Cancelled' ? 'danger' : 'neutral'}
          title="SAP's status for this order"
        >
          SAP status: {s.status}
        </Badge>
      )}
      {numbers && s.numbers && (compact ? <b className="mono">{s.numbers}</b> : <span className="mono">SAP: <b>{s.numbers}</b></span>)}
    </div>
  );
}
