/**
 * Product Sales — one product (5 Nov 2026): whether Hi-Tech still has it,
 * what it sold for (highest, lowest, average, and who sold at each), each
 * rep's share, and every sale in the month.
 */

import { useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Badge, Card, Empty, Icon, Skeleton } from '@/components/ui';
import { PriceChart, RepsChart } from './charts';
import { byProduct, priceOf, productDetail } from './productSales';
import {
  ReportHead,
  Stat,
  dm,
  initials,
  kgText,
  money,
  plural,
  priceText,
  stockState,
  useReportFilters,
  useSoldLines,
  useStock,
} from './shared';
import '@/components/layout/layout.css';

export function ProductDetailPage() {
  const { code = '' } = useParams();
  const f = useReportFilters();
  const [tick, setTick] = useState(0);
  const { lines, loading, error } = useSoldLines(f.from, f.to, f.scope.companies, tick);
  const { stock, loaded, failed } = useStock(tick);
  const c = f.scope.currency;

  const product = useMemo(() => byProduct(lines, 'amount').find((p) => p.itemCode === code), [lines, code]);
  const rank = useMemo(() => byProduct(lines, f.measure).findIndex((p) => p.itemCode === code) + 1, [lines, f.measure, code]);
  const d = useMemo(() => productDetail(lines, code), [lines, code]);
  const st = stockState(stock.get(code), loaded);
  const name = product?.itemName ?? stock.get(code)?.itemName ?? code;
  const p = (v: number) => priceText(v, d.per, c);

  const back = (
    <Link className="ps-back" to={`/product-sales/products${f.query}`}>
      <Icon name="chevronLeft" size={14} /> All products
    </Link>
  );

  return (
    <div>
      <ReportHead
        f={f}
        title={name}
        sub={
          loading
            ? code
            : product
              ? `${code} · number ${rank} of the month's products · ${plural(product.orders, 'order')}`
              : `${code} · not sold in ${f.scope.label}, ${f.monthLabel}`
        }
        loading={loading}
        onRefresh={() => setTick((t) => t + 1)}
        error={error}
        back={back}
      />

      {!failed && (
        <div className={`ps-stock ps-stock--${st.tone}`} style={{ marginTop: 0, marginBottom: 14 }}>
          <Badge tone={st.tone}>{st.label}</Badge>
          <span className="small">{st.detail} at Hi-Tech today</span>
        </div>
      )}

      {loading ? (
        <Card>
          <Skeleton height={260} />
        </Card>
      ) : !product ? (
        <Card>
          <Empty icon="—" title="No sales this month" />
        </Card>
      ) : (
        <>
          <Card flush>
            <div className="ps-stats ps-stats--4">
              <Stat label="Sold" value={money(product.amount, c)} />
              <Stat label="Weight" value={product.kg ? kgText(product.kg) : '—'}>
                {product.rolls ? plural(product.rolls, 'roll') : null}
              </Stat>
              <Stat label="Highest price" value={d.highest ? p(priceOf(d.highest).value) : '—'}>
                {d.highest && `${d.highest.rep || 'No rep'} · ${dm(d.highest.date)}`}
              </Stat>
              <Stat label="Lowest price" value={d.lowest ? p(priceOf(d.lowest).value) : '—'}>
                {d.lowest && `${d.lowest.rep || 'No rep'} · ${dm(d.lowest.date)}`}
              </Stat>
            </div>
            <div className="ps-avg">
              Average {d.average ? p(Math.round(d.average * 100) / 100) : '—'}, weighted by {d.per === 'kg' ? 'kg' : 'quantity'}.
              {d.highest && (
                <>
                  {' '}
                  Highest was on order <b>{d.highest.order}</b>.
                </>
              )}
            </div>
          </Card>

          <div className="ps-two ps-two--detail">
            <Card flush>
              <div className="ps-tools">
                <h2 className="ps-h2">Who sold it</h2>
              </div>
              <div style={{ padding: '8px 12px 0' }}>
                <RepsChart reps={d.reps} currency={c} />
              </div>
              <ul className="ps-reps" style={{ padding: '0 16px 10px' }}>
                {d.reps.map((r) => (
                  <li key={r.rep}>
                    <span className="ps-avatar" aria-hidden>
                      {initials(r.rep)}
                    </span>
                    <span className="grow">
                      <b>{r.rep}</b>
                      <div className="tiny dim">
                        {plural(r.orders, 'order')}
                        {r.kg ? ` · ${kgText(r.kg)}` : ''}
                        {r.topPrice ? ` · top ${p(r.topPrice)}` : ''}
                      </div>
                    </span>
                    <span className="ps-num">{money(r.amount, c)}</span>
                  </li>
                ))}
              </ul>
            </Card>

            <Card flush>
              <div className="ps-tools">
                <h2 className="ps-h2">Price per sale</h2>
                <span className="tiny dim" style={{ marginLeft: 'auto' }}>
                  Each dot is a sale, sized by quantity · {d.per === 'kg' ? 'per kg' : `per ${d.per}`}
                </span>
              </div>
              <div style={{ padding: '8px 12px' }}>
                <PriceChart lines={d.lines} per={d.per} currency={c} average={d.average} from={f.from} to={f.to} />
              </div>
              <div className="ps-tools" style={{ borderTop: '1px solid var(--border)' }}>
                <h2 className="ps-h2">Every sale</h2>
                <span className="tiny dim" style={{ marginLeft: 'auto' }}>
                  Newest first
                </span>
              </div>
              <div className="scroll-x">
                <table className="table ps-lines">
                  <thead>
                    <tr>
                      <th>Date</th>
                      <th>Rep</th>
                      <th>Order</th>
                      <th className="right">Qty</th>
                      <th className="right">Price</th>
                      <th className="right">Amount</th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.lines.map((l, i) => {
                      const pr = priceOf(l);
                      const isTop = l === d.highest && d.lines.length > 1;
                      return (
                        <tr key={`${l.order}-${i}`} className={isTop ? 'is-top' : undefined}>
                          <td className="ps-num">{dm(l.date)}</td>
                          <td>{l.rep || '—'}</td>
                          <td className="tiny">{l.order}</td>
                          <td className="right ps-num">
                            {l.kg ? kgText(l.kg) : `${l.qty} ${l.uom}`}
                            {l.rolls ? <div className="tiny dim">{plural(l.rolls, 'roll')}</div> : null}
                          </td>
                          <td className="right ps-num">
                            {pr.value ? priceText(pr.value, pr.per, c) : '—'}
                            {isTop && <div className="tiny ps-top">highest</div>}
                          </td>
                          <td className="right ps-num">{money(l.amount, c)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </Card>
          </div>
        </>
      )}
    </div>
  );
}
