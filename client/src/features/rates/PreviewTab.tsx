/**
 * Preview & confirm. Opens on what confirming will do — one sentence and the
 * button; the files are at most three CSVs (Manna Treads' price list, Manna
 * Treads' dealer prices, Hi-Tech's price list) — then: Manna Treads' list prices
 * by group, dealer prices by dealer (only dealers whose prices change, unless
 * asked for all), and Hi-Tech's prices by group. A group is an item property,
 * "HOT - Black Pearl". Each summary row opens onto its detail; a dealer opens
 * group by group, and a group onto its items.
 */

import { useState } from 'react';
import { Alert, Badge, Button, Card, Segmented } from '@/components/ui';
import {
  buildDtwFiles,
  hitechByQuality,
  roundMoney,
  type DealerSummary,
  type DtwDelivery,
  type PricingSnapshot,
  type QualitySummary,
  type RatesPlan,
  type RuleDiff,
} from '@/domain/dealerRates';
import { ExpandRow, Paged, download, downloadDelivery, kindOf, matchItem, range, rs, signed, useOpenSet } from './parts';
import type { Targets } from './RatesPage';

export interface Confirmed {
  files: DtwDelivery[];
  at: string;
  summary: string;
  /** The copy of SAP the files were made from; a sync to a newer one ends the wait for the import. */
  syncedAt: string;
  /** Which files have been downloaded — kept here so leaving the tab does not forget. */
  downloaded: Record<string, boolean>;
}

