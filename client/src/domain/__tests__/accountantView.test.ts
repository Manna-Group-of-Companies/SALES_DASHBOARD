/**
 * What the accountant sees of an order at Hi-Tech: the delivery once there is
 * one, the sales order until then.
 */

import { describe, expect, it } from 'vitest';
import { accountantView, matchesSearch, tabOf, type AcctLineInput, type AcctOrderInput } from '../accountantView';

function line(p: Partial<AcctLineInput> & { item: string }): AcctLineInput {
  return {
    item_name: `${p.item} name`,
    rolls: 0,
    ordered_kg: 0,
    amount: 0,
    rate_per_kg: 0,
    delivered_kg: 0,
    invoiced_kg: 0,
    ...p,
  };
}

function order(p: Partial<AcctOrderInput>): AcctOrderInput {
  return { sap_sales_order: '501', sap_status: 'bost_Open', lines: [], delivery_refs: [], ...p };
}

const twoLines = [
  line({ item: 'I-1', rolls: 4, ordered_kg: 60, amount: 11940, rate_per_kg: 199 }),
  line({ item: 'I-2', rolls: 2, ordered_kg: 36, amount: 6120, rate_per_kg: 170 }),
];

describe('accountantView', () => {
  it('shows the sales order while nothing has been delivered', () => {
    const v = accountantView(order({ lines: twoLines }));
    expect(v.state).toBe('awaiting');
    expect(v.shows).toBe('sales_order');
    expect(v.lines).toEqual([
      { item: 'I-1', itemName: 'I-1 name', kg: 60, rolls: 4, rate: 199, amount: 11940 },
      { item: 'I-2', itemName: 'I-2 name', kg: 36, rolls: 2, rate: 170, amount: 6120 },
    ]);
    expect(v.totalKg).toBe(96);
    expect(v.total).toBe(18060);
    expect(v.deliveries).toEqual([]);
  });

  it('shows only the delivery once one exists — short kilos, and an undelivered line left off', () => {
    const v = accountantView(
      order({
        sap_status: 'bost_Close',
        lines: [{ ...twoLines[0], delivered_kg: 55.5 }, twoLines[1]],
        delivery_refs: ['DN 6 (26-09-2026)', 'DN 6 (26-09-2026)'],
      }),
    );
    expect(v.state).toBe('delivered');
    expect(v.shows).toBe('delivery');
    expect(v.lines).toEqual([{ item: 'I-1', itemName: 'I-1 name', kg: 55.5, rolls: null, rate: 199, amount: 11044.5 }]);
    expect(v.total).toBe(11044.5);
    expect(v.deliveries).toEqual(['DN 6 (26-09-2026)']);
  });

  it('a delivery against an order Hi-Tech has not closed is a part delivery', () => {
    const v = accountantView(order({ lines: [{ ...twoLines[0], delivered_kg: 20 }, twoLines[1]] }));
    expect(v.state).toBe('part_delivered');
    expect(v.shows).toBe('delivery');
    expect(v.totalKg).toBe(20);
  });

  it('delivered and invoiced counts the delivery only, never both', () => {
    const v = accountantView(
      order({
        sap_status: 'bost_Close',
        lines: [
          { ...twoLines[0], delivered_kg: 60, invoiced_kg: 60 },
          { ...twoLines[1], invoiced_kg: 36 },
        ],
      }),
    );
    expect(v.shows).toBe('delivery');
    expect(v.lines.map((l) => [l.item, l.kg])).toEqual([['I-1', 60]]);
  });

  it('invoiced straight from the order, with no delivery note, still shows the sales order', () => {
    const v = accountantView(
      order({ sap_status: 'bost_Close', lines: [{ ...twoLines[0], invoiced_kg: 60 }, twoLines[1]] }),
    );
    expect(v.state).toBe('invoiced');
    expect(v.shows).toBe('sales_order');
    expect(v.total).toBe(18060);
  });

  it('closed with nothing delivered, and cancelled, show the sales order', () => {
    expect(accountantView(order({ sap_status: 'bost_Close', lines: twoLines })).state).toBe('closed');
    const c = accountantView(order({ sap_status: 'bost_Cancelled', lines: twoLines }));
    expect(c.state).toBe('cancelled');
    expect(c.shows).toBe('sales_order');
  });

  it('reads SAP status case-blind', () => {
    expect(accountantView(order({ sap_status: 'BOST_CANCELLED', lines: twoLines })).state).toBe('cancelled');
  });

  it('uses the approved price per kilo, not the list rate, as the shared rule does', () => {
    const v = accountantView(
      order({ lines: [line({ item: 'I-9', ordered_kg: 50, amount: 9500, rate_per_kg: 200, delivered_kg: 50 })] }),
    );
    expect(v.lines[0].rate).toBe(190);
    expect(v.lines[0].amount).toBe(9500);
  });

  it('a line ordered by count only falls back to its rate', () => {
    const v = accountantView(order({ lines: [line({ item: 'I-9', rolls: 3, amount: 600, rate_per_kg: 200 })] }));
    expect(v.lines[0]).toMatchObject({ kg: 0, rolls: 3, rate: 200, amount: 600 });
  });
});

describe('tabOf', () => {
  it('groups the states into the screen filters', () => {
    expect(tabOf('delivered')).toBe('delivered');
    expect(tabOf('part_delivered')).toBe('delivered');
    expect(tabOf('awaiting')).toBe('not_delivered');
    expect(tabOf('invoiced')).toBe('not_delivered');
    expect(tabOf('closed')).toBe('not_delivered');
    expect(tabOf('cancelled')).toBe('cancelled');
  });
});

describe('matchesSearch', () => {
  const o = {
    customerName: 'Arun Traders Vadakara',
    customer: 'C-0412',
    name: 'SAL-ORD-2026-00151',
    sapSalesOrder: '452',
    deliveries: ['DN 18 (07-10-2026)'],
  };
  it('finds by customer, either order number or a delivery', () => {
    expect(matchesSearch('arun', o)).toBe(true);
    expect(matchesSearch('00151', o)).toBe(true);
    expect(matchesSearch('452', o)).toBe(true);
    expect(matchesSearch('dn 18', o)).toBe(true);
    expect(matchesSearch('', o)).toBe(true);
    expect(matchesSearch('kochi', o)).toBe(false);
  });
});
