/**
 * Dealer discounts, two ways round.
 *
 * BY DEALER: one row per dealer — their discounts as chips, how many items
 * that covers, what they end up paying, and whether the draft changes them.
 * Clicking a dealer opens their discounts group by group (editable); clicking
 * a group there opens its items and the dealer's price for each.
 *
 * BY GROUP: one row per group — an item property, "HOT - Black Pearl" — with
 * every dealer's discount on it. Opening a group lists those dealers to edit,
 * adds a dealer to it, or moves every dealer's discount on it by the same
 * rupees. A discount is per group, so "HOT - Black Pearl" and "PCTR - Black
 * Pearl" take different rupees off (the user, 25 Sep 2026).
 *
 * Adding a discount lives behind a button so the screen opens on the list.
 */

import { useMemo, useState } from 'react';
import { Alert, Badge, Button, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import {
  roundMoney,
  ruleKey,
  type DealerRule,
  type DealerSummary,
  type PricingSnapshot,
} from '@/domain/dealerRates';
import { Chips, ExpandRow, Paged, RupeesInput, keepRow, kindOf, matchItem, range, rs, useOpenSet } from './parts';

type Customer = PricingSnapshot['customers'][number];

type RuleState = 'new' | 'changed' | 'saved';

export function DealersTab({
  qualities,
  itemCounts,
  customers,
  draftRules,
  savedRules,
  summaries,
  stale,
  upsert,
  remove,
}: {
  qualities: { no: number; name: string }[];
  /** Items carrying each group, by property number. */
  itemCounts: Map<number, number>;
  customers: Map<string, Customer>;
  draftRules: DealerRule[];
  savedRules: DealerRule[];
  summaries: DealerSummary[];
  /** Saved rules whose group SAP has since renamed (staleRules). */
  stale: { rule: DealerRule; was: string; now: string | null }[];
  upsert: (r: DealerRule) => void;
  remove: (key: string) => void;
}) {
  const dealersOpen = useOpenSet<string>();
  const linesOpen = useOpenSet<string>();
  const [search, setSearch] = useState('');
  const [adding, setAdding] = useState(false);
  const [view, setView] = useState<'dealer' | 'group'>('dealer');

  const savedByKey = useMemo(() => new Map(savedRules.map((r) => [ruleKey(r), r])), [savedRules]);
  const draftKeys = useMemo(() => new Set(draftRules.map(ruleKey)), [draftRules]);
  const removed = savedRules.filter((s) => !draftKeys.has(ruleKey(s)));

  const stateOf = (r: DealerRule): RuleState => {
    const s = savedByKey.get(ruleKey(r));
    if (!s) return 'new';
    return Math.abs(s.rupeesOff - r.rupeesOff) > 0.0001 || (s.note ?? '') !== (r.note ?? '') ? 'changed' : 'saved';
  };

  const withRules = summaries.filter((d) => d.lines.length > 0);
  const needle = search.trim().toLowerCase();
  const shown = needle
    ? withRules.filter((d) => `${d.cardCode} ${d.cardName} ${d.group ?? ''}`.toLowerCase().includes(needle))
    : withRules;

  return (
    <>
      <DealerList customers={customers} />
      {stale.length > 0 && (
        <Alert tone="warn" title={`${stale.length} dealer price(s) on a renamed group`}>
          {stale
            .slice(0, 8)
            .map((s) => `${s.rule.cardName || s.rule.cardCode}: ₹${s.rule.rupeesOff}/kg off "${s.was}" → ${s.now ? `"${s.now}"` : 'unnamed property'}`)
            .join(' · ')}
          {stale.length > 8 ? ` · …and ${stale.length - 8} more` : ''}. Confirming saves them under the new name.
        </Alert>
      )}
      <Card
        title={view === 'dealer' ? `Dealers (${withRules.length})` : `Groups (${qualities.length})`}
        actions={
          <div className="rates__bar">
            <Segmented
              ariaLabel="View by"
              value={view}
              onChange={setView}
              options={[
                { value: 'dealer', label: 'By dealer' },
                { value: 'group', label: 'By group' },
              ]}
            />
            <Input
              compact
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={view === 'dealer' ? 'Search dealer, code or group' : 'Search group'}
            />
            <Button variant={adding ? 'ghost' : 'primary'} onClick={() => setAdding((a) => !a)}>
              {adding ? 'Close' : '+ Add a dealer price'}
            </Button>
          </div>
        }
        flush
      >
        {adding && (
          <AddDealerPrice
            qualities={qualities}
            customers={customers}
            onAdd={(r) => {
              upsert(r);
              // Open the dealer so the MD sees the new price land.
              if (view === 'dealer' && !dealersOpen.has(r.cardCode)) dealersOpen.toggle(r.cardCode);
            }}
          />
        )}

        {view === 'group' ? (
          <ByGroup
            qualities={needle ? qualities.filter((q) => q.name.toLowerCase().includes(needle)) : qualities}
            itemCounts={itemCounts}
            customers={customers}
            draftRules={draftRules}
            summaries={summaries}
            stateOf={stateOf}
            savedByKey={savedByKey}
            upsert={upsert}
            remove={remove}
          />
        ) : withRules.length === 0 ? (
          <Empty title="No dealer prices" />
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th>₹/kg off list</th>
                  <th className="right">Items covered</th>
                  <th className="right">Dealer pays</th>
                  <th>Draft</th>
                </tr>
              </thead>
              <tbody>
                {shown.map((d) => {
                  const mine = draftRules.filter((r) => r.cardCode === d.cardCode);
                  const states = mine.map(stateOf);
                  const nNew = states.filter((s) => s === 'new').length;
                  const nChanged = states.filter((s) => s === 'changed').length;
                  const nGone = removed.filter((r) => r.cardCode === d.cardCode).length;
                  const touched = nNew + nChanged + nGone > 0;
                  return (
                    <ExpandRow
                      key={d.cardCode}
                      open={dealersOpen.has(d.cardCode)}
                      onToggle={() => dealersOpen.toggle(d.cardCode)}
                      colSpan={6}
                      tone={touched ? 'changed' : undefined}
                      label={`${d.cardName}: ${d.lines.length} dealer prices`}
                      cells={
                        <>
                          <td>
                            <b>{d.cardName}</b>
                            <div className="tiny dim">
                              <span className="mono">{d.cardCode}</span>
                              {d.active === false ? ' · inactive in SAP' : ''}
                            </div>
                          </td>
                          <td>
                            <Chips items={d.lines.map((l) => `${l.quality} ${rs(l.rupeesOff)}`)} />
                          </td>
                          <td className="right num">{d.lines.reduce((n, l) => n + l.rows.length, 0)}</td>
                          <td className="right num">{range(d.prices)}</td>
                          <td>
                            {touched ? (
                              <span className="rates__chips">
                                {nNew > 0 && <Badge tone="info">{nNew} new</Badge>}
                                {nChanged > 0 && <Badge tone="warn">{nChanged} changed</Badge>}
                                {nGone > 0 && <Badge tone="danger">{nGone} removed</Badge>}
                              </span>
                            ) : (
                              <span className="tiny dim">saved</span>
                            )}
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
                            <th className="right">Dealer pays</th>
                            <th>Note</th>
                            <th>State</th>
                            <th />
                          </tr>
                        </thead>
                        <tbody>
                          {d.lines.map((l) => {
                            // The lines come from the deferred copy of the
                            // rules and `mine` from the live one, so for one
                            // render after a Remove the rule is already gone.
                            const rule = mine.find((r) => r.propertyNo === l.propertyNo);
                            if (!rule) return null;
                            const k = ruleKey(rule);
                            const st = stateOf(rule);
                            const was = savedByKey.get(k);
                            return (
                              <ExpandRow
                                key={k}
                                open={linesOpen.has(k)}
                                onToggle={() => linesOpen.toggle(k)}
                                colSpan={8}
                                tone={st !== 'saved' ? 'changed' : undefined}
                                cells={
                                  <>
                                    <td>
                                      <b>{l.quality}</b>
                                    </td>
                                    <td className="right">
                                      <RupeesInput
                                        value={rule.rupeesOff}
                                        onCommit={(n) => upsert({ ...rule, rupeesOff: n })}
                                        label={`${l.quality} rupees off per kg`}
                                      />
                                      {was && st === 'changed' && <div className="tiny dim">was {rs(was.rupeesOff)}</div>}
                                    </td>
                                    <td className="right num">{l.rows.length}</td>
                                    <td className="right num">{range(l.rows.map((x) => x.newPrice))}</td>
                                    <td className="small">{rule.note ?? ''}</td>
                                    <td>
                                      <Badge tone={st === 'new' ? 'info' : st === 'changed' ? 'warn' : 'ok'}>{st}</Badge>
                                    </td>
                                    <td className="right">
                                      <Button
                                        size="sm"
                                        variant="ghost"
                                        onKeyDown={keepRow.onKeyDown}
                                        onClick={(e) => {
                                          e.stopPropagation();
                                          remove(k);
                                        }}
                                      >
                                        Remove
                                      </Button>
                                    </td>
                                  </>
                                }
                              >
                                <Paged
                                  rows={l.rows}
                                  match={(r, q) => matchItem(r.item, q)}
                                  placeholder={`Filter ${l.quality} items`}
                                  empty="No priced items"
                                  header={
                                    <tr>
                                      <th>Item</th>
                                      <th>Name</th>
                                      <th>Type</th>
                                      <th className="right">List</th>
                                      <th className="right">Dealer pays</th>
                                      <th className="right">In SAP now</th>
                                    </tr>
                                  }
                                >
                                  {(r) => (
                                    <tr key={r.item.code}>
                                      <td className="mono">{r.item.code}</td>
                                      <td>{r.item.name}</td>
                                      <td>{kindOf(r.item)}</td>
                                      <td className="right num">{rs(r.listPrice)}</td>
                                      <td className="right num">
                                        <b>{rs(r.newPrice)}</b>
                                      </td>
                                      <td className="right num">
                                        {r.sapPrice === null ? <span className="dim">none</span> : rs(r.sapPrice)}
                                      </td>
                                    </tr>
                                  )}
                                </Paged>
                              </ExpandRow>
                            );
                          })}
                        </tbody>
                      </table>
                      {d.problems.length > 0 && (
                        <div className="rates__pad">
                          <Alert tone="warn" title={`${d.problems.length} item(s) get no price`}>
                            {d.problems.slice(0, 5).map((p) => `${p.itemCode}: ${p.message}`).join(' · ')}
                            {d.problems.length > 5 ? ` · …and ${d.problems.length - 5} more` : ''}
                          </Alert>
                        </div>
                      )}
                    </ExpandRow>
                  );
                })}
              </tbody>
            </table>
            {shown.length === 0 && <div className="small dim rates__pad">No matching dealers</div>}
          </div>
        )}
      </Card>

      {removed.length > 0 && (
        <Alert tone="warn" title={`Removed in this draft (${removed.length})`}>
          {removed
            .slice(0, 8)
            .map((r) => `${r.cardName || r.cardCode} · ${r.quality} (${rs(r.rupeesOff)}/kg off)`)
            .join(' · ')}
          {removed.length > 8 ? ` · …and ${removed.length - 8} more` : ''}. SAP keeps these until deleted in Special Prices for Business
          Partners.
        </Alert>
      )}
    </>
  );
}

/**
 * Discounts by group: one row per item property ("HOT - Black Pearl") with the
 * dealers who have a discount on it. Opening a group lists them to edit, adds
 * a dealer to it, and can move every one of those discounts by the same rupees
 * — a change of dealer rates made selectively, group by group.
 */
function ByGroup({
  qualities,
  itemCounts,
  customers,
  draftRules,
  summaries,
  stateOf,
  savedByKey,
  upsert,
  remove,
}: {
  qualities: { no: number; name: string }[];
  itemCounts: Map<number, number>;
  customers: Map<string, Customer>;
  draftRules: DealerRule[];
  summaries: DealerSummary[];
  stateOf: (r: DealerRule) => RuleState;
  savedByKey: Map<string, DealerRule>;
  upsert: (r: DealerRule) => void;
  remove: (key: string) => void;
}) {
  const groupsOpen = useOpenSet<number>();
  const [shift, setShift] = useState<Record<number, string>>({});
  const [note, setNote] = useState<Record<number, string>>({});
  const [newDealer, setNewDealer] = useState<Record<number, string>>({});
  const [newRupees, setNewRupees] = useState<Record<number, string>>({});
  const summaryBy = useMemo(() => new Map(summaries.map((d) => [d.cardCode, d])), [summaries]);

  if (!qualities.length) return <Empty title="No group matches" />;

  return (
    <div className="table-wrap">
      <table className="table rates__table">
        <thead>
          <tr>
            <th className="rates__chev" />
            <th>Group</th>
            <th className="right">Items</th>
            <th className="right">Dealers</th>
            <th className="right">₹/kg off list</th>
            <th className="right">Dealers pay</th>
            <th>Draft</th>
          </tr>
        </thead>
        <tbody>
          {qualities.map((q) => {
            const rules = draftRules.filter((r) => r.propertyNo === q.no).sort((a, b) => (a.cardName || a.cardCode).localeCompare(b.cardName || b.cardCode));
            const lineOf = (card: string) => summaryBy.get(card)?.lines.find((l) => l.propertyNo === q.no);
            const pays = rules.flatMap((r) => (lineOf(r.cardCode)?.rows ?? []).map((x) => x.newPrice));
            const states = rules.map(stateOf);
            const touched = states.some((s) => s !== 'saved');
            const apply = () => {
              const by = roundMoney(Number(shift[q.no]));
              if (!by) return;
              let kept = 0;
              for (const r of rules) {
                const next = roundMoney(r.rupeesOff + by);
                if (next > 0) upsert({ ...r, rupeesOff: next });
                else kept++;
              }
              setShift((p) => ({ ...p, [q.no]: '' }));
              setNote((p) => ({
                ...p,
                [q.no]: `₹/kg off on ${q.name} changed by ${by > 0 ? '+' : '−'}${rs(Math.abs(by))} for every dealer${kept ? `; ${kept} unchanged (would reach ₹0)` : ''}.`,
              }));
            };
            const add = () => {
              const code = (newDealer[q.no] ?? '').split(' — ')[0].trim();
              const c = customers.get(code);
              const n = roundMoney(Number(newRupees[q.no]));
              if (!c) return setNote((p) => ({ ...p, [q.no]: 'Pick a dealer from the list.' }));
              if (!(n > 0)) return setNote((p) => ({ ...p, [q.no]: '₹/kg off must be more than zero.' }));
              upsert({ cardCode: c.code, cardName: c.name, propertyNo: q.no, quality: q.name, rupeesOff: n });
              setNewDealer((p) => ({ ...p, [q.no]: '' }));
              setNewRupees((p) => ({ ...p, [q.no]: '' }));
              setNote((p) => ({ ...p, [q.no]: `Added ${c.name}: ${rs(n)}/kg off ${q.name}.` }));
            };
            return (
              <ExpandRow
                key={q.no}
                open={groupsOpen.has(q.no)}
                onToggle={() => groupsOpen.toggle(q.no)}
                colSpan={7}
                tone={touched ? 'changed' : undefined}
                label={`${q.name}: ${rules.length} dealer prices`}
                cells={
                  <>
                    <td>
                      <b>{q.name}</b>
                    </td>
                    <td className="right num">{itemCounts.get(q.no) ?? 0}</td>
                    <td className="right num">{rules.length}</td>
                    <td className="right num">{range(rules.map((r) => r.rupeesOff))}</td>
                    <td className="right num">{range(pays)}</td>
                    <td>
                      {touched ? (
                        <span className="rates__chips">
                          {states.filter((s) => s === 'new').length > 0 && <Badge tone="info">{states.filter((s) => s === 'new').length} new</Badge>}
                          {states.filter((s) => s === 'changed').length > 0 && <Badge tone="warn">{states.filter((s) => s === 'changed').length} changed</Badge>}
                        </span>
                      ) : (
                        <span className="tiny dim">{rules.length ? 'saved' : 'none'}</span>
                      )}
                    </td>
                  </>
                }
              >
                <div className="rates__pad rates__bar">
                  {rules.length > 0 && (
                    <>
                      <span className="small">Change every dealer's ₹/kg off by</span>
                      <Input
                        numeric
                        compact
                        className="rates__change"
                        type="number"
                        step="0.5"
                        placeholder="0"
                        value={shift[q.no] ?? ''}
                        onChange={(e) => setShift((p) => ({ ...p, [q.no]: e.target.value }))}
                        aria-label={`Change every dealer's rupees off on ${q.name}`}
                      />
                      <Button size="sm" onClick={apply} disabled={!roundMoney(Number(shift[q.no]))}>
                        Apply to {rules.length} dealer{rules.length === 1 ? '' : 's'}
                      </Button>
                    </>
                  )}
                </div>
                {note[q.no] && <div className="small rates__pad">{note[q.no]}</div>}
                {rules.length > 0 && (
                  <table className="table rates__inner">
                    <thead>
                      <tr>
                        <th>Dealer</th>
                        <th className="right">₹/kg off list</th>
                        <th className="right">Items</th>
                        <th className="right">Dealer pays</th>
                        <th>State</th>
                        <th />
                      </tr>
                    </thead>
                    <tbody>
                      {rules.map((r) => {
                        const k = ruleKey(r);
                        const st = stateOf(r);
                        const was = savedByKey.get(k);
                        const line = lineOf(r.cardCode);
                        return (
                          <tr key={k} className={st !== 'saved' ? 'rates__row--changed' : ''}>
                            <td>
                              <b>{r.cardName || r.cardCode}</b>
                              <div className="tiny dim mono">{r.cardCode}</div>
                            </td>
                            <td className="right">
                              <RupeesInput
                                value={r.rupeesOff}
                                onCommit={(n) => upsert({ ...r, rupeesOff: n })}
                                label={`${r.cardName || r.cardCode}: rupees off ${q.name}`}
                              />
                              {was && st === 'changed' && <div className="tiny dim">was {rs(was.rupeesOff)}</div>}
                            </td>
                            <td className="right num">{line?.rows.length ?? 0}</td>
                            <td className="right num">{range((line?.rows ?? []).map((x) => x.newPrice))}</td>
                            <td>
                              <Badge tone={st === 'new' ? 'info' : st === 'changed' ? 'warn' : 'ok'}>{st}</Badge>
                            </td>
                            <td className="right">
                              <Button size="sm" variant="ghost" onClick={() => remove(k)}>
                                Remove
                              </Button>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                )}
                <div className="rates__pad rates__form">
                  <label className="rates__field">
                    <span className="small dim">Add a dealer to {q.name}</span>
                    <Input
                      list="rates-dealers"
                      value={newDealer[q.no] ?? ''}
                      onChange={(e) => setNewDealer((p) => ({ ...p, [q.no]: e.target.value }))}
                      placeholder="Dealer code or name"
                    />
                  </label>
                  <label className="rates__field rates__field--narrow">
                    <span className="small dim">₹/kg off list</span>
                    <Input
                      numeric
                      type="number"
                      step="0.5"
                      min="0"
                      value={newRupees[q.no] ?? ''}
                      onChange={(e) => setNewRupees((p) => ({ ...p, [q.no]: e.target.value }))}
                    />
                  </label>
                  <Button onClick={add}>Add to draft</Button>
                </div>
              </ExpandRow>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/** The dealer suggestions every "type a code or a name" box uses. */
function DealerList({ customers }: { customers: Map<string, Customer> }) {
  return (
    <datalist id="rates-dealers">
      {[...customers.values()].map((c) => (
        <option key={c.code} value={`${c.code} — ${c.name}`}>
          {c.group}
        </option>
      ))}
    </datalist>
  );
}

function AddDealerPrice({
  qualities,
  customers,
  onAdd,
}: {
  qualities: { no: number; name: string }[];
  customers: Map<string, Customer>;
  onAdd: (r: DealerRule) => void;
}) {
  const [dealer, setDealer] = useState('');
  const [quality, setQuality] = useState<number>(qualities[0]?.no ?? 1);
  const [rupees, setRupees] = useState('');
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);

  const add = () => {
    setError(null);
    const code = dealer.split(' — ')[0].trim();
    const c = customers.get(code);
    if (!c) return setError('Pick a dealer from the list.');
    const n = roundMoney(Number(rupees));
    if (!(n > 0)) return setError('₹/kg off must be more than zero.');
    onAdd({
      cardCode: c.code,
      cardName: c.name,
      propertyNo: quality,
      quality: qualities.find((q) => q.no === quality)?.name ?? '',
      rupeesOff: n,
      note: note.trim() || undefined,
    });
    setRupees('');
    setNote('');
  };

  return (
    <div className="rates__add">
      <div className="rates__form">
        <label className="rates__field">
          <span className="small dim">Dealer</span>
          <Input list="rates-dealers" value={dealer} onChange={(e) => setDealer(e.target.value)} placeholder="Dealer code or name" />
        </label>
        <label className="rates__field rates__field--narrow">
          <span className="small dim">Group</span>
          <Select value={quality} onChange={(e) => setQuality(Number(e.target.value))}>
            {qualities.map((q) => (
              <option key={q.no} value={q.no}>
                {q.name}
              </option>
            ))}
          </Select>
        </label>
        <label className="rates__field rates__field--narrow">
          <span className="small dim">₹/kg off list</span>
          <Input numeric type="number" step="0.5" min="0" value={rupees} onChange={(e) => setRupees(e.target.value)} />
        </label>
        <label className="rates__field">
          <span className="small dim">Note (optional)</span>
          <Input value={note} onChange={(e) => setNote(e.target.value)} />
        </label>
        <Button variant="primary" onClick={add}>
          Add to draft
        </Button>
      </div>
      {error && <div className="small rates__error">{error}</div>}
    </div>
  );
}
