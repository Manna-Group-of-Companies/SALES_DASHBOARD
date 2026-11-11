import { describe, expect, it } from 'vitest';
import { buildRepCustomers, initials, shortDate, statusOf } from './repCustomers';
import type { SalesCustomer } from '@/domain/types';

const cust = (id: string, name: string, extra: Partial<SalesCustomer> = {}): SalesCustomer => ({
  id,
  name,
  creditLimit: 0,
  outstanding: 0,
  outstanding0_30: 0,
  outstanding30_60: 0,
  outstanding60_90: 0,
  outstanding90Plus: 0,
  overduePastTerms: 0,
  overdueDays: 0,
  latitude: 0,
  longitude: 0,
  ...extra,
});

describe('buildRepCustomers', () => {
  const rows = buildRepCustomers(
    [
      cust('C1', 'Alpha Rubber', { outstanding: 50000, overduePastTerms: 20000, overdueDays: 12 }),
      cust('C2', 'Beta Treads', { outstanding: 10000 }),
      cust('C3', 'Gamma Tyres'),
    ],
    [
      { id: 'SO-1', customer: 'C1', customerName: 'Alpha Rubber', placedOn: '2026-11-02', netTotal: 30000, sapInvoice: '901' },
      { id: 'SO-2', customer: 'C1', customerName: 'Alpha Rubber', placedOn: '2026-11-04', netTotal: 5000 },
      { id: 'SO-3', customer: 'X9', customerName: 'Stranger Co', placedOn: '2026-11-03', netTotal: 1000 },
    ],
    [
      { order: 'SO-1', customerName: 'Alpha Rubber', itemName: 'A', invoice: '901', invoiceDate: '2026-11-03', amount: 20000, kg: 10 },
      { order: 'SO-1', customerName: 'Alpha Rubber', itemName: 'B', invoice: '901', invoiceDate: '2026-11-03', amount: 10000, kg: 5 },
      // Ordered last month, invoiced this month: matched by name.
      { order: 'SO-0', customerName: 'beta treads', itemName: 'C', invoice: '902', invoiceDate: '2026-11-01', amount: 4000, kg: 2 },
    ],
  );
  const by = (n: string) => rows.find((r) => r.name === n)!;

  it('adds up orders and groups invoice lines per invoice', () => {
    const a = by('Alpha Rubber');
    expect(a.orders).toHaveLength(2);
    expect(a.ordered).toBe(35000);
    expect(a.lastOrder).toBe('2026-11-04');
    expect(a.invoices).toEqual([{ invoice: '901', date: '2026-11-03', orders: ['SO-1'], amount: 30000 }]);
    expect(a.invoiced).toBe(30000);
    expect(by('Beta Treads').invoiced).toBe(4000);
  });

  it('keeps a customer only known from an order, with nothing owed claimed', () => {
    const s = by('Stranger Co');
    expect(s.assigned).toBe(false);
    expect(s.outstanding).toBeNull();
    expect(statusOf(s)).toBe('unknown');
  });

  // 11 Nov 2026: Drona Tyres and its demo copy had one name; the real one's
  // orders were matched by name and shown under the copy.
  it('keeps two customers of one name apart', () => {
    const two = buildRepCustomers(
      [cust('C-DEMO', 'Drona Tyres', { outstanding: 174081 })],
      [
        { id: 'SO-7', customer: 'C-DEMO', customerName: 'Drona Tyres', placedOn: '2026-11-10', netTotal: 6808 },
        { id: 'SO-8', customer: 'C-REAL', customerName: 'Drona Tyres', placedOn: '2026-11-06', netTotal: 90000 },
      ],
      [],
    );
    expect(two).toHaveLength(2);
    expect(two.find((r) => r.id === 'C-DEMO')!.ordered).toBe(6808);
    const real = two.find((r) => r.id === 'C-REAL')!;
    expect(real.ordered).toBe(90000);
    expect(real.assigned).toBe(false);
  });

  it('labels what each owes', () => {
    expect(statusOf(by('Alpha Rubber'))).toBe('overdue');
    expect(statusOf(by('Beta Treads'))).toBe('owes');
    expect(statusOf(by('Gamma Tyres'))).toBe('clear');
  });

  it('puts the most invoiced first', () => {
    expect(rows[0].name).toBe('Alpha Rubber');
  });
});

describe('helpers', () => {
  it('formats', () => {
    expect(shortDate('2026-11-05')).toBe('05 Nov 2026');
    expect(shortDate(undefined)).toBe('—');
    expect(initials('Test Demo Rep')).toBe('TD');
  });
});
