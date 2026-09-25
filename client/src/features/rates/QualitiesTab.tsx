/**
 * Qualities & list prices: one row per quality — how many items, Manna Treads'
 * price range today, the change in rupees, the new range, and what Hi-Tech's
 * price for the same items becomes. Clicking a row opens its items, each with
 * its Hi-Tech twin. The change box sits in the summary row, so a quality is
 * changed without opening anything.
 */

import { Alert, Badge, Card, Input } from '@/components/ui';
import { roundMoney, type QualitySummary, type RatesPlan } from '@/domain/dealerRates';
import { ExpandRow, Paged, keepRow, kindOf, matchItem, range, rs, signed, useOpenSet } from './parts';

export function QualitiesTab({
  summaries,
  plan,
  margin,
  hitechName,
  changeInput,
  setChange,
}: {
  summaries: QualitySummary[];
  plan: RatesPlan;
  margin: number | null;
  hitechName: string;
  changeInput: Record<number, string>;
  setChange: (propertyNo: number, value: string) => void;
}) {
  const rows = useOpenSet<number>();
  const newPrice = new Map(plan.listChanges.map((c) => [c.item.code, c.newPrice]));
  const hitechBy = new Map(plan.hitechRows.map((r) => [r.item.code, r]));
  const itemProblems = [...plan.problems.filter((p) => !p.cardCode), ...plan.hitechProblems];

  return (
    <Card
      title="Qualities — Manna Treads' list prices"
      actions={
        <span className="small dim">
          Type the rupees per kg to add (− to take off) in a quality's row. {hitechName}'s price follows at{' '}
          {margin ? `${rs(margin)} less` : 'the margin below'}. Click a row to see its items.
        </span>
      }
      flush
    >
      <div className="table-wrap">
        <table className="table rates__table">
          <thead>
            <tr>
              <th className="rates__chev" />
              <th>Quality</th>
              <th className="right">Items</th>
              <th className="right">List price now</th>
              <th className="right">Change ₹/kg</th>
              <th className="right">New list price</th>
              <th className="right">{hitechName}</th>
              <th className="right">Dealers with a discount</th>
            </tr>
          </thead>
          <tbody>
            {summaries.map((q) => {
              const changed = q.changedItems > 0;
              return (
                <ExpandRow
                  key={q.propertyNo}
                  open={rows.has(q.propertyNo)}
                  onToggle={() => rows.toggle(q.propertyNo)}
                  colSpan={8}
                  tone={changed ? 'changed' : undefined}
                  label={`${q.name}: ${q.items.length} items`}
                  cells={
                    <>
                      <td>
                        <b>{q.name}</b>
                        <div className="tiny dim">SAP item property {q.propertyNo}</div>
                      </td>
                      <td className="right num">
                        {q.items.length}
                        <div className="tiny dim">
                          {q.precured} precured · {q.hot} hot
                        </div>
                      </td>
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
                          value={changeInput[q.propertyNo] ?? ''}
                          onChange={(e) => setChange(q.propertyNo, e.target.value)}
                          aria-label={`Change ${q.name} by rupees per kg`}
                        />
                      </td>
                      <td className="right num">
                        {changed ? (
                          <>
                            <b>{range(q.listNew)}</b>
                            <div className="tiny dim">
                              {q.changedItems} item{q.changedItems === 1 ? '' : 's'} {signed(q.change)}
                            </div>
                          </>
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right num">
                        {q.hitechNew.length ? (
                          <>
                            {q.hitechChanging ? <b>{range(q.hitechNew)}</b> : range(q.hitechNew)}
                            <div className="tiny dim">
                              {q.hitechChanging ? `${q.hitechChanging} changing` : 'unchanged'}
                              {q.noTwin ? ` · ${q.noTwin} with no twin` : ''}
                            </div>
                          </>
                        ) : (
                          <span className="dim">{q.noTwin ? `${q.noTwin} with no twin` : '—'}</span>
                        )}
                      </td>
                      <td className="right num">{q.dealers}</td>
                    </>
                  }
                >
                  <Paged
                    rows={q.items}
                    match={matchItem}
                    placeholder={`Filter ${q.name} items by code, name, precured / hot`}
                    header={
                      <tr>
                        <th>Item</th>
                        <th>Name</th>
                        <th>Type</th>
                        <th>UoM</th>
                        <th className="right">Belts/roll</th>
                        <th className="right">kg/roll</th>
                        <th className="right">Stock</th>
                        <th>Last changed in SAP</th>
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
                          <td>{i.uom || '—'}</td>
                          <td className="right num">{i.beltsPerRoll ?? '—'}</td>
                          <td className="right num">{i.weightPerRoll ?? '—'}</td>
                          <td className="right num">
                            {Number(i.stock).toLocaleString('en-IN')}
                            {h?.hitech.stock !== undefined && <div className="tiny dim">Hi-Tech {Number(h.hitech.stock).toLocaleString('en-IN')}</div>}
                          </td>
                          <td className="num">{i.updated || '—'}</td>
                          <td className="right num">{rs(i.listPrice)}</td>
                          <td className="right num">{np !== undefined ? <b>{rs(np)}</b> : <span className="dim">{rs(i.listPrice)}</span>}</td>
                          <td className="right num">{np !== undefined ? signed(roundMoney(np - Number(i.listPrice))) : ''}</td>
                          <td className="right num">
                            {h ? (
                              <>
                                {rs(h.hitechNow)} → {h.action === 'UPDATE' ? <b>{rs(h.newPrice)}</b> : rs(h.newPrice)}
                                <div className="tiny dim mono">{h.hitech.code}</div>
                              </>
                            ) : (
                              <span className="tiny dim">{i.twinNote ?? (i.twin ? '—' : 'no Hi-Tech twin')}</span>
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
      {itemProblems.length > 0 && (
        <div className="rates__pad">
          <Alert tone="warn" title={`${itemProblems.length} item(s) cannot take the change`}>
            <ul className="rates__notes">
              {itemProblems.slice(0, 20).map((p) => (
                <li key={p.itemCode + p.message}>
                  {p.itemCode} {p.message}
                </li>
              ))}
              {itemProblems.length > 20 && <li>…and {itemProblems.length - 20} more (all listed on the Preview tab)</li>}
            </ul>
          </Alert>
        </div>
      )}
    </Card>
  );
}
