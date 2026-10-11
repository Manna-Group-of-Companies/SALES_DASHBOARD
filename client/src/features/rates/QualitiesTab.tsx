/**
 * List prices by group: one row per item property named in Manna Treads' SAP —
 * "HOT - Black Pearl", "PCTR - Black Pearl", and any group named later, such as
 * "BONDING GUM - Black Pearl" — with how many items carry it, Manna Treads'
 * price range today, the change in rupees, the new range, and what Hi-Tech's
 * price for the same items becomes. Each row has its own change box. Clicking
 * a row opens its items, each with its Hi-Tech twin.
 */

import { Alert, Badge, Card, Input } from '@/components/ui';
import { roundMoney, type QualitySummary, type RatesPlan } from '@/domain/dealerRates';
import { ExpandRow, Paged, keepRow, kindOf, matchItem, range, rs, signed, useOpenSet } from './parts';

export function QualitiesTab({
  summaries,
  plan,
  hitechName,
  changeInput,
  setChange,
}: {
  summaries: QualitySummary[];
  plan: RatesPlan;
  hitechName: string;
  changeInput: Record<string, string>;
  setChange: (key: string, value: string) => void;
}) {
  const rows = useOpenSet<string>();
  const newPrice = new Map(plan.listChanges.map((c) => [c.item.code, c.newPrice]));
  const hitechBy = new Map(plan.hitechRows.map((r) => [r.item.code, r]));
  const itemProblems = [...plan.problems.filter((p) => !p.cardCode), ...plan.hitechProblems];

  return (
    <Card title="List prices by group" flush>
      <div className="table-wrap">
        <table className="table rates__table">
          <thead>
            <tr>
              <th className="rates__chev" />
              <th>Group</th>
              <th className="right">Items</th>
              <th className="right">List price now</th>
              <th className="right">Change ₹/kg</th>
              <th className="right">New list price</th>
              <th className="right">{hitechName}</th>
              <th className="right">Dealers</th>
            </tr>
          </thead>
          <tbody>
            {summaries.map((q) => {
              const changed = q.changedItems > 0;
              return (
                <ExpandRow
                  key={q.key}
                  open={rows.has(q.key)}
                  onToggle={() => rows.toggle(q.key)}
                  colSpan={8}
                  tone={changed ? 'changed' : undefined}
                  label={`${q.label}: ${q.items.length} items`}
                  cells={
                    <>
                      <td>
                        <b>{q.label}</b>
                      </td>
                      <td className="right num">{q.items.length}</td>
                      <td className="right num">{range(q.listNow)}</td>
                      <td className="right">
                        <Input
                          {...keepRow}
                          numeric
                          compact
                          className="rates__change"
                          type="number"
                          step="0.5"
                          placeholder="0"
                          value={changeInput[q.key] ?? ''}
                          onChange={(e) => setChange(q.key, e.target.value)}
                          disabled={q.items.length === 0}
                          aria-label={`Change ${q.label} by rupees per kg`}
                        />
                      </td>
                      <td className="right num">
                        {changed ? <b>{range(q.listNew)}</b> : <span className="dim">—</span>}
                      </td>
                      <td className="right num">
                        {!q.hitechNew.length ? (
                          <span className="dim">—</span>
                        ) : q.hitechChanging ? (
                          <b>{range(q.hitechNew)}</b>
                        ) : (
                          range(q.hitechNew)
                        )}
                      </td>
                      <td className="right num">{q.dealers}</td>
                    </>
                  }
                >
                  <Paged
                    rows={q.items}
                    match={matchItem}
                    placeholder={`Filter ${q.label} items`}
                    empty={`No items carry ${q.label} in SAP`}
                    header={
                      <tr>
                        <th>Item</th>
                        <th>Name</th>
                        <th>Type</th>
                        <th className="right">List now</th>
                        <th className="right">New list</th>
                        <th className="right">Change</th>
                        <th className="right">{hitechName} now → new</th>
                      </tr>
                    }
                  >
                    {(i) => {
                      const np = newPrice.get(i.code);
                      const h = hitechBy.get(i.code);
                      return (
                        <tr key={i.code}>
                          <td className="mono">{i.code}</td>
                          <td>
                            {i.name}
                            {!i.sales && <Badge tone="warn">not a sales item</Badge>}
                            {i.frozen && <Badge tone="danger">frozen</Badge>}
                          </td>
                          <td>{kindOf(i)}</td>
                          <td className="right num">{rs(i.listPrice)}</td>
                          <td className="right num">{np !== undefined ? <b>{rs(np)}</b> : <span className="dim">{rs(i.listPrice)}</span>}</td>
                          <td className="right num">{np !== undefined ? signed(roundMoney(np - Number(i.listPrice))) : ''}</td>
                          <td className="right num">
                            {h ? (
                              <>
                                {rs(h.hitechNow)} → {h.action === 'UPDATE' ? <b>{rs(h.newPrice)}</b> : rs(h.newPrice)}
                              </>
                            ) : (
                              <span className="dim" title={i.twinNote ?? (i.twin ? undefined : 'No Hi-Tech twin')}>
                                —
                              </span>
                            )}
                          </td>
                        </tr>
                      );
                    }}
                  </Paged>
                </ExpandRow>
              );
            })}
          </tbody>
        </table>
      </div>
      {plan.multiGroup.length > 0 && (
        <div className="rates__pad">
          <Alert tone="warn" title={`${plan.multiGroup.length} item(s) carry more than one group`}>
            Untick all but one in Manna Treads' SAP: {plan.multiGroup.slice(0, 10).map((i) => i.code).join(', ')}
            {plan.multiGroup.length > 10 ? `, …and ${plan.multiGroup.length - 10} more` : ''}.
          </Alert>
        </div>
      )}
      {itemProblems.length > 0 && (
        <div className="rates__pad">
          <Alert tone="warn" title={`${itemProblems.length} item(s) cannot take the change`}>
            Listed on the Preview tab.
          </Alert>
        </div>
      )}
    </Card>
  );
}
