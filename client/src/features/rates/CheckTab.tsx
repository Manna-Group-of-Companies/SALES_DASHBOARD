/**
 * Check against SAP. Dealer prices: one row per dealer with how many of their
 * prices are OK, drifted, missing or still a percentage — dealers needing
 * attention first, and by default only those; a dealer opens quality by
 * quality, a quality onto its items. Then Hi-Tech's price list: one row per
 * quality, each twin's price against Manna Treads' less the margin.
 *
 * The office server checks the same thing itself on every sync, with the
 * PowerShell twin of the rules; whether the two agree is said at the top.
 */

import { useState } from 'react';
import { Alert, Badge, Card, Segmented } from '@/components/ui';
import {
  hitechByQuality,
  type CheckDealer,
  type CheckStatus,
  type HitechStatus,
  type PricingSnapshot,
  type SapCheck,
  type ServerAgreement,
  type StatusCounts,
} from '@/domain/dealerRates';
import { ExpandRow, Paged, kindOf, matchItem, rs, useOpenSet } from './parts';

const TONE = { OK: 'ok', DRIFT: 'danger', MISSING: 'warn', KIND: 'warn' } as const;
const SAYS: Record<CheckStatus, string> = {
  OK: 'SAP price = list − rupees',
  DRIFT: 'SAP gives a different discount',
  MISSING: 'SAP has no price for this dealer and item',
  KIND: 'still a percentage in SAP, not a fixed price',
};
const LABEL: Record<CheckStatus, string> = { OK: 'OK', DRIFT: 'Drift', MISSING: 'Missing', KIND: 'Still %' };
const H_SAYS: Record<HitechStatus, string> = {
  OK: "Hi-Tech's price = Manna Treads' less the margin",
  DRIFT: "Hi-Tech's price is not Manna Treads' less the margin",
  MISSING: 'the Hi-Tech item has no price in this price list',
};

function Counts({ c, says = SAYS }: { c: Partial<Record<CheckStatus, number>>; says?: Partial<Record<CheckStatus, string>> }) {
  return (
    <span className="rates__chips">
      {(['OK', 'DRIFT', 'MISSING', 'KIND'] as const)
        .filter((s) => (c[s] ?? 0) > 0)
        .map((s) => (
          <Badge key={s} tone={TONE[s]} title={says[s]}>
            {c[s]} {LABEL[s]}
          </Badge>
        ))}
    </span>
  );
}

