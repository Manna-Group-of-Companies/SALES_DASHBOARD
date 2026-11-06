import { describe, expect, it } from 'vitest';
import type { SoldLine } from '@/api/productSales';
import { bestAndSlowest, byDay, byProduct, mostExpensiveSale, priceOf, productDetail } from './productSales';

const line = (p: Partial<SoldLine>): SoldLine => ({
  order: 'SO-1',
  date: '2026-11-02',
  company: 'Manna Treads',
  rep: 'Amjad Pr',
  itemCode: 'A',
  itemName: 'Tread A',
  amount: 0,
  kg: 0,
  rolls: 0,
  qty: 0,
  uom: '',
  rate: 0,
  ratePerKg: 0,
  ...p,
});

const LINES = [
  line({ order: 'SO-1', itemCode: 'A', itemName: 'Tread A', amount: 1000, kg: 50, date: '2026-11-02' }),
  line({ order: 'SO-2', itemCode: 'A', itemName: 'Tread A', amount: 500, kg: 25, date: '2026-11-03', rep: 'Bibin' }),
  line({ order: 'SO-2', itemCode: 'B', itemName: 'Gum B', amount: 2000, kg: 10, date: '2026-11-03', rep: 'Bibin' }),
  line({ order: 'SO-3', itemCode: 'C', itemName: 'Solution C', amount: 100, kg: 0, date: '2026-11-05' }),
];

describe('byProduct', () => {
  it('ranks by value, counting distinct orders and reps', () => {
    const p = byProduct(LINES, 'amount');
    expect(p.map((x) => x.itemCode)).toEqual(['B', 'A', 'C']);
    expect(p[1]).toMatchObject({ amount: 1500, kg: 75, orders: 2, reps: 2 });
  });
  it('ranks by weight, leaving out what has no weight', () => {
    expect(byProduct(LINES, 'kg').map((x) => x.itemCode)).toEqual(['A', 'B']);
  });
});

describe('byDay and bestAndSlowest', () => {
  const days = byDay(LINES, '2026-11-01', '2026-11-05');
  it('has every day of the range, zero where nothing was ordered', () => {
    expect(days.map((d) => d.date)).toEqual(['2026-11-01', '2026-11-02', '2026-11-03', '2026-11-04', '2026-11-05']);
    expect(days[2]).toMatchObject({ amount: 2500, orders: 1 });
    expect(days[0].amount).toBe(0);
  });
  it('picks the best day, and the slowest among days with orders', () => {
    const r = bestAndSlowest(days, 'amount')!;
    expect(r.best.date).toBe('2026-11-03');
    expect(r.slowest.date).toBe('2026-11-05');
  });
  it('is null when nothing sold', () => {
    expect(bestAndSlowest(byDay([], '2026-11-01', '2026-11-02'), 'amount')).toBeNull();
  });
});

describe('prices', () => {
  const P = [
    line({ order: 'SO-1', itemCode: 'T', rep: 'Amjad Pr', ratePerKg: 300, kg: 50, amount: 15000 }),
    line({ order: 'SO-2', itemCode: 'T', rep: 'Bibin', ratePerKg: 320, kg: 25, amount: 8000, date: '2026-11-04' }),
    line({ order: 'SO-3', itemCode: 'T', rep: 'Amjad Pr', ratePerKg: 290, kg: 25, amount: 7250, date: '2026-11-05' }),
    line({ order: 'SO-4', itemCode: 'G', rep: 'Bibin', rate: 900, uom: 'Nos', qty: 2, amount: 1800 }),
  ];
  it('finds the highest and lowest price, who sold at it, and a weighted average', () => {
    const d = productDetail(P, 'T');
    expect(d.per).toBe('kg');
    expect(d.highest).toMatchObject({ rep: 'Bibin', ratePerKg: 320 });
    expect(d.lowest).toMatchObject({ order: 'SO-3', ratePerKg: 290 });
    expect(d.average).toBeCloseTo((300 * 50 + 320 * 25 + 290 * 25) / 100);
    expect(d.reps.map((r) => [r.rep, r.orders, r.topPrice])).toEqual([
      ['Amjad Pr', 2, 300],
      ['Bibin', 1, 320],
    ]);
  });
  it('prices per unit when nothing was quoted per kg', () => {
    expect(priceOf(P[3])).toEqual({ value: 900, per: 'Nos' });
  });
  it('the most expensive sale is the highest per-kg price', () => {
    expect(mostExpensiveSale(P)).toMatchObject({ order: 'SO-2', rep: 'Bibin' });
  });
});
