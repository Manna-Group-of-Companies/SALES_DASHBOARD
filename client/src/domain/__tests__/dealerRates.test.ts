/**
 * The MD's rates screen, against shared/fixtures/dealer_rates.json — the same
 * cases sap-pricing/Test-RupeeRules.ps1 runs, so the screen and the office
 * server's own check cannot disagree about a dealer's price or a Hi-Tech price.
 */

import { describe, expect, it } from 'vitest';
import fx from '../../../../shared/fixtures/dealer_rates.json';
import {
  buildDtwFiles,
  buildPlan,
  checkAgainstSap,
  checkCounts,
  compareServerCheck,
  badRules,
  diffRules,
  hitechByQuality,
  staleRules,
  hitechPrice,
  itemKind,
  roundMoney,
  ruleSignature,
  specialPrice,
  summariseCheck,
  summariseDealers,
  summariseQualities,
  type DealerRule,
  type HitechItem,
  type PricingSnapshot,
  type QualityChange,
  type ServerCheck,
  type SnapItem,
} from '../dealerRates';
import { expandSnapshot } from '@/api/pricing';

function item(code: string, props: number[], listPrice: number | null, twin: string | null = null, type = 'PRECURED'): SnapItem {
  return { code, name: code, group: 116, type, quality: '', uom: 'KGS', stock: 0, sales: true, frozen: false, updated: '2026-09-25', props, listPrice, currency: 'INR', twin };
}

const change = (propertyNo: number, rupees: number): QualityChange => ({ propertyNo, rupees });

function hitechItem(code: string, listPrice: number | null): HitechItem {
  return { code, name: code, listPrice, currency: 'INR' };
}

function snapshot(items: SnapItem[], special: PricingSnapshot['special'] = [], hitech?: HitechItem[], properties = [ { no: 1, name: 'PCTR - Black Pearl' }, { no: 2, name: 'PCTR - Platinum' } ]): PricingSnapshot {
  return {
    version: 3,
    company: 'MANNA_TREADS_LIVE',
    companyName: 'Manna Treads',
    priceList: { no: 1, name: 'selling price' },
    syncedAt: '2026-09-25 12:00:00',
    properties,
    items,
    customers: [ { code: 'A', name: 'Dealer A', priceList: 1, active: true }, { code: 'B', name: 'Dealer B', priceList: 1, active: true } ],
    special,
    hitech: hitech ? { company: 'HITECH_PRETREADS_LIVE', companyName: 'Hi-Tech Pretreads', priceList: { no: 1, name: 'Price List 01' }, items: hitech } : undefined,
  };
}

const rule = (cardCode: string, propertyNo: number, rupeesOff: number): DealerRule => ({ cardCode, cardName: `Dealer ${cardCode}`, propertyNo, quality: '', rupeesOff });
const fixed = (card: string, itemCode: string, price: number, priceList = 0, valid = true) => ({ card, item: itemCode, price, currency: 'INR', discount: 0, priceList, autoUpdate: false, valid });

describe('a dealer price is list minus rupees (shared fixture)', () => {
  for (const c of fx.special_price) {
    it(c.why, () => {
      const r = specialPrice(c.list, c.rupees);
      expect(r.ok).toBe(true);
      if (r.ok) {
        expect(r.price).toBe(c.price);
        expect(r.percent).toBeCloseTo(c.percent, 6);
      }
    });
  }
  for (const c of fx.refused) {
    it(c.why, () => {
      const r = specialPrice(c.list, c.rupees);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.error).toContain(c.error);
    });
  }
  for (const c of fx.rounding) {
    it(c.why, () => expect(roundMoney(c.value)).toBe(c.expect));
  }
});

describe("Hi-Tech's price is Manna Treads' less the margin (shared fixture)", () => {
  for (const c of fx.hitech_price) {
    it(c.why, () => {
      const r = hitechPrice(c.treads, c.margin);
      expect(r.ok).toBe(true);
      if (r.ok) expect(r.price).toBe(c.hitech);
    });
  }
  for (const c of fx.hitech_refused) {
    it(c.why, () => {
      const r = hitechPrice(c.treads, c.margin);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.error).toContain(c.error);
    });
  }
});

describe('the type is read from the item (shared fixture)', () => {
  for (const c of fx.item_kind) {
    it(c.why, () => expect(itemKind({ type: c.type, name: c.name })).toBe(c.kind));
  }
});

