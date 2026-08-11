/**
 * Approvals, escalation, GM exemptions, weeks, the 1 pm freeze and the money
 * identities on an order line.
 *
 * These are the rules that must not differ between the two applications.
 */

import { describe, expect, it } from 'vitest';
import {
  boundByCutoff,
  boundByOwnership,
  creditPicture,
  escalates,
  isApproved,
  isSet,
  productionLine,
  rateEditable,
  statusPill,
  tickState,
  PO_STATUS,
  LEAD_ORDER_STATUS_VALUES,
  canEscalateLeadOrder,
} from '../orderStatus';
import { canStartOrder } from '../sales';
import {
  isClosed,
  lastClosedWeek,
  mondayOf,
  pastCutoff,
  recentWeeks,
  shiftWeek,
  weekOf,
} from '../weeks';
import { orderLineValues } from '../productRules';
import { parseItemName, distinctOf, worthOffering } from '../itemNaming';
import type { Product } from '../types';

describe('the status pill never leaks the stored string', () => {
  it('says nothing about POs or SAP for any stored value', () => {
    const stored = [...Object.values(PO_STATUS), '', null, undefined, 'something unexpected'];
    for (const s of stored) {
      const text = statusPill(s as string).text;
      expect(text).not.toMatch(/\bPO\b/);
      expect(text).not.toMatch(/SAP/i);
    }
  });

  it('maps each stored value to its rep-facing label', () => {
    expect(statusPill(PO_STATUS.approved)).toEqual({ text: 'APPROVED', tone: 'ok' });
    expect(statusPill(PO_STATUS.pending).text).toBe('WAITING FOR MANAGER APPROVAL');
    expect(statusPill(PO_STATUS.poUploaded).text).toBe('WAITING FOR MANAGER APPROVAL');
    expect(statusPill(PO_STATUS.pendingRate).text).toBe('WAITING FOR RATE APPROVAL');
    expect(statusPill(PO_STATUS.pendingGm).text).toBe('ESCALATED TO GM');
    expect(statusPill(PO_STATUS.rejected)).toEqual({ text: 'REJECTED', tone: 'danger' });
  });

  it('treats an unknown status as needing attention, never as approved', () => {
    expect(statusPill('who knows').tone).toBe('warn');
    expect(isApproved('who knows')).toBe(false);
  });
});

describe('escalation is on the customer’s credit limit', () => {
  it('escalates when the order takes them past it', () => {
    expect(escalates({ outstanding: 120000, creditLimit: 150000, orderTotal: 45000 })).toBe(true);
  });

  it('does not escalate exactly at the limit', () => {
    expect(escalates({ outstanding: 100000, creditLimit: 150000, orderTotal: 50000 })).toBe(false);
  });

  it('does not escalate when no limit is recorded', () => {
    // All 620 customers currently have a zero limit, so nothing escalates yet.
    expect(escalates({ outstanding: 999999, creditLimit: 0, orderTotal: 45000 })).toBe(false);
  });

  it('never escalates a lead — no limit, no trading history', () => {
    expect(
      escalates({ outstanding: 120000, creditLimit: 150000, orderTotal: 45000, isLead: true }),
    ).toBe(false);
  });

  it('produces the GM card’s five figures', () => {
    const p = creditPicture({ outstanding: 120000, creditLimit: 150000, orderTotal: 45000 });
    expect(p).toEqual({
      outstanding: 120000,
      orderTotal: 45000,
      projected: 165000,
      creditLimit: 150000,
      over: 15000,
    });
  });
});

describe('the three GM exemptions, and nobody else gets them', () => {
  const others = ['sales_manager', 'production_manager', 'stock_manager', 'hr', undefined];

  it('exempts the GM from the 1 pm freeze', () => {
    expect(boundByCutoff('general_manager')).toBe(false);
    for (const r of others) expect(boundByCutoff(r)).toBe(true);
  });

  it('exempts the GM from the rep/manager ownership rule', () => {
    expect(boundByOwnership('general_manager')).toBe(false);
    for (const r of others) expect(boundByOwnership(r)).toBe(true);
  });

  it('lets ONLY the GM change a rate the sales manager locked', () => {
    expect(rateEditable('general_manager', true)).toBe(true);
    for (const r of others) expect(rateEditable(r, true)).toBe(false);
  });

  it('leaves an unlocked rate editable by everyone', () => {
    for (const r of [...others, 'general_manager']) expect(rateEditable(r, false)).toBe(true);
  });
});

