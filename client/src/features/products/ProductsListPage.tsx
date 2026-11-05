/**
 * Product Sales — Products: every product sold in the month, best first, with
 * today's stock. A row opens the product's own page (5 Nov 2026).
 */

import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Badge, Card, Icon, Skeleton } from '@/components/ui';
import { byProduct } from './productSales';
import { ReportHead, kgText, money, plural, stockState, useReportFilters, useSoldLines, useStock } from './shared';
import '@/components/layout/layout.css';

export function ProductsListPage() {
  const f = useReportFilters();
  const navigate = useNavigate();
  const [tick, setTick] = useState(0);
  const [q, setQ] = useState('');
  const { lines, loading, error } = useSoldLines(f.from, f.to, f.scope.companies, tick);
  const { stock, loaded, failed } = useStock(tick);
  const c = f.scope.currency;
  const m = f.measure;

  const products = useMemo(() => byProduct(lines, m), [lines, m]);
  const sum = products.reduce((n, p) => n + p[m], 0);
  const top = products[0];
  const pctText = (v: number) => {
    const p = sum > 0 ? Math.round((v / sum) * 100) : 0;
    return v > 0 && p === 0 ? '<1%' : `${p}%`;
  };
  const soldOut = loaded && !failed ? products.filter((p) => stockState(stock.get(p.itemCode), true).label === 'Sold out').length : 0;

  const needle = q.trim().toLowerCase();
  const shown = needle ? products.filter((p) => `${p.itemName} ${p.itemCode}`.toLowerCase().includes(needle)) : products;
  const open = (code: string) => navigate(`/product-sales/products/${encodeURIComponent(code)}${f.query}`);

  return (
    <div>
      <ReportHead
        f={f}
        title="Products"
        sub={
          loading
            ? 'Every product sold in the month, best first.'
            : `${plural(products.length, 'product')} sold in ${f.monthLabel}${soldOut ? `; ${soldOut} of them sold out today` : ''}. Click one to see its prices and who sold it.`
        }
        loading={loading}
        onRefresh={() => setTick((t) => t + 1)}
        error={error}
      />

      <Card flush>
        <div className="ps-tools">
          <label className="ps-search" style={{ marginLeft: 0 }}>
            <Icon name="search" size={15} />
            <input placeholder="Search product or code" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search products" />
          </label>
        </div>
        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr>
                <th className="right" style={{ width: 40 }}>
                  #
                </th>
                <th>Product</th>
                <th style={{ minWidth: 160 }}>Share</th>
                <th className="right">Value</th>
                <th className="right">Weight</th>
                <th className="right">Orders</th>
                <th>Stock today</th>
                <th style={{ width: 28 }} />
              </tr>
            </thead>
            <tbody>
              {loading &&
                [0, 1, 2, 3].map((i) => (
                  <tr key={i}>
                    <td colSpan={8}>
                      <Skeleton height={18} />
                    </td>
                  </tr>
                ))}
              {!loading && shown.length === 0 && (
                <tr>
                  <td colSpan={8} className="ps-empty">
                    {products.length ? 'No products match.' : `Nothing sold in ${f.scope.label}, ${f.monthLabel}.`}
                  </td>
                </tr>
              )}
              {!loading &&
                shown.map((p) => {
                  const st = stockState(stock.get(p.itemCode), loaded);
                  return (
                    <tr
                      key={p.itemCode}
                      className="ps-row"
                      tabIndex={0}
                      onClick={() => open(p.itemCode)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') open(p.itemCode);
                      }}
                    >
                      <td className="right dim">{products.indexOf(p) + 1}</td>
                      <td>
                        <div className="ps-pname">{p.itemName}</div>
                        <div className="tiny dim">{p.itemCode}</div>
                      </td>
                      <td>
                        <div className="ps-share">
                          <div className="ps-share__track">
                            <i style={{ width: `${top ? (p[m] / top[m]) * 100 : 0}%` }} />
                          </div>
                          <span className="tiny">{pctText(p[m])}</span>
                        </div>
                      </td>
                      <td className="right ps-num">{money(p.amount, c)}</td>
                      <td className="right ps-num">{p.kg ? kgText(p.kg) : <span className="dim">—</span>}</td>
                      <td className="right">{p.orders}</td>
                      <td>{failed ? <span className="tiny dim">—</span> : <Badge tone={st.tone}>{st.label}</Badge>}</td>
                      <td className="ps-chev">
                        <Icon name="chevronRight" size={16} />
                      </td>
                    </tr>
                  );
                })}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}