describe('a change to a group (item property) moves every item carrying it (shared fixture)', () => {
  const q = fx.quality_change;
  const snap = snapshot(
    q.items.map((i) => item(i.code, i.props, i.listPrice, i.twin, i.type)),
    [],
    q.hitech.map((h) => hitechItem(h.code, h.listPrice)),
    q.properties,
  );
  const rules = q.rules.map((r) => rule(r.cardCode, r.propertyNo, r.rupeesOff));
  const plan = buildPlan(snap, rules, q.changes, q.margin);

  it(q.why, () => {
    const list: Record<string, number> = {};
    for (const i of snap.items) list[i.code] = plan.listChanges.find((c) => c.item.code === i.code)?.newPrice ?? Number(i.listPrice);
    expect(list).toEqual(q.expect_list);
    const dealer: Record<string, number> = {};
    for (const r of plan.dealerRows) dealer[`${r.cardCode}|${r.item.code}`] = r.newPrice;
    expect(dealer).toEqual(q.expect_dealer);
    const hitech: Record<string, number> = {};
    for (const r of plan.hitechRows) hitech[r.hitech.code] = r.newPrice;
    expect(hitech).toEqual(q.expect_hitech);
  });

  it('only the changed groups appear as list changes, each by its own rupees, and only their twins as Hi-Tech changes', () => {
    expect(plan.listChanges.map((c) => [c.item.code, c.quality, c.delta]).sort()).toEqual([
      ['BP-HOT', 'HOT - Black Pearl', 5],
      ['BP-PRE', 'PCTR - Black Pearl', 3],
    ]);
    expect(plan.hitechRows.filter((r) => r.action === 'UPDATE').map((r) => r.hitech.code).sort()).toEqual(q.expect_hitech_changing);
    expect(plan.counts.hitech).toBe(2);
    expect(plan.counts.hitechSame).toBe(1);
  });
});

describe('the check against SAP (shared fixture), as the office server counts it', () => {
  const c = fx.check;
  const snap = snapshot(
    c.items.map((i) => item(i.code, i.props, i.listPrice, i.twin)),
    c.special.map((s) => fixed(s.card, s.item, s.price, s.priceList, (s as { valid?: boolean }).valid ?? true)),
    c.hitech.map((h) => hitechItem(h.code, h.listPrice)),
  );
  const rules = c.rules.map((r) => rule(r.cardCode, r.propertyNo, r.rupeesOff));
  const check = checkAgainstSap(snap, rules, c.margin);

  it(c.why, () => {
    expect(Object.fromEntries(check.rows.map((r) => [r.item.code, r.status]))).toEqual(c.expect_dealer);
    expect(Object.fromEntries(check.hitech.map((r) => [r.item.code, r.status]))).toEqual(c.expect_hitech);
    const counts = checkCounts(check);
    expect(counts.dealer).toEqual(c.expect_dealer_counts);
    expect(counts.hitech).toEqual(c.expect_hitech_counts);
    expect(counts.noTwin).toBe(c.expect_no_twin);
    expect(counts.conflicts).toBe(c.expect_conflicts);
  });

  it('shows the rupees and the margin SAP is really giving', () => {
    expect(check.rows.find((r) => r.item.code === 'BP2')?.sapRupeesOff).toBe(10);
    expect(check.hitech.find((r) => r.item.code === 'BP2')?.sapMargin).toBe(10);
  });
});