export function CheckTab({
  dealers,
  check,
  snapshot,
  margin,
  agreement,
}: {
  dealers: CheckDealer[];
  check: SapCheck;
  snapshot: PricingSnapshot;
  margin: number | null;
  agreement: ServerAgreement;
}) {
  const dOpen = useOpenSet<string>();
  const lOpen = useOpenSet<string>();
  const hOpen = useOpenSet<string>();
  const bad = dealers.filter((d) => d.bad > 0);
  const [scope, setScope] = useState<'attention' | 'all'>(bad.length ? 'attention' : 'all');
  const hitechBad = check.hitech.filter((r) => r.status !== 'OK');
  const [hScope, setHScope] = useState<'attention' | 'all'>(hitechBad.length ? 'attention' : 'all');
  const rows = scope === 'attention' ? bad : dealers;
  const total: StatusCounts = { OK: 0, DRIFT: 0, MISSING: 0, KIND: 0 };
  for (const d of dealers) for (const s of ['OK', 'DRIFT', 'MISSING', 'KIND'] as const) total[s] += d.counts[s];
  const hTotal: Partial<Record<CheckStatus, number>> = { OK: 0, DRIFT: 0, MISSING: 0 };
  for (const r of check.hitech) hTotal[r.status] = (hTotal[r.status] ?? 0) + 1;
  const hitechName = snapshot.hitech?.companyName ?? 'Hi-Tech Pretreads';
  const hitechGroups = hitechByQuality(snapshot, hScope === 'attention' ? hitechBad : check.hitech);

  return (
    <>
      {agreement.state === 'agree' && (
        <Alert tone="info">The office server checked SAP itself when it last read it, and counted exactly what this screen counts.</Alert>
      )}
      {agreement.state === 'stale' && (
        <Alert tone="info">
          The office server's own check is from before a change here ({agreement.why}). Press Sync from SAP and it checks again.
        </Alert>
      )}

      <Card
        title={`Dealer prices in Manna Treads' SAP, as read ${snapshot.syncedAt}`}
        actions={
          <Segmented
            ariaLabel="Which dealers"
            value={scope}
            onChange={setScope}
            options={[
              { value: 'attention', label: `Needs attention (${bad.length})` },
              { value: 'all', label: `All (${dealers.length})` },
            ]}
          />
        }
        flush
      >
        <div className="rates__pad rates__bar">
          <Counts c={total} />
          <span className="small dim">Anything not OK is fixed by confirming on the Preview tab and importing the files, then Sync from SAP.</span>
        </div>
        {rows.length === 0 ? (
          <div className="small dim rates__pad">{scope === 'attention' ? 'Every dealer price in SAP is right.' : 'No dealer has a discount yet.'}</div>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th className="right">Prices checked</th>
                  <th>Result</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((d) => (
                  <ExpandRow
                    key={d.cardCode}
                    open={dOpen.has(d.cardCode)}
                    onToggle={() => dOpen.toggle(d.cardCode)}
                    colSpan={4}
                    tone={d.bad > 0 ? 'warn' : undefined}
                    cells={
                      <>
                        <td>
                          <b>{d.cardName}</b>
                          <div className="tiny dim mono">{d.cardCode}</div>
                        </td>
                        <td className="right num">{d.lines.reduce((n, l) => n + l.rows.length, 0)}</td>
                        <td>
                          <Counts c={d.counts} />
                        </td>
                      </>
                    }
                  >
                    <table className="table rates__inner">
                      <thead>
                        <tr>
                          <th className="rates__chev" />
                          <th>Quality</th>
                          <th className="right">₹ off per kg</th>
                          <th className="right">Items</th>
                          <th>Result</th>
                        </tr>
                      </thead>
                      <tbody>
                        {d.lines.map((l) => {
                          const k = `${d.cardCode}|${l.propertyNo}`;
                          return (
                            <ExpandRow
                              key={k}
                              open={lOpen.has(k)}
                              onToggle={() => lOpen.toggle(k)}
                              colSpan={5}
                              tone={l.rows.length - l.counts.OK > 0 ? 'warn' : undefined}
                              cells={
                                <>
                                  <td>
                                    <b>{l.quality}</b>
                                  </td>
                                  <td className="right num">{rs(l.rupeesOff)}</td>
                                  <td className="right num">{l.rows.length}</td>
                                  <td>
                                    <Counts c={l.counts} />
                                  </td>
                                </>
                              }
                            >
                              <Paged
                                rows={[...l.rows].sort((a, b) => (a.status === 'OK' ? 1 : 0) - (b.status === 'OK' ? 1 : 0))}
                                match={(r, s) => matchItem(r.item, s) || r.status.toLowerCase().includes(s)}
                                placeholder="Filter items, or type drift / missing"
                                header={
                                  <tr>
                                    <th>Status</th>
                                    <th>Item</th>
                                    <th>Name</th>
                                    <th>Type</th>
                                    <th className="right">List</th>
                                    <th className="right">Should be</th>
                                    <th className="right">SAP price</th>
                                    <th className="right">SAP gives ₹ off</th>
                                  </tr>
                                }
                              >
                                {(r) => (
                                  <tr key={r.item.code}>
                                    <td>
                                      <Badge tone={TONE[r.status]} title={SAYS[r.status]}>
                                        {LABEL[r.status]}
                                      </Badge>
                                    </td>
                                    <td className="mono">{r.item.code}</td>
                                    <td>{r.item.name}</td>
                                    <td>{kindOf(r.item)}</td>
                                    <td className="right num">{rs(r.listPrice)}</td>
                                    <td className="right num">{rs(r.expected)}</td>
                                    <td className="right num">{rs(r.sapPrice)}</td>
                                    <td className="right num">{r.sapRupeesOff === null ? '—' : rs(r.sapRupeesOff)}</td>
                                  </tr>
                                )}
                              </Paged>
                            </ExpandRow>
                          );
                        })}
                      </tbody>
                    </table>
                  </ExpandRow>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <Card
        title={`${hitechName}'s price list against Manna Treads' ${margin ? `less ${rs(margin)}` : 'less the margin'}`}
        actions={
          <Segmented
            ariaLabel="Which Hi-Tech prices"
            value={hScope}
            onChange={setHScope}
            options={[
              { value: 'attention', label: `Needs attention (${hitechBad.length})` },
              { value: 'all', label: `All (${check.hitech.length})` },
            ]}
          />
        }
        flush
      >
        <div className="rates__pad rates__bar">
          <Counts c={hTotal} says={H_SAYS} />
          {check.noTwin.length > 0 && <span className="small dim">{check.noTwin.length} item(s) with no Hi-Tech twin are not checked.</span>}
        </div>
        {check.hitechSkipped ? (
          <div className="small dim rates__pad">Not checked: {check.hitechSkipped}.</div>
        ) : hitechGroups.length === 0 ? (
          <div className="small dim rates__pad">
            {hScope === 'attention' ? `Every ${hitechName} price is Manna Treads' less the margin.` : 'No item has a Hi-Tech twin.'}
          </div>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Quality</th>
                  <th className="right">Items</th>
                  <th>Result</th>
                </tr>
              </thead>
              <tbody>
                {hitechGroups.map((g) => {
                  const k = String(g.propertyNo);
                  const c: Partial<Record<CheckStatus, number>> = {};
                  for (const r of g.rows) c[r.status] = (c[r.status] ?? 0) + 1;
                  const notOk = g.rows.filter((r) => r.status !== 'OK').length;
                  return (
                    <ExpandRow
                      key={k}
                      open={hOpen.has(k)}
                      onToggle={() => hOpen.toggle(k)}
                      colSpan={4}
                      tone={notOk ? 'warn' : undefined}
                      cells={
                        <>
                          <td>
                            <b>{g.quality}</b>
                          </td>
                          <td className="right num">{g.rows.length}</td>
                          <td>
                            <Counts c={c} says={H_SAYS} />
                          </td>
                        </>
                      }
                    >
                      <Paged
                        rows={[...g.rows].sort((a, b) => (a.status === 'OK' ? 1 : 0) - (b.status === 'OK' ? 1 : 0))}
                        match={(r, s) => matchItem(r.item, s) || r.status.toLowerCase().includes(s)}
                        placeholder="Filter items, or type drift / missing"
                        header={
                          <tr>
                            <th>Status</th>
                            <th>Manna Treads item</th>
                            <th>Name</th>
                            <th>Type</th>
                            <th>Hi-Tech item</th>
                            <th className="right">Manna Treads price</th>
                            <th className="right">Should be</th>
                            <th className="right">Hi-Tech price</th>
                            <th className="right">Margin SAP gives</th>
                          </tr>
                        }
                      >
                        {(r) => (
                          <tr key={r.item.code}>
                            <td>
                              <Badge tone={TONE[r.status]} title={H_SAYS[r.status]}>
                                {LABEL[r.status]}
                              </Badge>
                            </td>
                            <td className="mono">{r.item.code}</td>
                            <td>{r.item.name}</td>
                            <td>{kindOf(r.item)}</td>
                            <td className="mono">{r.hitech.code}</td>
                            <td className="right num">{rs(r.treadsPrice)}</td>
                            <td className="right num">{rs(r.expected)}</td>
                            <td className="right num">{rs(r.sapPrice)}</td>
                            <td className="right num">{r.sapMargin === null ? '—' : rs(r.sapMargin)}</td>
                          </tr>
                        )}
                      </Paged>
                    </ExpandRow>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </>
  );
}