const count = (n: number, what: string) => `${n} ${what}${n === 1 ? '' : 's'}`;
const andList = (parts: string[]) => (parts.length < 2 ? parts.join('') : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`);

/** How to import one delivery, in the DTW wizard's own steps (DTW 10.00.190 help, "Importing the Source Data"). Folded away until asked for. */
function ImportSteps({ d }: { d: DtwDelivery }) {
  return (
    <details className="rates__how">
      <summary>How to import</summary>
      <ul className="rates__notes">
        <li>
          Log in to DTW as <b>{d.company}</b> ({d.companyName}); Tools → Import Data.
        </li>
        <li>
          Step 1 Select Data Type: <b>{d.import.dataType}</b>. Step 2 Specify Operation Type: <b>{d.import.dtwMode}</b>.
        </li>
        <li>
          Step 3 Select a Business Object: <b>{d.import.objectPath}</b>.
        </li>
        <li>
          Step 4 Select Data Source: csv (comma delimited) — <span className="mono">{d.name}</span> goes to <b>{d.import.slot}</b>
          {d.import.note ? `; ${d.import.note}` : ''}.
        </li>
        <li>Step 6: Run Simulation first; import only when clean.</li>
        {d.fallback && (
          <li className="tiny dim">
            Items file, only if DTW requires it:{' '}
            <Button size="sm" variant="ghost" onClick={() => download(d.fallback!.name, d.fallback!.content)}>
              {d.fallback.name}
            </Button>
          </li>
        )}
      </ul>
    </details>
  );
}

export function PreviewTab({
  snapshot,
  plan,
  targets,
  qualities,
  dealers,
  ruleDiff,
  dirty,
  awaitingImport,
  confirming,
  onConfirm,
  confirmed,
  onDownloaded,
  onSync,
}: {
  snapshot: PricingSnapshot;
  plan: RatesPlan;
  targets: Targets;
  qualities: QualitySummary[];
  dealers: DealerSummary[];
  ruleDiff: RuleDiff;
  dirty: boolean;
  /** Files were made from this copy of SAP; confirming again would only repeat them. */
  awaitingImport: boolean;
  confirming: boolean;
  onConfirm: () => void;
  confirmed: Confirmed | null;
  onDownloaded: (name: string) => void;
  onSync: () => void;
}) {
  const qOpen = useOpenSet<string>();
  const dOpen = useOpenSet<string>();
  const lOpen = useOpenSet<string>();
  const oOpen = useOpenSet<string>();
  const hOpen = useOpenSet<string>();
  const [scope, setScope] = useState<'changing' | 'all'>('changing');
  const [hScope, setHScope] = useState<'changing' | 'all'>('changing');
  const [showProblems, setShowProblems] = useState(false);
  const downloaded = confirmed?.downloaded ?? {};

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
  const dealerPrices = plan.counts.add + plan.counts.update;
  const changing = [
    plan.counts.listChanges ? count(plan.counts.listChanges, 'Manna Treads list price') : '',
    dealerPrices ? count(dealerPrices, 'dealer price') : '',
    plan.counts.hitech ? count(plan.counts.hitech, `${hitechName} price`) : '',
  ].filter(Boolean);
  const will = andList(
    [
      changing.length ? `changes ${andList(changing)}` : '',
      ruleCount ? `saves ${count(ruleCount, 'dealer price rule')}` : '',
      files.length ? `makes ${count(files.length, 'DTW file')}` : '',
    ].filter(Boolean),
  );

  return (
    <>
      {confirmed && (
        <Card title={`DTW files · ${confirmed.at}`}>
          {confirmed.files.length === 0 ? (
            <p className="small">No files needed — SAP already matches.</p>
          ) : (
            <ol className="rates__steps">
              {confirmed.files.map((d) => (
                <li key={d.id}>
                  <div className="rates__bar">
                    <b>{d.title}</b>
                    <span className="small dim">
                      {d.rows} row(s) · {d.companyName}
                    </span>
                    <Button
                      size="sm"
                      variant={downloaded[d.name] ? 'ghost' : 'primary'}
                      title={d.name}
                      onClick={() => {
                        downloadDelivery(d);
                        onDownloaded(d.name);
                      }}
                    >
                      {downloaded[d.name] ? 'Downloaded ✓' : 'Download'}
                    </Button>
                  </div>
                  <ImportSteps d={d} />
                </li>
              ))}
              <li>
                <div className="rates__bar">
                  <b>After import</b>
                  <Button size="sm" onClick={onSync}>
                    Sync from SAP
                  </Button>
                </div>
              </li>
            </ol>
          )}
        </Card>
      )}

      <Card title="Confirm" className="rates__confirm-card">
        {plan.hitechSkipped && (
          <Alert tone="warn" title={`No ${hitechName} prices`}>
            {plan.hitechSkipped}.
          </Alert>
        )}
        {problems.length > 0 && (
          <Alert
            tone="warn"
            title={`${problems.length} row(s) are left out of the files`}
            actions={
              <Button size="sm" variant="ghost" onClick={() => setShowProblems((s) => !s)}>
                {showProblems ? 'Hide' : 'Show'}
              </Button>
            }
          >
            {showProblems && (
              <ul className="rates__notes">
                {problems.map((p, i) => (
                  <li key={i}>
                    {p.cardCode ? `${p.cardCode} · ` : ''}
                    {p.itemCode}: {p.message}
                  </li>
                ))}
              </ul>
            )}
          </Alert>
        )}
        <div className="rates__confirm">
          <span className="small">
            {!dirty ? 'No changes — SAP already matches.' : awaitingImport ? `Files made ${confirmed?.at}. Import them, then Sync from SAP.` : `Confirming ${will}.`}
          </span>
          {awaitingImport ? (
            <Button variant="ghost" disabled={!dirty} loading={confirming} onClick={onConfirm}>
              Make files again
            </Button>
          ) : (
            <Button variant="primary" disabled={!dirty} loading={confirming} onClick={onConfirm}>
              Confirm and make DTW files
            </Button>
          )}
        </div>
      </Card>

      {changingQualities.length > 0 && (
        <Card title="Manna Treads list prices" flush>
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Group</th>
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
                      key={q.key}
                      open={qOpen.has(q.key)}
                      onToggle={() => qOpen.toggle(q.key)}
                      colSpan={6}
                      cells={
                        <>
                          <td>
                            <b>{q.label}</b>
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
                        placeholder={`Filter ${q.label} items`}
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
        title="Dealer prices"
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
            {scope === 'changing' ? 'No dealer price changes' : 'No dealer prices'}
          </div>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th className="right">Groups</th>
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
                          <div className="tiny dim mono">{d.cardCode}</div>
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
                          <th>Group</th>
                          <th className="right">₹/kg off list</th>
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
                                    <td className="right num">{rs(r.listPrice)}</td>
                                    <td className="right num">{r.sapPrice === null ? <span className="dim">none</span> : rs(r.sapPrice)}</td>
                                    <td className="right num">
                                      <b>{rs(r.newPrice)}</b>
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
          title={`${hitechName} prices`}
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
              {plan.hitechSkipped ?? (hScope === 'changing' ? `${hitechName} prices are up to date` : 'No Hi-Tech twins')}
            </div>
          ) : (
            <div className="table-wrap">
              <table className="table rates__table">
                <thead>
                  <tr>
                    <th className="rates__chev" />
                    <th>Group</th>
                    <th className="right">Items</th>
                    <th className="right">Now</th>
                    <th className="right">New</th>
                  </tr>
                </thead>
                <tbody>
                  {hitechGroups.map((g) => {
                    const k = g.key;
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
                            <td className="right num">{g.rows.length}</td>
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
        </Card>
      )}

      {orphanDealers.length > 0 && (
        <Card title={`Dealer prices in SAP with no rule (${plan.orphans.length})`} flush>
          <div className="rates__pad">
            <Alert tone="warn">
              Delete in SAP: Special Prices for Business Partners → right-click the row → Delete Row. DTW cannot remove them.
            </Alert>
          </div>
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th className="right">Prices with no rule</th>
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
                          <td>{o.item?.name ?? <span className="dim">not in a group</span>}</td>
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