describe('the plan', () => {
  it('adds what SAP lacks, updates what moved, leaves the rest', () => {
    const snap = snapshot([item('BP', [1], 185), item('PT', [2], 175)], [fixed('A', 'BP', 180), fixed('A', 'PT', 172)]);
    const plan = buildPlan(snap, [rule('A', 1, 5), rule('A', 2, 3), rule('B', 1, 8)], [change(1, 5)]);
    const byKey = Object.fromEntries(plan.dealerRows.map((r) => [`${r.cardCode}|${r.item.code}`, r.action]));
    expect(byKey).toEqual({ 'A|BP': 'UPDATE', 'A|PT': 'same', 'B|BP': 'ADD' });
  });

  it('turns a percentage special price into a fixed one even at the same price', () => {
    const snap = snapshot([item('PT', [2], 175)], [{ card: 'A', item: 'PT', price: 172, currency: 'INR', discount: 1.71, priceList: 1, autoUpdate: true, valid: true }]);
    expect(buildPlan(snap, [rule('A', 2, 3)], []).dealerRows[0].action).toBe('UPDATE');
  });

  it("refuses an item in two of one dealer's qualities, and reports it as a conflict", () => {
    const plan = buildPlan(snapshot([item('BOTH', [1, 2], 150)]), [rule('A', 1, 5), rule('A', 2, 3)], []);
    expect(plan.dealerRows).toHaveLength(0);
    expect(plan.problems[0].message).toContain('one property only');
    expect(plan.problems[0].kind).toBe('conflict');
  });

  it('never lets a list price fall to zero or below', () => {
    const plan = buildPlan(snapshot([item('BP', [1], 4)]), [], [change(1, -5)]);
    expect(plan.listChanges).toHaveLength(0);
    expect(plan.problems).toHaveLength(1);
  });

  it('lists special prices that no rule stands behind', () => {
    const plan = buildPlan(snapshot([item('BP', [1], 185)], [fixed('B', 'BP', 177)]), [], []);
    expect(plan.orphans).toHaveLength(1);
    expect(plan.orphans[0].cardName).toBe('Dealer B');
  });

  it('works out no Hi-Tech price without a margin, or from a snapshot without Hi-Tech', () => {
    const withHitech = snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 170)]);
    const a = buildPlan(withHitech, [], [], null);
    expect(a.hitechRows).toHaveLength(0);
    expect(a.hitechSkipped).toContain('margin');
    const b = buildPlan(snapshot([item('BP', [1], 185, 'BP')]), [], [], 12);
    expect(b.hitechRows).toHaveLength(0);
    expect(b.hitechSkipped).toContain('Sync from SAP');
  });

  it('counts a Manna Treads item with no twin, and makes it no Hi-Tech price', () => {
    const plan = buildPlan(snapshot([item('BP', [1], 185, null), item('PT', [2], 175, 'PT')], [], [hitechItem('PT', 160)]), [], [], 12);
    expect(plan.noTwin.map((i) => i.code)).toEqual(['BP']);
    expect(plan.hitechRows.map((r) => [r.hitech.code, r.newPrice, r.action])).toEqual([['PT', 163, 'UPDATE']]);
  });

  it('refuses a margin as big as the price, and reports it', () => {
    const plan = buildPlan(snapshot([item('X', [1], 10, 'X')], [], [hitechItem('X', 5)]), [], [], 12);
    expect(plan.hitechRows).toHaveLength(0);
    expect(plan.hitechProblems[0].message).toContain('not less than');
  });
});

describe('the DTW files: at most three CSVs, one per destination', () => {
  const snap = snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]);
  const plan = buildPlan(snap, [rule('A', 1, 5)], [change(1, 5)], 12);
  const opts = {
    treads: { db: 'MANNA_TREADS_LIVE', name: 'Manna Treads', priceListNo: 1 },
    hitech: { db: 'HITECH_PRETREADS_LIVE', name: 'Hi-Tech Pretreads', priceListNo: 1 },
    currency: 'INR',
    stamp: '20260925-1200',
  };
  const files = buildDtwFiles(plan, opts);

  it('Manna Treads price list, Manna Treads dealer prices, Hi-Tech price list — in import order, each for its company', () => {
    expect(files.map((f) => [f.step, f.name, f.company])).toEqual([
      [1, '1-treads-price-list-20260925-1200.csv', 'MANNA_TREADS_LIVE'],
      [2, '2-treads-dealer-prices-20260925-1200.csv', 'MANNA_TREADS_LIVE'],
      [3, '3-hitech-price-list-20260925-1200.csv', 'HITECH_PRETREADS_LIVE'],
    ]);
  });

  it("a price list is DTW's Items_Prices file alone, imported as Update Existing Data", () => {
    expect(files[0].import).toMatchObject({ dtwObject: 'Items (oItems)', dtwMode: 'Update Existing Data', slot: 'Items_Prices' });
    expect(files[0].content).toBe('ParentKey,LineNum,PriceList,Price,Currency\r\nItemCode,LineNum,PriceList,Price,Currency\r\nBP,0,1,190,INR\r\n');
    expect(files[2].content).toBe('ParentKey,LineNum,PriceList,Price,Currency\r\nItemCode,LineNum,PriceList,Price,Currency\r\nBP,0,1,178,INR\r\n');
    expect(files[0].fallback).toEqual({ name: '1-treads-price-list-20260925-1200-Items.csv', content: 'ItemCode\r\nItemCode\r\nBP\r\n' });
  });

  it('the dealer prices are one CSV, new and changed together, each a fixed price', () => {
    expect(files[1].import).toMatchObject({ dtwMode: 'Add New Data and Update Existing Data', slot: 'SpecialPrices' });
    expect(files[1].content).toBe(
      'ItemCode,CardCode,Price,Currency,DiscountPercent,PriceListNum,AutoUpdate\r\nItemCode,CardCode,Price,Currency,Discount,ListNum,AutoUpdt\r\nBP,A,185,INR,0,0,tNO\r\n',
    );
    const both = buildPlan(snapshot([item('BP', [1], 185)], [fixed('A', 'BP', 180)]), [rule('A', 1, 5), rule('B', 1, 8)], [change(1, 5)]);
    expect(both.dealerRows.map((r) => r.action).sort()).toEqual(['ADD', 'UPDATE']);
    const one = buildDtwFiles(both, { ...opts, hitech: null }).filter((f) => f.id === 'treads-dealer-prices');
    expect(one).toHaveLength(1);
    expect(one[0].rows).toBe(2);
    expect(one[0].content.split('\r\n').filter(Boolean)).toHaveLength(4);
  });

  it('only what changes: a dealer-only change is one file, and nothing to do is none', () => {
    const dealerOnly = buildPlan(snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]), [rule('A', 1, 5)], [], 12);
    expect(buildDtwFiles(dealerOnly, opts).map((f) => f.id)).toEqual(['treads-dealer-prices']);
    const quiet = buildPlan(snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]), [], [], 12);
    expect(buildDtwFiles(quiet, opts)).toEqual([]);
  });
});

