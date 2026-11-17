/**
 * On an order's page: the temporary credit extensions asked on it (17 Nov
 * 2026). The extension is a separate workflow and the order's own approval is
 * unchanged, so the manager or GM deciding the order would otherwise not know
 * that SAP's limit was raised for it, or that its commitment was missed.
 * Shows nothing when there are none, or when this login may not see them.
 */
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { listCreditExtensions, type CreditExtension } from '@/api/creditExtensions';
import { XT } from '@/domain/creditExtension';
import { Alert } from '@/components/ui';

const rs = (v: number) => `₹${Math.round(v).toLocaleString('en-IN')}`;

export function TemporaryCreditNote({ orderId }: { orderId: string }) {
  const [rows, setRows] = useState<CreditExtension[]>([]);
  useEffect(() => {
    let live = true;
    if (!orderId) return;
    listCreditExtensions({ salesOrder: orderId })
      .then((r) => live && setRows(r))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [orderId]);
  if (rows.length === 0) return null;
  return (
    <>
      {rows.map((x) => {
        const bad = x.status === XT.overdue || x.status === XT.rejectedByGm || x.status === XT.rejected || x.status === XT.pushFailed;
        return (
          <Alert key={x.name} tone={bad ? 'danger' : x.status === XT.active ? 'ok' : 'info'} title={`Temporary credit ${x.name}: ${x.status}`}>
            {x.amount > 0
              ? `${rs(x.amount)} extra in SAP until ${x.commitmentDate}; paid ${rs(x.paid)} (${x.paymentStatus}).`
              : `Asked; over the limit by ${rs(x.excess)}.`}{' '}
            <Link to="/credit-extensions">Open Temporary Credit</Link>
          </Alert>
        );
      })}
    </>
  );
}
