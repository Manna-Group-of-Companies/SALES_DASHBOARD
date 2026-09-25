/**
 * Dealer discounts: one row per dealer — their discounts as chips, how many
 * items that covers, what they end up paying, and whether the draft changes
 * them. Clicking a dealer opens their discounts quality by quality (editable);
 * clicking a quality there opens its items and the dealer's price for each.
 *
 * Adding a discount lives behind a button so the screen opens on the list.
 */

import { useMemo, useState } from 'react';
import { Alert, Badge, Button, Card, Empty, Input, Select } from '@/components/ui';
import {
  roundMoney,
  ruleKey,
  type DealerRule,
  type DealerSummary,
  type PricingSnapshot,
} from '@/domain/dealerRates';
import { Chips, ExpandRow, Paged, keepRow, kindOf, matchItem, range, rs, useOpenSet } from './parts';

type Customer = PricingSnapshot['customers'][number];

export function DealersTab({
  qualities,
  customers,
  draftRules,
  savedRules,
  summaries,
  upsert,
  remove,
}: {
  qualities: { no: number; name: string }[];
  customers: Map<string, Customer>;
  draftRules: DealerRule[];
  savedRules: DealerRule[];
  summaries: DealerSummary[];
  upsert: (r: DealerRule) => void;
  remove: (key: string) => void;
}) {
  const dealersOpen = useOpenSet<string>();
  const linesOpen = useOpenSet<string>();
  const [search, setSearch] = useState('');
  const [adding, setAdding] = useState(false);

  const savedByKey = useMemo(() => new Map(savedRules.map((r) => [ruleKey(r), r])), [savedRules]);
  const draftKeys = useMemo(() => new Set(draftRules.map(ruleKey)), [draftRules]);
  const removed = savedRules.filter((s) => !draftKeys.has(ruleKey(s)));

  const stateOf = (r: DealerRule): 'new' | 'changed' | 'saved' => {
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
      <Card
        title={`Dealers with discounts (${withRules.length})`}
        actions={
          <div className="rates__bar">
            <Input compact value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Find a dealer by code, name or group" />
            <Button variant={adding ? 'ghost' : 'primary'} onClick={() => setAdding((a) => !a)}>
              {adding ? 'Close' : '+ Add a discount'}
            </Button>
          </div>
        }
        flush
      >
        {adding && (
          <AddDiscount
            qualities={qualities}
            customers={customers}
            onAdd={(r) => {
              upsert(r);
              // Open the dealer so the MD sees the discount land.
              if (!dealersOpen.has(r.cardCode)) dealersOpen.toggle(r.cardCode);
            }}
          />
        )}

        {withRules.length === 0 ? (
          <Empty title="No dealer discounts yet">Press “+ Add a discount” to give a dealer rupees off a quality.</Empty>
        ) : (
          <div className="table-wrap">
            <table className="table rates__table">
              <thead>
                <tr>
                  <th className="rates__chev" />
                  <th>Dealer</th>
                  <th>Discounts (₹/kg off)</th>
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
                      label={`${d.cardName}: ${d.lines.length} discounts`}
                      cells={
                        <>
                          <td>
                            <b>{d.cardName}</b>
                            <div className="tiny dim">
                              <span className="mono">{d.cardCode}</span>
                              {d.group ? ` · ${d.group}` : ''}
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
                            <th>Quality</th>
                            <th className="right">₹ off per kg</th>
                            <th className="right">Items</th>
                            <th className="right">Dealer pays</th>
                            <th>Note</th>
                            <th>State</th>
                            <th />
                          </tr>
                        </thead>
                        <tbody>
                          {d.lines.map((l) => {
                            const rule = mine.find((r) => r.propertyNo === l.propertyNo)!;
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
                                      <Input
                                        {...keepRow}
                                        numeric
                                        compact
                                        className="rates__change"
                                        type="number"
                                        step="0.5"
                                        min="0"
                                        value={String(rule.rupeesOff)}
                                        onChange={(e) => upsert({ ...rule, rupeesOff: roundMoney(Number(e.target.value)) })}
                                        aria-label={`${l.quality} rupees off per kg`}
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
                                  empty="No priced item carries this quality."
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
            {shown.length === 0 && <div className="small dim rates__pad">No dealer matches “{search}”.</div>}
          </div>
        )}
      </Card>

      {removed.length > 0 && (
        <Alert tone="warn" title={`Removed in this draft (${removed.length})`}>
          {removed
            .slice(0, 8)
            .map((r) => `${r.cardName || r.cardCode} · ${r.quality} (${rs(r.rupeesOff)} off)`)
            .join(' · ')}
          {removed.length > 8 ? ` · …and ${removed.length - 8} more` : ''}. Removing a discount does not remove the price from SAP:
          after confirming, delete those rows in SAP's Special Prices for Business Partners window, or the dealer keeps the old price.
        </Alert>
      )}
    </>
  );
}

function AddDiscount({
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
    if (!c) return setError("Pick a dealer from the list (it offers every Manna Treads customer in SAP by code and name).");
    const n = roundMoney(Number(rupees));
    if (!(n > 0)) return setError('Rupees off must be more than zero.');
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
          <span className="small dim">Dealer (Manna Treads customer)</span>
          <Input list="rates-dealers" value={dealer} onChange={(e) => setDealer(e.target.value)} placeholder="Type a code or a name" />
          <datalist id="rates-dealers">
            {[...customers.values()].map((c) => (
              <option key={c.code} value={`${c.code} — ${c.name}`}>
                {c.group}
              </option>
            ))}
          </datalist>
        </label>
        <label className="rates__field rates__field--narrow">
          <span className="small dim">Quality</span>
          <Select value={quality} onChange={(e) => setQuality(Number(e.target.value))}>
            {qualities.map((q) => (
              <option key={q.no} value={q.no}>
                {q.name}
              </option>
            ))}
          </Select>
        </label>
        <label className="rates__field rates__field--narrow">
          <span className="small dim">₹ off per kg</span>
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
      <div className="tiny dim">
        A dealer has one discount per quality; adding the same dealer and quality again replaces it. Nothing is saved until you
        confirm on the Preview tab.
      </div>
    </div>
  );
}