describe("comparing with the office server's own check", () => {
  const c = fx.check;
  const snap = snapshot(
    c.items.map((i) => item(i.code, i.props, i.listPrice, i.twin)),
    c.special.map((s) => fixed(s.card, s.item, s.price, s.priceList, (s as { valid?: boolean }).valid ?? true)),
    c.hitech.map((h) => hitechItem(h.code, h.listPrice)),
  );
  const rules = c.rules.map((r) => rule(r.cardCode, r.propertyNo, r.rupeesOff));
  const ours = checkCounts(checkAgainstSap(snap, rules, c.margin));
  const server: ServerCheck = { ...ours, margin: c.margin, rules: rules.map(ruleSignature) };

  it('agrees when both counted the same', () => expect(compareServerCheck(server, ours, rules, c.margin)).toEqual({ state: 'agree' }));

  it('says where they disagree', () => {
    const r = compareServerCheck({ ...server, dealer: { ...server.dealer, DRIFT: 2 } }, ours, rules, c.margin);
    expect(r.state).toBe('disagree');
    if (r.state === 'disagree') expect(r.differences[0]).toContain('DRIFT');
  });

  it('does not compare when the rules or the margin have changed since', () => {
    expect(compareServerCheck(server, ours, [...rules, rule('B', 1, 8)], c.margin).state).toBe('stale');
    expect(compareServerCheck(server, ours, rules, 15).state).toBe('stale');
  });

  it('writes a rule the way the office server does', () => {
    expect(ruleSignature(rule('A', 1, 5))).toBe('A|1|5');
    expect(ruleSignature(rule('A', 2, 8.5))).toBe('A|2|8.5');
  });
});