describe('a lead order cannot be escalated on this site', () => {
  it('has no Pending GM Approval option in its Select', () => {
    expect(LEAD_ORDER_STATUS_VALUES).not.toContain('Pending GM Approval');
    expect(canEscalateLeadOrder()).toBe(false);
  });
});

describe('a route is mandatory before an order', () => {
  it('accepts a real route', () => {
    expect(canStartOrder({ route: 'Pareeth - Aluva' })).toBe(true);
  });

  it('refuses every flavour of "not set"', () => {
    for (const r of ['', '   ', null, undefined, 'null']) {
      expect(canStartOrder({ route: r as string })).toBe(false);
    }
  });

  it('isSet agrees, including on the literal string null', () => {
    expect(isSet('null')).toBe(false);
    expect(isSet('')).toBe(false);
    expect(isSet('Pareeth - Aluva')).toBe(true);
  });
});

describe('weeks are Monday to Sunday, on the date only', () => {
  it('puts Sunday 23:55 and Monday 00:05 in different weeks', () => {
    expect(weekOf(new Date(2026, 7, 9, 23, 55)).start).toBe('2026-08-03');
    expect(weekOf(new Date(2026, 7, 10, 0, 5)).start).toBe('2026-08-10');
  });

  it('treats a Monday as its own week start', () => {
    expect(mondayOf(new Date(2026, 7, 10)).getDate()).toBe(10);
  });

  it('offers thirteen weeks', () => {
    expect(recentWeeks(new Date(2026, 7, 8), 13)).toHaveLength(13);
  });

  it('opens close-the-week on the last FINISHED week', () => {
    const w = lastClosedWeek(new Date(2026, 7, 8)); // Sat 8 Aug
    expect(w.start).toBe('2026-07-27');
    expect(isClosed(w, new Date(2026, 7, 8))).toBe(true);
  });

  it('will not step forward into a week still running', () => {
    const current = weekOf(new Date(2026, 7, 8));
    expect(isClosed(current, new Date(2026, 7, 8))).toBe(false);
    expect(isClosed(shiftWeek(current, -1), new Date(2026, 7, 8))).toBe(true);
  });
});

describe('the 1 pm freeze', () => {
  it('closes at exactly 13:00 on the delivery date', () => {
    expect(pastCutoff('2026-08-13', new Date(2026, 7, 13, 12, 59))).toBe(false);
    expect(pastCutoff('2026-08-13', new Date(2026, 7, 13, 13, 0))).toBe(true);
  });

  it('leaves an order with NO delivery date permanently OPEN', () => {
    // A missing date is a data problem; refusing edits would make it permanent.
    expect(pastCutoff(undefined, new Date(2099, 0, 1))).toBe(false);
    expect(pastCutoff('', new Date(2099, 0, 1))).toBe(false);
  });
});

describe('the completion tick is derived, and names the state', () => {
  it('maps the four production statuses', () => {
    expect(tickState('Dispatched')).toBe('complete');
    expect(tickState('Ready')).toBe('ready');
    expect(tickState('In Production')).toBe('in_production');
    expect(tickState('')).toBe('not_started');
  });

  it('rounds an unrecognised status down', () => {
    expect(tickState('Curing')).toBe('not_started');
  });
});

