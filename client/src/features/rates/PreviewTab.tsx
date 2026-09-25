/**
 * Preview & confirm. Opens on what confirming will do — counts, the files
 * company by company, the button — then summaries: Manna Treads' list prices by
 * quality, dealer prices by dealer (only dealers whose prices change, unless
 * asked for all), and Hi-Tech's prices by quality. Each summary row opens onto
 * its detail; a dealer opens quality by quality, and a quality onto its items.
 */

import { useState } from 'react';
import { Alert, Badge, Button, Card, Segmented } from '@/components/ui';
import {
  buildDtwFiles,
  hitechByQuality,
  roundMoney,
  type DealerSummary,
  type DtwFile,
  type PricingSnapshot,
  type QualitySummary,
  type RatesPlan,
  type RuleDiff,
} from '@/domain/dealerRates';
import { ExpandRow, Paged, download, kindOf, matchItem, range, rs, signed, useOpenSet } from './parts';
import type { Targets } from './RatesPage';

export interface Confirmed {
  files: DtwFile[];
  at: string;
  summary: string;
}

/** The files grouped by the company DTW must be logged in to, in import order. */
function byCompany(files: DtwFile[]): { company: string; companyName: string; files: DtwFile[] }[] {
  const out: { company: string; companyName: string; files: DtwFile[] }[] = [];
  for (const f of files) {
    const last = out[out.length - 1];
    if (last && last.company === f.company) last.files.push(f);
    else out.push({ company: f.company, companyName: f.companyName, files: [f] });
  }
  return out;
}