describe('the summaries the screen opens on', () => {
  const groups = [
    { no: 1, name: 'PCTR - Black Pearl' },
    { no: 2, name: 'PCTR - Platinum' },
    { no: 6, name: 'HOT - Black Pearl' },
    { no: 7, name: 'BONDING GUM - Black Pearl' },
  ];
  const snap = snapshot(
    [
      { ...item('BP', [1], 185, 'BP'), type: 'PRECURED' },
      { ...item('BP-H', [6], 175), type: '', name: 'TREAD RUBBER HOT BLACK PEARL 32*12' },
      { ...item('PT', [2], 175), type: 'FINISHED', name: 'TREAD RUBBER PRECURED PLATINUM 150' },
    ],
    [fixed('A', 'BP', 180), fixed('C', 'PT', 150)],
    [hitechItem('BP', 173)],
    groups,
  );
  snap.customers.push({ code: 'C', name: 'Dealer C', priceList: 1, active: true });
  const rules = [rule('A', 1, 5), rule('A', 2, 3), rule('B', 1, 8), rule('A', 6, 4)];
  const changes = [change(1, 5), change(6, 2)];
  const plan = buildPlan(snap, rules, changes, 12);

  it('one row per item property — every one, even a group no item carries yet — each with its own change', () => {
    const q = summariseQualities(snap, plan, rules, changes);
    expect(q.map((x) => [x.label, x.items.length, x.change, x.changedItems, x.dealers, x.hitechChanging, x.noTwin])).toEqual([
      ['PCTR - Black Pearl', 1, 5, 1, 2, 1, 0],
      ['PCTR - Platinum', 1, 0, 0, 1, 0, 1],
      ['HOT - Black Pearl', 1, 2, 1, 1, 0, 1],
      ['BONDING GUM - Black Pearl', 0, 0, 0, 0, 0, 0],
    ]);
    expect(q.map((x) => x.listNew)).toEqual([[190], [175], [177], []]);
    expect(q[0].hitechNew).toEqual([178]);
    expect(q.map((x) => x.kinds)).toEqual([{ PCTR: 1 }, { PCTR: 1 }, { HOT: 1 }, {}]);
  });

  it('flags an item that carries two groups', () => {
    const two = snapshot([item('BOTH', [1, 6], 185)], [], undefined, groups);
    expect(buildPlan(two, [], []).multiGroup.map((i) => i.code)).toEqual(['BOTH']);
    expect(plan.multiGroup).toEqual([]);
  });

  it('reads the type from the name when the type field does not say (display only)', () => {
    expect(itemKind({ type: 'FINISHED', name: 'TREAD RUBBER PRECURED X 120' })).toBe('PCTR');
    expect(itemKind({ type: '', name: 'TREAD RUBBER HOT X 32*12' })).toBe('HOT');
    expect(itemKind({ type: '', name: 'CUSHION' })).toBe('OTHER');
  });

  it('one row per dealer, with a line per group — HOT and PCTR of one quality at their own rupees', () => {
    const d = summariseDealers(snap, plan, rules);
    expect(d.map((x) => x.cardCode)).toEqual(['A', 'B', 'C']);
    expect(d[0].lines.map((l) => [l.quality, l.rupeesOff, l.rows.length, l.add, l.update, l.same])).toEqual([
      ['PCTR - Black Pearl', 5, 1, 0, 1, 0],
      ['PCTR - Platinum', 3, 1, 1, 0, 0],
      ['HOT - Black Pearl', 4, 1, 1, 0, 0],
    ]);
    expect(plan.dealerRows.find((r) => r.cardCode === 'A' && r.item.code === 'BP-H')?.newPrice).toBe(173);
    expect(d[2].orphans).toHaveLength(1);
    expect(d[2].lines).toHaveLength(0);
  });

  it('check summaries put the dealers needing attention first', () => {
    const { rows } = checkAgainstSap(snap, rules, 12);
    const c = summariseCheck(rows);
    expect(c[0].bad).toBeGreaterThan(0);
    const a = c.find((x) => x.cardCode === 'A')!;
    expect(a.counts).toEqual({ OK: 1, DRIFT: 0, MISSING: 2, KIND: 0 });
    expect(a.lines.map((l) => l.quality)).toEqual(['PCTR - Black Pearl', 'PCTR - Platinum', 'HOT - Black Pearl']);
  });

  it('groups Hi-Tech rows by group', () => {
    expect(hitechByQuality(snap, plan.hitechRows).map((g) => [g.quality, g.rows.length])).toEqual([['PCTR - Black Pearl', 1]]);
  });
});

describe('the snapshot as stored', () => {
  const v1special = [fixed('A', 'BP', 180)];
  const base = snapshot([item('BP', [1], 185)]);

  it('reads version 2 compact rows into the same special prices as version 1', () => {
    const { special: _s, ...rest } = base;
    const v2 = {
      ...rest,
      version: 2,
      specialCols: ['card', 'item', 'price', 'priceList', 'autoUpdate', 'discount', 'valid', 'currency'],
      specialRows: [['A', 'BP', 180, 0, 0, 0, 1, 'INR']],
    };
    expect(expandSnapshot(v2).special).toEqual(v1special);
    expect(expandSnapshot({ ...base, special: v1special }).special).toEqual(v1special);
  });

  it('follows the column order the file states', () => {
    const { special: _s, ...rest } = base;
    const v2 = { ...rest, version: 2, specialCols: ['item', 'card', 'priceList', 'price'], specialRows: [['BP', 'A', 1, 172.5]] };
    expect(expandSnapshot(v2).special[0]).toMatchObject({ card: 'A', item: 'BP', price: 172.5, priceList: 1, valid: true, currency: 'INR' });
  });

  it('keeps version 3\'s Hi-Tech side and the office server\'s check', () => {
    const { special: _s, ...rest } = snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]);
    const serverCheck = { margin: 12, rules: [], dealer: { OK: 0, DRIFT: 0, MISSING: 0, KIND: 0 }, hitech: { OK: 1, DRIFT: 0, MISSING: 0 }, noTwin: 0, conflicts: 0 };
    const v3 = { ...rest, specialCols: ['card', 'item', 'price'], specialRows: [], serverCheck };
    const s = expandSnapshot(v3);
    expect(s.hitech?.items[0]).toMatchObject({ code: 'BP', listPrice: 173 });
    expect(s.serverCheck).toEqual(serverCheck);
  });
});