describe('the production line under an order row', () => {
  it('says nothing at all before approval', () => {
    expect(productionLine({ poStatus: PO_STATUS.pending, productionStatus: 'In Production' }))
      .toBeNull();
  });

  it('says a finished order plainly', () => {
    const l = productionLine({ poStatus: PO_STATUS.approved, productionStatus: 'Dispatched' });
    expect(l).toEqual({ text: 'Order complete — dispatched', done: true });
    expect(l!.text).not.toContain('Production: Dispatched');
  });

  it('keeps the stage name for anything short of finished', () => {
    expect(
      productionLine({ poStatus: PO_STATUS.approved, productionStatus: 'Ready' })!.text,
    ).toBe('Production: Ready');
  });
});

describe('the money identities on an order line', () => {
  // The live item behind SAL-ORD-2026-00104.
  const ajax: Product = {
    code: 'AJAX',
    name: 'AJAX',
    category: 'PCTR',
    weightPerBelt: 2.4,
    beltsPerRoll: 14,
    weightPerRoll: 33.6,
    active: true,
  };

  it('reproduces the live line exactly', () => {
    const v = orderLineValues(ajax, { rolls: 9, looseBelts: 0, ratePerKg: 32 });
    expect(v.qty).toBe(9);
    expect(v.rate).toBe(1075.2);
    expect(v.amount).toBe(9676.8);
    expect(v.totalWeight).toBe(302.4);
    expect(v.packingNote).toBe('9 rolls · 302.40 kg (avg)');
  });

  it('keeps BOTH identities when loose belts are involved', () => {
    const v = orderLineValues(ajax, { rolls: 9, looseBelts: 7, ratePerKg: 32 });
    expect(v.qty * v.rate).toBeCloseTo(v.amount, 2);
    expect(v.totalWeight * 32).toBeCloseTo(v.amount, 2);
  });

  it('does not give the belts away, which a bare roll count would', () => {
    const v = orderLineValues(ajax, { rolls: 9, looseBelts: 7, ratePerKg: 32 });
    expect(9 * v.rate).toBeLessThan(v.amount);
  });

  it('prices a misconfigured item at zero rather than at Infinity', () => {
    const broken: Product = { code: 'B', name: 'B', category: 'PCTR', active: true };
    const v = orderLineValues(broken, { rolls: 5, ratePerKg: 30 });
    expect(Number.isFinite(v.qty)).toBe(true);
    expect(v.qty).toBe(0);
  });
});

describe('quality and pattern parsed from the item name', () => {
  it('parses the documented shape', () => {
    expect(parseItemName('TREAD RUBBER PRECURED  BLACK PEARL  130  VK  90')).toEqual({
      quality: 'BLACK PEARL',
      width: 130,
      pattern: 'VK',
      parsed: true,
    });
  });

  it('keeps BLACK PEARL and BLACK PEARL B distinct', () => {
    expect(parseItemName('TREAD RUBBER PRECURED BLACK PEARL B 174 MLG 120').quality).toBe(
      'BLACK PEARL B',
    );
  });

  it('survives the mojibake in the master', () => {
    expect(parseItemName('TREAD RUBBER PRECURED BLACK PEARL 93Â€ RTS 99').quality).toBe(
      'BLACK PEARL',
    );
  });

  it('strips the LONGEST matching prefix', () => {
    expect(parseItemName('TREAD RUBBER PRECURED BLACK PEARL 102 EA 60').quality).toBe('BLACK PEARL');
    expect(parseItemName('PCTR 240 MSP 133 MG').quality).toBeUndefined();
  });

  it('soft-fails a name with no pattern, keeping the quality', () => {
    const p = parseItemName('BONDING GUM 5');
    expect(p.parsed).toBe(false);
    expect(p.quality).toBe('BONDING GUM');
  });

  it('leaves unparsed names out of the dropdowns but never filters the row', () => {
    const names = ['TREAD RUBBER PRECURED BLACK PEARL 120 AJAX 69', 'BONDING GUM 5'];
    expect(distinctOf(names, (p) => p.pattern)).toEqual(['AJAX']);
  });

  it('hides a dropdown that would offer only one value', () => {
    expect(worthOffering(['BLACK PEARL'])).toBe(false);
    expect(worthOffering(['BLACK PEARL', 'BLACK PEARL B'])).toBe(true);
  });
});