export function PreviewTab({
  snapshot,
  plan,
  targets,
  margin,
  qualities,
  dealers,
  ruleDiff,
  dirty,
  confirming,
  onConfirm,
  confirmed,
  onSync,
}: {
  snapshot: PricingSnapshot;
  plan: RatesPlan;
  targets: Targets;
  margin: number | null;
  qualities: QualitySummary[];
  dealers: DealerSummary[];
  ruleDiff: RuleDiff;
  dirty: boolean;
  confirming: boolean;
  onConfirm: () => void;
  confirmed: Confirmed | null;
  onSync: () => void;
}) {
  const qOpen = useOpenSet<number>();
  const dOpen = useOpenSet<string>();
  const lOpen = useOpenSet<string>();
  const oOpen = useOpenSet<string>();
  const hOpen = useOpenSet<string>();
  const [scope, setScope] = useState<'changing' | 'all'>('changing');
  const [hScope, setHScope] = useState<'changing' | 'all'>('changing');
  const [showProblems, setShowProblems] = useState(false);

  const files = buildDtwFiles(plan, { ...targets, currency: 'INR', stamp: 'preview' });
  const changingQualities = qualities.filter((q) => q.changedItems > 0);
  const priced = dealers.filter((d) => d.lines.length > 0);
  const changingDealers = priced.filter((d) => d.add + d.update > 0);
  const dealerRows = scope === 'changing' ? changingDealers : priced;
  const orphanDealers = dealers.filter((d) => d.orphans.length > 0);
  const ruleCount = ruleDiff.create.length + ruleDiff.update.length + ruleDiff.remove.length;
  const hitechName = snapshot.hitech?.companyName ?? 'Hi-Tech Pretreads';
  const hitechShown = hScope === 'changing' ? plan.hitechRows.filter((r) => r.action === 'UPDATE') : plan.hitechRows;
  const hitechGroups = hitechByQuality(snapshot, hitechShown);
  const problems = [...plan.problems, ...plan.hitechProblems];

  return (
    <>
      {confirmed && (
        <Card title={`Confirmed ${confirmed.at} — now import these in DTW`}>
          <p className="small" style={{ marginTop: 0 }}>
            {confirmed.summary}. Your browser downloaded the files; they are here too.
          </p>
          {confirmed.files.length === 0 ? (
            <p className="small">No DTW file was needed — SAP already matches.</p>
          ) : (
            <ol className="rates__steps">
              {byCompany(confirmed.files).map((g) => (
                <li key={g.company}>
                  Log in to DTW as <b>{g.company}</b> ({g.companyName}), then, in this order:
                  <ul className="rates__notes">
                    {g.files.map((f) => (
                      <li key={f.name}>
                        <b>{f.dtwObject}</b> · {f.dtwMode} · slot <b>{f.dtwSlot}</b> · {f.rows} row(s){' '}
                        <Button size="sm" variant="ghost" onClick={() => download(f.name, f.content)}>
                          {f.name}
                        </Button>
                      </li>
                    ))}
                  </ul>
                </li>
              ))}
              <li>
                In DTW, Simulate first, then Import. Each price-list pair (a + b) is one Items import. A file's name starts with the company it goes
                into — <b>treads-</b> for Manna Treads, <b>hitech-</b> for Hi-Tech Pretreads.
              </li>
              <li>
                Then{' '}
                <Button size="sm" onClick={onSync}>
                  Sync from SAP
                </Button>{' '}
                and open the Check tab: every row should read OK.
              </li>
            </ol>
          )}
        </Card>
      )}

      <Card title="What confirming will do">
        <div className="rates__tiles rates__tiles--tight">
          <Stat label="Manna Treads list prices" value={plan.counts.listChanges} hint={`in ${changingQualities.length} quality(ies)`} />
          <Stat label="Dealer prices added" value={plan.counts.add} />
          <Stat label="Dealer prices updated" value={plan.counts.update} hint={`${changingDealers.length} dealer(s) change`} />
          <Stat label={`${hitechName} prices`} value={plan.counts.hitech} hint={margin ? `at ${rs(margin)} less · ${plan.counts.hitechSame} already right` : 'margin not set'} />
          <Stat label="Already right" value={plan.counts.same} hint="dealer prices" />
          <Stat label="Dealer rules saved" value={ruleCount} hint={`${ruleDiff.create.length} new · ${ruleDiff.update.length} changed · ${ruleDiff.remove.length} removed`} />
        </div>
        <div className="small" style={{ margin: '10px 0' }}>
          {files.length
            ? byCompany(files).map((g) => (
                <div key={g.company}>
                  <b>{g.companyName}</b>: {g.files.map((f) => `${f.name.replace(/^(treads|hitech)-rates-preview-/, '')} (${f.rows} rows)`).join(' · ')}
                </div>
              ))
            : 'Files: none needed.'}
        </div>
        {plan.hitechSkipped && (
          <Alert tone="warn" title={`No ${hitechName} prices`}>
            {plan.hitechSkipped}.
          </Alert>
        )}
        {problems.length > 0 && (
          <Alert
            tone="warn"
            title={`${problems.length} row(s) are left out`}
            actions={
              <Button size="sm" variant="ghost" onClick={() => setShowProblems((s) => !s)}>
                {showProblems ? 'Hide' : 'Show'}
              </Button>
            }
          >
            {showProblems ? (
              <ul className="rates__notes">
                {problems.map((p, i) => (
                  <li key={i}>
                    {p.cardCode ? `${p.cardCode} · ` : ''}
                    {p.itemCode}: {p.message}
                  </li>
                ))}
              </ul>
            ) : (
              'Items with no list price, an item in two qualities, or a discount or margin as big as the price. They get no file row.'
            )}
          </Alert>
        )}
        <div className="rates__bar" style={{ marginTop: 12 }}>
          <Button variant="primary" disabled={!dirty} loading={confirming} onClick={onConfirm}>
            Confirm and download DTW files
          </Button>
          {!dirty && <span className="small dim">Nothing to confirm — SAP already matches the discounts and the margin, and no list price is being changed.</span>}
        </div>
      </Card>

      {changingQualities.length > 0 && (
        <Card title={`Manna Treads list prices by quality (${plan.counts.listChanges} items)`} flush>
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Quality</th>
                  <th className="right">Items changing</th>
                  <th className="right">Change</th>
                  <th className="right">Now</th>
                  <th className="right">New</th>
                </tr>
              </thead>
              <tbody>
                {changingQualities.map((q) => {
                  const rows = plan.listChanges.filter((c) => c.propertyNo === q.propertyNo);
                  return (
                    <ExpandRow
                      key={q.propertyNo}
                      open={qOpen.has(q.propertyNo)}
                      onToggle={() => qOpen.toggle(q.propertyNo)}
                      colSpan={6}
                      cells={
                        <>
                          <td>
                            <b>{q.name}</b>
                          </td>
                          <td className="right num">
                            {rows.length} of {q.items.length}
                          </td>
                          <td className="right num">
                            <b>{signed(q.change)}</b>
                          </td>
                          <td className="right num">{range(rows.map((r) => Number(r.oldPrice)))}</td>
                          <td className="right num">
                            <b>{range(rows.map((r) => r.newPrice))}</b>
                          </td>
                        </>
                      }
                    >
                      <Paged
                        rows={rows}
                        match={(r, s) => matchItem(r.item, s)}
                        placeholder={`Filter ${q.name} items`}
                        header={
                          <tr>
                            <th>Item</th>
                            <th>Name</th>
                            <th>Type</th>
                            <th className="right">Now</th>
                            <th className="right">New</th>
                            <th className="right">Change</th>
                          </tr>
                        }
                      >
                        {(c) => (
                          <tr key={c.item.code}>
                            <td className="mono">{c.item.code}</td>
                            <td>{c.item.name}</td>
                            <td>{kindOf(c.item)}</td>
                            <td className="right num">{rs(c.oldPrice)}</td>
                            <td className="right num">
                              <b>{rs(c.newPrice)}</b>
                            </td>
                            <td className="right num">{signed(c.delta)}</td>
                          </tr>
                        )}
                      </Paged>
                    </ExpandRow>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      <Card
        title={`Dealer prices by dealer — Manna Treads (${dealerRows.length})`}
        actions={
          <Segmented
            ariaLabel="Which dealers"
            value={scope}
            onChange={setScope}
            options={[
              { value: 'changing', label: `Changing (${changingDealers.length})` },
              { value: 'all', label: `All (${priced.length})` },
            ]}
          />
        }
        flush
      >
        {dealerRows.length === 0 ? (
          <div className="small dim rates__pad">
            {scope === 'changing' ? 'No dealer price changes. Switch to All to see every dealer.' : 'No dealer has a discount yet.'}
          </div>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th className="right">Qualities</th>
                  <th>Changing</th>
                  <th className="right">Unchanged</th>
                  <th className="right">New prices</th>
                </tr>
              </thead>
              <tbody>
                {dealerRows.map((d) => (
                  <ExpandRow
                    key={d.cardCode}
                    open={dOpen.has(d.cardCode)}
                    onToggle={() => dOpen.toggle(d.cardCode)}
                    colSpan={6}
                    tone={d.add + d.update > 0 ? 'changed' : undefined}
                    cells={
                      <>
                        <td>
                          <b>{d.cardName}</b>
                          <div className="tiny dim">
                            <span className="mono">{d.cardCode}</span>
                            {d.group ? ` · ${d.group}` : ''}
                          </div>
                        </td>
                        <td className="right num">{d.lines.length}</td>
                        <td>
                          <span className="rates__chips">
                            {d.add > 0 && <Badge tone="info">{d.add} added</Badge>}
                            {d.update > 0 && <Badge tone="warn">{d.update} updated</Badge>}
                            {d.add + d.update === 0 && <span className="tiny dim">none</span>}
                          </span>
                        </td>
                        <td className="right num">{d.same}</td>
                        <td className="right num">{range(d.prices)}</td>
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
                          <th>Changing</th>
                          <th className="right">Dealer pays</th>
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
                              colSpan={6}
                              tone={l.add + l.update > 0 ? 'changed' : undefined}
                              cells={
                                <>
                                  <td>
                                    <b>{l.quality}</b>
                                  </td>
                                  <td className="right num">{rs(l.rupeesOff)}</td>
                                  <td className="right num">{l.rows.length}</td>
                                  <td>
                                    <span className="rates__chips">
                                      {l.add > 0 && <Badge tone="info">{l.add} added</Badge>}
                                      {l.update > 0 && <Badge tone="warn">{l.update} updated</Badge>}
                                      {l.add + l.update === 0 && <span className="tiny dim">none</span>}
                                    </span>
                                  </td>
                                  <td className="right num">{range(l.rows.map((r) => r.newPrice))}</td>
                                </>
                              }
                            >
                              <Paged
                                rows={l.rows}
                                match={(r, s) => matchItem(r.item, s)}
                                placeholder={`Filter ${l.quality} items`}
                                header={
                                  <tr>
                                    <th>Item</th>
                                    <th>Name</th>
                                    <th>Type</th>
                                    <th className="right">List</th>
                                    <th className="right">In SAP now</th>
                                    <th className="right">New dealer price</th>
                                    <th className="right">Change</th>
                                    <th>Action</th>
                                  </tr>
                                }
                              >
                                {(r) => (
                                  <tr key={r.item.code} className={r.action !== 'same' ? 'rates__row--changed' : ''}>
                                    <td className="mono">{r.item.code}</td>
                                    <td>{r.item.name}</td>
                                    <td>{kindOf(r.item)}</td>
                                    <td className="right num">
                                      {rs(r.listPrice)}
                                      {r.listPriceNow !== r.listPrice && <div className="tiny dim">was {rs(r.listPriceNow)}</div>}
                                    </td>
                                    <td className="right num">
                                      {r.sapPrice === null ? <span className="dim">none</span> : rs(r.sapPrice)}
                                      {r.sapIsFixed === false && <div className="tiny dim">a percentage</div>}
                                    </td>
                                    <td className="right num">
                                      <b>{rs(r.newPrice)}</b>
                                      <div className="tiny dim">≈ {r.percent.toFixed(2)}% off</div>
                                    </td>
                                    <td className="right num">{r.sapPrice === null ? '' : signed(roundMoney(r.newPrice - r.sapPrice))}</td>
                                    <td>
                                      <Badge tone={r.action === 'ADD' ? 'info' : r.action === 'UPDATE' ? 'warn' : 'ok'}>
                                        {r.action === 'same' ? 'no change' : r.action.toLowerCase()}
                                      </Badge>
                                    </td>
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

      {snapshot.hitech && (
        <Card
          title={`${hitechName} ${snapshot.hitech.priceList.name} — Manna Treads' price ${margin ? `less ${rs(margin)}` : 'less the margin'} (${plan.counts.hitech} changing)`}
          actions={
            <Segmented
              ariaLabel="Which Hi-Tech prices"
              value={hScope}
              onChange={setHScope}
              options={[
                { value: 'changing', label: `Changing (${plan.counts.hitech})` },
                { value: 'all', label: `All (${plan.hitechRows.length})` },
              ]}
            />
          }
          flush
        >
          {hitechGroups.length === 0 ? (
            <div className="small dim rates__pad">
              {plan.hitechSkipped ?? (hScope === 'changing' ? `Every ${hitechName} price is already Manna Treads' less the margin.` : 'No item has a Hi-Tech twin.')}
            </div>
          ) : (
            <div className="table-wrap">
              <table className="table rates__table">
                <thead>
                  <tr>
                    <th className="rates__chev" />
                    <th>Quality</th>
                    <th className="right">Items</th>
                    <th className="right">Now</th>
                    <th className="right">New</th>
                  </tr>
                </thead>
                <tbody>
                  {hitechGroups.map((g) => {
                    const k = String(g.propertyNo);
                    const moving = g.rows.filter((r) => r.action === 'UPDATE').length;
                    return (
                      <ExpandRow
                        key={k}
                        open={hOpen.has(k)}
                        onToggle={() => hOpen.toggle(k)}
                        colSpan={5}
                        tone={moving ? 'changed' : undefined}
                        cells={
                          <>
                            <td>
                              <b>{g.quality}</b>
                            </td>
                            <td className="right num">
                              {g.rows.length}
                              {moving ? <div className="tiny dim">{moving} changing</div> : null}
                            </td>
                            <td className="right num">{range(g.rows.map((r) => Number(r.hitechNow)).filter((x) => x > 0))}</td>
                            <td className="right num">
                              <b>{range(g.rows.map((r) => r.newPrice))}</b>
                            </td>
                          </>
                        }
                      >
                        <Paged
                          rows={g.rows}
                          match={(r, s) => matchItem(r.item, s)}
                          placeholder={`Filter ${g.quality} items`}
                          header={
                            <tr>
                              <th>Manna Treads item</th>
                              <th>Name</th>
                              <th>Type</th>
                              <th>Hi-Tech item</th>
                              <th className="right">Manna Treads price</th>
                              <th className="right">Hi-Tech now</th>
                              <th className="right">Hi-Tech new</th>
                              <th>Action</th>
                            </tr>
                          }
                        >
                          {(r) => (
                            <tr key={r.item.code} className={r.action !== 'same' ? 'rates__row--changed' : ''}>
                              <td className="mono">{r.item.code}</td>
                              <td>{r.item.name}</td>
                              <td>{kindOf(r.item)}</td>
                              <td className="mono">{r.hitech.code}</td>
                              <td className="right num">{rs(r.treadsPrice)}</td>
                              <td className="right num">{r.hitechNow === null ? <span className="dim">none</span> : rs(r.hitechNow)}</td>
                              <td className="right num">
                                <b>{rs(r.newPrice)}</b>
                              </td>
                              <td>
                                <Badge tone={r.action === 'UPDATE' ? 'warn' : 'ok'}>{r.action === 'same' ? 'no change' : 'update'}</Badge>
                              </td>
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
          {plan.noTwin.length > 0 && (
            <div className="rates__pad">
              <Alert tone="info" title={`${plan.noTwin.length} Manna Treads item(s) have no Hi-Tech twin, so get no Hi-Tech price`}>
                A twin is the Hi-Tech item with the same code and the same name. {plan.noTwin.slice(0, 8).map((i) => i.twinNote ?? `${i.code} ${i.name}`).join(' · ')}
                {plan.noTwin.length > 8 ? ` · …and ${plan.noTwin.length - 8} more` : ''}
              </Alert>
            </div>
          )}
        </Card>
      )}

      {orphanDealers.length > 0 && (
        <Card title={`Dealer prices in Manna Treads' SAP with no discount behind them (${plan.orphans.length})`} flush>
          <div className="rates__pad">
            <Alert tone="warn">
              These stay in SAP — and keep giving their price — until deleted there: Inventory → Price Lists → Special Prices →
              Special Prices for Business Partners → the dealer → right-click the row → Delete Row. DTW cannot delete them.
            </Alert>
          </div>
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th className="right">Prices with no discount</th>
                </tr>
              </thead>
              <tbody>
                {orphanDealers.map((d) => (
                  <ExpandRow
                    key={d.cardCode}
                    open={oOpen.has(d.cardCode)}
                    onToggle={() => oOpen.toggle(d.cardCode)}
                    colSpan={3}
                    tone="warn"
                    cells={
                      <>
                        <td>
                          <b>{d.cardName}</b>
                          <div className="tiny dim mono">{d.cardCode}</div>
                        </td>
                        <td className="right num">{d.orphans.length}</td>
                      </>
                    }
                  >
                    <Paged
                      rows={d.orphans}
                      match={(o, s) => `${o.special.item} ${o.item?.name ?? ''}`.toLowerCase().includes(s)}
                      header={
                        <tr>
                          <th>Item</th>
                          <th>Name</th>
                          <th className="right">Price in SAP</th>
                          <th>Kind</th>
                        </tr>
                      }
                    >
                      {(o) => (
                        <tr key={o.special.item}>
                          <td className="mono">{o.special.item}</td>
                          <td>{o.item?.name ?? <span className="dim">not an item with a quality</span>}</td>
                          <td className="right num">{rs(o.special.price)}</td>
                          <td>{o.special.priceList === 0 ? 'fixed' : `${o.special.discount}% of price list ${o.special.priceList}`}</td>
                        </tr>
                      )}
                    </Paged>
                  </ExpandRow>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </>
  );
}

function Stat({ label, value, hint }: { label: string; value: number | string; hint?: string }) {
  return (
    <div className="rates__tile">
      <div className="rates__tile-label">{label}</div>
      <div className="rates__tile-value">{value}</div>
      {hint && <div className="rates__tile-hint">{hint}</div>}
    </div>
  );
}
