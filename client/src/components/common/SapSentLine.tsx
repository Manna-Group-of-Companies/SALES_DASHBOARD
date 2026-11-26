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
  className,
}: {
  order: SapSentInput;
  compact?: boolean;
  /** For the wrapper, so a row with nothing to say leaves no empty block. */
  className?: string;
}) {
  const s = sapSent(order);
  if (!s.label && !s.approvedBy && !s.numbers) return null;
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
      {s.numbers && (compact ? <b className="mono">{s.numbers}</b> : <span className="mono">SAP: <b>{s.numbers}</b></span>)}
    </div>
  );
}
