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
  diffRules,
  hitechByQuality,
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
  type ItemKind,
  type PricingSnapshot,
  type QualityChange,
  type ServerCheck,
  type SnapItem,
} from '../dealerRates';
import { expandSnapshot } from '@/api/pricing';

function item(code: string, props: number[], listPrice: number | null, twin: string | null = null, type = 'PRECURED'): SnapItem {
  return { code, name: code, group: 116, type, quality: '', uom: 'KGS', stock: 0, sales: true, frozen: false, updated: '2026-09-25', props, listPrice, currency: 'INR', twin };
}

const pctr = (propertyNo: number, rupees: number): QualityChange => ({ kind: 'PCTR', propertyNo, rupees });

function hitechItem(code: string, listPrice: number | null): HitechItem {
  return { code, name: code, listPrice, currency: 'INR' };
}

function snapshot(items: SnapItem[], special: PricingSnapshot['special'] = [], hitech?: HitechItem[]): PricingSnapshot {
  return {
    version: 3,
    company: 'MANNA_TREADS_LIVE',
    companyName: 'Manna Treads',
    priceList: { no: 1, name: 'selling price' },
    syncedAt: '2026-09-25 12:00:00',
    properties: [ { no: 1, name: 'Black Pearl' }, { no: 2, name: 'Platinum' } ],
    items,
    customers: [ { code: 'A', name: 'Dealer A', priceList: 1, active: true }, { code: 'B', name: 'Dealer B', priceList: 1, active: true } ],
    special,
    hitech: hitech ? { company: 'HITECH_PRETREADS_LIVE', companyName: 'Hi-Tech Pretreads', priceList: { no: 1, name: 'Price List 01' }, items: hitech } : undefined,
  };
}

const rule = (cardCode: string, propertyNo: number, rupeesOff: number): DealerRule => ({ cardCode, cardName: `Dealer ${cardCode}`, propertyNo, quality: '', rupeesOff });
const fixed = (card: string, itemCode: string, price: number, priceList = 0) => ({ card, item: itemCode, price, currency: 'INR', discount: 0, priceList, autoUpdate: false, valid: true });

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

describe('a type × quality change moves every item of that type and quality (shared fixture)', () => {
  const q = fx.quality_change;
  const snap = snapshot(
    q.items.map((i) => item(i.code, i.props, i.listPrice, i.twin, i.type)),
    [],
    q.hitech.map((h) => hitechItem(h.code, h.listPrice)),
  );
  const rules = q.rules.map((r) => rule(r.cardCode, r.propertyNo, r.rupeesOff));
  const changes = q.changes.map((c) => ({ ...c, kind: c.kind as ItemKind }));
  const plan = buildPlan(snap, rules, changes, q.margin);

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

  it('only the changed types appear as list changes, each by its own rupees, and only their twins as Hi-Tech changes', () => {
    expect(plan.listChanges.map((c) => [c.item.code, c.kind, c.delta]).sort()).toEqual([
      ['BP-HOT', 'HOT', 5],
      ['BP-PRE', 'PCTR', 3],
    ]);
    expect(plan.hitechRows.filter((r) => r.action === 'UPDATE').map((r) => r.hitech.code).sort()).toEqual(q.expect_hitech_changing);
    expect(plan.counts.hitech).toBe(2);
    expect(plan.counts.hitechSame).toBe(2);
  });
});

