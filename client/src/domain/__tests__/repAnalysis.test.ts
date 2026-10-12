import { describe, expect, it } from 'vitest';
import {
  alignedSeries,
  bucketKey,
  bucketsBetween,
  byCustomer,
  byGroup,
  change,
  comparisonRange,
  dso,
  outstandingSeries,
  presetRange,
  series,
  totals,
  trendSlope,
  type OutstandingPoint,
  type SaleLine,
} from '../repAnalysis';

const line = (p: Partial<SaleLine>): SaleLine => ({
  date: '2026-09-01',
  rep: 'Amjad Pr',
  customer: 'C1',
  customerName: 'Arun Traders',
  group: 'FG - TRP - Black Pearl',
  amount: 1000,
  kg: 4,
  order: 'O1',
  ...p,
});

describe('buckets', () => {
  it('keys a week by its Monday, a month by its 1st, a quarter by its first month', () => {
    expect(bucketKey('2026-10-11', 'week')).toBe('2026-10-05'); // a Sunday
    expect(bucketKey('2026-10-12', 'week')).toBe('2026-10-12'); // the Monday after
    expect(bucketKey('2026-10-11', 'month')).toBe('2026-10-01');
    expect(bucketKey('2026-08-31', 'quarter')).toBe('2026-07-01');
  });

  it('includes empty buckets, so a month with no sales still shows', () => {
    const b = bucketsBetween({ from: '2026-01-15', to: '2026-04-02' }, 'month');
    expect(b.map((x) => x.key)).toEqual(['2026-01-01', '2026-02-01', '2026-03-01', '2026-04-01']);
    expect(b[1].end).toBe('2026-02-28');
    expect(b[0].label).toBe('Jan 26');
  });
});

describe('comparison ranges', () => {
  it('previous period is the same length, ending the day before', () => {
    expect(comparisonRange({ from: '2026-10-01', to: '2026-10-10' }, 'previous')).toEqual({
      from: '2026-09-21',
      to: '2026-09-30',
    });
  });

  it('last year shifts both ends back a year', () => {
    expect(comparisonRange({ from: '2026-04-01', to: '2026-10-11' }, 'lastYear')).toEqual({
      from: '2025-04-01',
      to: '2025-10-11',
    });
  });

  it('none is none', () => {
    expect(comparisonRange({ from: '2026-04-01', to: '2026-10-11' }, 'none')).toBeUndefined();
  });

  it('the financial year starts on 1 April', () => {
    expect(presetRange('fy', '2026-02-10').from).toBe('2025-04-01');
    expect(presetRange('fy', '2026-10-11').from).toBe('2026-04-01');
  });
});

describe('totals and change', () => {
  it('counts orders and customers, not lines', () => {
    const t = totals([line({}), line({ amount: 500, kg: 2 }), line({ order: 'O2', customer: 'C2' })]);
    expect(t).toMatchObject({ amount: 2500, kg: 10, orders: 2, customers: 2, perKg: 250 });
  });

  it('has no percentage against nothing', () => {
    expect(change(100, 0)).toBeNull();
    expect(change(150, 100)).toBeCloseTo(0.5);
  });
});

describe('series', () => {
  it('sums into buckets and counts distinct orders per bucket', () => {
    const b = bucketsBetween({ from: '2026-09-01', to: '2026-10-31' }, 'month');
    const s = series([line({}), line({}), line({ date: '2026-10-03', order: 'O2' })], b, 'month');
    expect(s.map((p) => [p.amount, p.orders])).toEqual([[2000, 1], [1000, 1]]);
  });

  it('lines the comparison up bucket for bucket, dropping any surplus', () => {
    const s = alignedSeries([line({ date: '2025-09-02' })], { from: '2025-09-01', to: '2025-11-30' }, 'month', 2);
    expect(s).toHaveLength(2);
    expect(s[0].amount).toBe(1000);
  });

  it('reads a trend as a fraction of the mean per bucket', () => {
    expect(trendSlope([100, 110, 120, 130])).toBeCloseTo(10 / 115);
    expect(trendSlope([5])).toBe(0);
  });
});

describe('customers', () => {
  const b = bucketsBetween({ from: '2026-09-01', to: '2026-09-30' }, 'month');

  it('keeps a customer who bought only last period, flagged as stopped', () => {
    const rows = byCustomer([], [line({ date: '2026-08-10' })], [], b, 'month', 'amount', '2026-09-30');
    expect(rows).toHaveLength(1);
    expect(rows[0].flags).toContain('lost');
  });

  it('flags gone quiet past the threshold, and new against an earlier period', () => {
    const rows = byCustomer(
      [line({ date: '2026-09-01' })],
      [line({ customer: 'C9', date: '2026-08-01' })],
      [],
      b,
      'month',
      'amount',
      '2026-10-30',
      45,
    );
    const c1 = rows.find((r) => r.customer === 'C1')!;
    expect(c1.flags).toEqual(expect.arrayContaining(['new', 'dormant']));
    expect(c1.daysSinceLast).toBe(59);
  });
});

describe('products', () => {
  it('ranks by the chosen measure and gives each a rate', () => {
    const g = byGroup([line({}), line({ group: 'Cushion Gum', amount: 300, kg: 10 })], 'kg');
    expect(g[0].group).toBe('Cushion Gum');
    expect(g[1].perKg).toBe(250);
  });
});

describe('outstanding', () => {
  const pt = (date: string, customer: string, total: number, d90 = 0): OutstandingPoint => ({
    date, rep: 'Amjad Pr', customer, total, d0_30: total - d90, d30_60: 0, d60_90: 0, d90,
  });

  it('is a level: the last snapshot per customer by bucket end, never a sum of snapshots', () => {
    const b = bucketsBetween({ from: '2026-09-01', to: '2026-10-31' }, 'month');
    const s = outstandingSeries(
      [pt('2026-09-07', 'A', 100), pt('2026-09-28', 'A', 300), pt('2026-09-14', 'B', 50, 50), pt('2026-10-05', 'A', 0)],
      b,
    );
    expect(s.map((x) => x.total)).toEqual([350, 50]);
    expect(s[1].d90).toBe(50);
  });

  it('turns outstanding into days of sales', () => {
    expect(dso(30_000, 30_000, { from: '2026-09-01', to: '2026-09-30' })).toBeCloseTo(30);
    expect(dso(1000, 0, { from: '2026-09-01', to: '2026-09-30' })).toBe(0);
  });
});