describe('saving the rules', () => {
  it('creates, updates and removes exactly what changed', () => {
    const saved = [ { ...rule('A', 1, 5), id: 'r1' }, { ...rule('A', 2, 3), id: 'r2' }, { ...rule('B', 1, 8), id: 'r3' } ];
    const draft = [ rule('A', 1, 6), rule('A', 2, 3), rule('B', 4, 4) ];
    const d = diffRules(saved, draft);
    expect(d.create.map((r) => `${r.cardCode}|${r.propertyNo}`)).toEqual(['B|4']);
    expect(d.update.map((r) => [r.id, r.rupeesOff])).toEqual([['r1', 6]]);
    expect(d.remove.map((r) => r.id)).toEqual(['r3']);
  });
});

describe('fixes from the 25 Sep review', () => {
  it('a special price some rule reaches is never listed as having no discount behind it — even when refused or in conflict', () => {
    const snap = snapshot([item('BOTH', [1, 2], 150), item('NOLIST', [1], null)], [fixed('A', 'BOTH', 140), fixed('A', 'NOLIST', 100)]);
    const plan = buildPlan(snap, [rule('A', 1, 5), rule('A', 2, 3)], []);
    expect(plan.orphans).toEqual([]);
    expect(plan.problems.map((p) => p.itemCode).sort()).toEqual(['BOTH', 'NOLIST']);
  });

  it('a special price switched off in SAP is reported, not taken as right, and the check calls it missing', () => {
    const snap = snapshot([item('BP', [1], 200)], [fixed('A', 'BP', 195, 0, false)]);
    const plan = buildPlan(snap, [rule('A', 1, 5)], []);
    expect(plan.dealerRows[0].action).toBe('same');
    expect(plan.problems[0].message).toContain('switched off');
    expect(checkAgainstSap(snap, [rule('A', 1, 5)]).rows[0].status).toBe('MISSING');
  });

  it('refuses a discount of zero or less', () => {
    expect(badRules([rule('A', 1, 5), rule('A', 2, 0), rule('B', 1, -1)]).map((r) => `${r.cardCode}|${r.propertyNo}`)).toEqual(['A|2', 'B|1']);
  });

  it('saves a rule under its group’s current name when asked, and finds rules made for a renamed group', () => {
    const saved = [{ ...rule('A', 1, 5), quality: 'Black Pearl', id: 'r1' }];
    const names = new Map([[1, 'Hot - Black Pearl']]);
    expect(diffRules(saved, saved).update).toEqual([]);
    expect(diffRules(saved, saved, names).update.map((r) => r.quality)).toEqual(['Hot - Black Pearl']);
    const snap = snapshot([], [], undefined, [{ no: 1, name: 'Hot - Black Pearl' }]);
    expect(staleRules(snap, saved).map((s) => [s.was, s.now])).toEqual([['Black Pearl', 'Hot - Black Pearl']]);
    expect(staleRules(snap, [{ ...saved[0], quality: 'HOT -Black  Pearl' }])).toEqual([]);
    expect(staleRules(snap, [{ ...rule('A', 9, 5), quality: 'Gone' }]).map((s) => s.now)).toEqual([null]);
  });

  it('tells each DTW step as the wizard names it', () => {
    const plan = buildPlan(snapshot([item('BP', [1], 185)]), [rule('A', 1, 5)], [change(1, 5)]);
    const [list, dealer] = buildDtwFiles(plan, { treads: { db: 'T', name: 'T', priceListNo: 1 }, hitech: null, currency: 'INR', stamp: 's' });
    expect(list.import).toMatchObject({ dataType: 'Master Data', objectPath: 'Inventory › Item Master Data' });
    expect(dealer.import).toMatchObject({ dataType: 'Setup Data', objectPath: 'Inventory › Price Lists › Special Prices › Special Prices for Business Partners' });
  });
});