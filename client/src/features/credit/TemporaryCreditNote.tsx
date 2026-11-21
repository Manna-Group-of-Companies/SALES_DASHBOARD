/**
 * On an order's page: its 10-day payment commitment, if it has one (17 Nov
 * 2026), so whoever reads the order sees the promised date and whether it
 * was kept. Shows nothing when there is none, or this login may not see it.
 * (Named for the temporary credit extension it replaced; the two merged.)
 */
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { getOrderRoute, type OrderRoute } from '@/api/paymentCommitments';
import { Alert } from '@/components/ui';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (v: string) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v ?? '');
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : v;
};

export function TemporaryCreditNote({ orderId }: { orderId: string }) {
  const [r, setR] = useState<OrderRoute | null>(null);
  useEffect(() => {
    let live = true;
    if (!orderId) return;
    getOrderRoute(orderId)
      .then((x) => live && setR(x))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [orderId]);
  const c = r?.commitment;
  if (!c || c.status === 'Pending' || c.status === 'Cancelled') return null;
  const tone = c.status === 'Kept' ? 'ok' : c.status === 'Missed' ? 'danger' : 'warn';
  const what =
    c.status === 'Kept'
      ? 'kept'
      : c.status === 'Missed'
        ? 'missed'
        : c.status === 'Unchecked'
          ? 'payment pending, not yet checked in SAP'
          : 'payment pending';
  return (
    <Alert tone={tone} title={`Payment commitment to ${day(c.commitmentDate)}: ${what}`}>
      Given by the {c.approverRole === 'gm' ? 'GM' : 'Manager'}
      {c.remarks ? ` - “${c.remarks}”` : ''}. <Link to="/payment-commitments">Payment Commitments</Link>
    </Alert>
  );
}
