/**
 * Check against SAP. Dealer prices: one row per dealer with how many of their
 * prices are OK, drifted, missing or still a percentage — dealers needing
 * attention first, and by default only those; a dealer opens quality by
 * group, a group onto its items. Then Hi-Tech's price list: one row per group
 * (item property), each twin's price against Manna Treads' less the margin.
 *
 * The office server checks the same thing itself on every sync, with the
 * PowerShell twin of the rules; whether the two agree is a badge beside the
 * dealer filter (a disagreement is also a banner over the whole page).
 */

import { useState } from 'react';
import { Badge, Card, Segmented } from '@/components/ui';
import {
  hitechByQuality,
  type CheckDealer,
  type CheckStatus,
  type HitechStatus,
  type PricingSnapshot,
  type SapCheck,
  type ServerAgreement,
} from '@/domain/dealerRates';
import { ExpandRow, Paged, kindOf, matchItem, rs, useOpenSet } from './parts';

const TONE = { OK: 'ok', DRIFT: 'danger', MISSING: 'warn', KIND: 'warn' } as const;
const SAYS: Record<CheckStatus, string> = {
  OK: 'SAP price = list − ₹/kg off',
  DRIFT: 'SAP price differs from list − ₹/kg off',
  MISSING: 'SAP has no price for this dealer and item',
  KIND: 'Still a percentage in SAP, not a fixed price',
};
const LABEL: Record<CheckStatus, string> = { OK: 'OK', DRIFT: 'Drift', MISSING: 'Missing', KIND: 'Still %' };
const H_SAYS: Record<HitechStatus, string> = {
  OK: "Hi-Tech's price = Manna Treads' less the margin",
  DRIFT: "Hi-Tech's price is not Manna Treads' less the margin",
  MISSING: 'The Hi-Tech item has no price in this price list',
};

/** Whether the office server's own check of SAP counted what this screen counts. */
function ServerVerdict({ agreement }: { agreement: ServerAgreement }) {
  if (agreement.state === 'agree')
    return (
      <Badge tone="ok" dot title="The office server's own check of SAP matches this screen.">
        Office server agrees
      </Badge>
    );
  if (agreement.state === 'stale')
    return (
      <Badge tone="neutral" dot title={`Out of date (${agreement.why}). Sync from SAP to recheck.`}>
        Office server check out of date
      </Badge>
    );
  if (agreement.state === 'disagree')
    return (
      <Badge tone="danger" dot title={agreement.differences.join(' · ')}>
        Office server disagrees
      </Badge>
    );
  return null;
}

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
  agreement,
}: {
  dealers: CheckDealer[];
  check: SapCheck;
  snapshot: PricingSnapshot;
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
  const hitechName = snapshot.hitech?.companyName ?? 'Hi-Tech Pretreads';
  const hitechGroups = hitechByQuality(snapshot, hScope === 'attention' ? hitechBad : check.hitech);

  return (
    <>
      <Card
        title="Dealer prices"
        actions={
          <div className="rates__bar">
            <ServerVerdict agreement={agreement} />
            <Segmented
              ariaLabel="Which dealers"
              value={scope}
              onChange={setScope}
              options={[
                { value: 'attention', label: `Needs attention (${bad.length})` },
                { value: 'all', label: `All (${dealers.length})` },
              ]}
            />
          </div>
        }
        flush
      >
        {rows.length === 0 ? (
          <div className="small dim rates__pad">{scope === 'attention' ? 'All dealer prices match SAP' : 'No dealer prices'}</div>
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
                          <th>Group</th>
                          <th className="right">₹/kg off list</th>
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
                                    <th className="right">SAP ₹/kg off</th>
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
        title={`${hitechName} prices`}
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
        {check.hitechSkipped ? (
          <div className="small dim rates__pad">Not checked: {check.hitechSkipped}.</div>
        ) : hitechGroups.length === 0 ? (
          <div className="small dim rates__pad">
            {hScope === 'attention' ? `All ${hitechName} prices match` : 'No Hi-Tech twins'}
          </div>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Group</th>
                  <th className="right">Items</th>
                  <th>Result</th>
                </tr>
              </thead>
              <tbody>
                {hitechGroups.map((g) => {
                  const k = g.key;
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
                            <th className="right">SAP margin</th>
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