describe('the check against SAP (shared fixture), as the office server counts it', () => {
  const c = fx.check;
  const snap = snapshot(
    c.items.map((i) => item(i.code, i.props, i.listPrice, i.twin)),
    c.special.map((s) => fixed(s.card, s.item, s.price, s.priceList)),
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
    const plan = buildPlan(snap, [rule('A', 1, 5), rule('A', 2, 3), rule('B', 1, 8)], [pctr(1, 5)]);
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
    expect(plan.problems[0].message).toContain('one quality only');
    expect(plan.problems[0].kind).toBe('conflict');
  });

  it('never lets a list price fall to zero or below', () => {
    const plan = buildPlan(snapshot([item('BP', [1], 4)]), [], [pctr(1, -5)]);
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

describe('the DTW files', () => {
  const snap = snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]);
  const plan = buildPlan(snap, [rule('A', 1, 5)], [pctr(1, 5)], 12);
  const files = buildDtwFiles(plan, {
    treads: { db: 'MANNA_TREADS_LIVE', name: 'Manna Treads', priceListNo: 1 },
    hitech: { db: 'HITECH_PRETREADS_LIVE', name: 'Hi-Tech Pretreads', priceListNo: 1 },
    currency: 'INR',
    stamp: '20260925-1200',
  });

  it('come in import order, each named for its company: Manna Treads list, dealer prices, then Hi-Tech', () => {
    expect(files.map((f) => f.name)).toEqual([
      'treads-rates-20260925-1200-1a-price-list-OITM.csv',
      'treads-rates-20260925-1200-1b-price-list-ITM1.csv',
      'treads-rates-20260925-1200-2a-dealer-prices-ADD.csv',
      'hitech-rates-20260925-1200-3a-price-list-OITM.csv',
      'hitech-rates-20260925-1200-3b-price-list-ITM1.csv',
    ]);
    expect(files.map((f) => f.company)).toEqual(['MANNA_TREADS_LIVE', 'MANNA_TREADS_LIVE', 'MANNA_TREADS_LIVE', 'HITECH_PRETREADS_LIVE', 'HITECH_PRETREADS_LIVE']);
  });

  it('name the price list outright, write the dealer price as a fixed price, and Hi-Tech at the margin', () => {
    expect(files[1].content).toBe('ParentKey,LineNum,PriceList,Price,Currency\r\nItemCode,LineNum,PriceList,Price,Currency\r\nBP,0,1,190,INR\r\n');
    expect(files[2].content).toBe(
      'ItemCode,CardCode,Price,Currency,DiscountPercent,PriceListNum,AutoUpdate\r\nItemCode,CardCode,Price,Currency,Discount,ListNum,AutoUpdt\r\nBP,A,185,INR,0,0,tNO\r\n',
    );
    expect(files[4].content).toBe('ParentKey,LineNum,PriceList,Price,Currency\r\nItemCode,LineNum,PriceList,Price,Currency\r\nBP,0,1,178,INR\r\n');
  });

  it('make no Hi-Tech file when every twin is already right', () => {
    const quiet = buildPlan(snapshot([item('BP', [1], 185, 'BP')], [], [hitechItem('BP', 173)]), [], [], 12);
    expect(
      buildDtwFiles(quiet, { treads: { db: 'T', name: 'T', priceListNo: 1 }, hitech: { db: 'H', name: 'H', priceListNo: 1 }, currency: 'INR', stamp: 's' }),
    ).toEqual([]);
  });
});

describe("comparing with the office server's own check", () => {
  const c = fx.check;
  const snap = snapshot(
    c.items.map((i) => item(i.code, i.props, i.listPrice, i.twin)),
    c.special.map((s) => fixed(s.card, s.item, s.price, s.priceList)),
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
  const snap = snapshot(
    [
      { ...item('BP', [1], 185, 'BP'), type: 'PRECURED' },
      { ...item('BP-H', [1], 175), type: '', name: 'TREAD RUBBER HOT BLACK PEARL 32*12' },
      { ...item('PT', [2], 175), type: 'FINISHED', name: 'TREAD RUBBER PRECURED PLATINUM 150' },
    ],
    [fixed('A', 'BP', 180), fixed('C', 'PT', 150)],
    [hitechItem('BP', 173)],
  );
  snap.customers.push({ code: 'C', name: 'Dealer C', priceList: 1, active: true });
  const rules = [rule('A', 1, 5), rule('A', 2, 3), rule('B', 1, 8)];
  const changes: QualityChange[] = [pctr(1, 5), { kind: 'HOT', propertyNo: 1, rupees: 2 }];
  const plan = buildPlan(snap, rules, changes, 12);

  it('one row per type × quality, HOT and PCTR always, each with its own change', () => {
    const q = summariseQualities(snap, plan, rules, changes);
    expect(q.map((x) => [x.label, x.items.length, x.change, x.changedItems, x.dealers, x.hitechChanging, x.noTwin])).toEqual([
      ['HOT - Black Pearl', 1, 2, 1, 2, 0, 1],
      ['PCTR - Black Pearl', 1, 5, 1, 2, 1, 0],
      ['HOT - Platinum', 0, 0, 0, 1, 0, 0],
      ['PCTR - Platinum', 1, 0, 0, 1, 0, 1],
    ]);
    expect(q[0].listNew).toEqual([177]);
    expect(q[1].listNew).toEqual([190]);
    expect(q[1].hitechNew).toEqual([178]);
  });

  it('shows a bonding gum row only where the quality has gum', () => {
    const withGum = snapshot([...snap.items, { ...item('GUM', [1], 150), type: '', name: 'BONDING GUM -BLACK PEARL' }]);
    const q = summariseQualities(withGum, buildPlan(withGum, [], []), [], []);
    expect(q.map((x) => x.label)).toEqual(['HOT - Black Pearl', 'PCTR - Black Pearl', 'BONDING GUM - Black Pearl', 'HOT - Platinum', 'PCTR - Platinum']);
  });

  it('one row per dealer, with lines per quality, and dealers known only by an orphan price', () => {
    const d = summariseDealers(snap, plan, rules);
    expect(d.map((x) => x.cardCode)).toEqual(['A', 'B', 'C']);
    const a = d[0];
    expect(a.lines.map((l) => [l.quality, l.rupeesOff, l.rows.length, l.add, l.update, l.same])).toEqual([
      ['Black Pearl', 5, 2, 1, 1, 0],
      ['Platinum', 3, 1, 1, 0, 0],
    ]);
    expect(d[2].orphans).toHaveLength(1);
    expect(d[2].lines).toHaveLength(0);
  });

  it('check summaries put the dealers needing attention first', () => {
    const { rows } = checkAgainstSap(snap, rules, 12);
    const c = summariseCheck(rows);
    expect(c[0].bad).toBeGreaterThan(0);
    const a = c.find((x) => x.cardCode === 'A')!;
    expect(a.counts).toEqual({ OK: 1, DRIFT: 0, MISSING: 2, KIND: 0 });
    expect(a.lines.map((l) => l.quality)).toEqual(['Black Pearl', 'Platinum']);
  });

  it('groups Hi-Tech rows by quality', () => {
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
