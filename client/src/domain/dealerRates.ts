/**
 * Quality-wise prices for Manna Treads' dealers, and Hi-Tech Pretreads' price
 * list that follows them — the Managing Director's rates screen.
 *
 * THE RULES (shared/fixtures/dealer_rates.json; the PowerShell twin, which the
 * office server checks SAP with on every sync, is sap-pricing/RupeeRules.ps1)
 *
 *   dealer price  = the item's Manna Treads Price List 01 price
 *                   − the dealer's rupees off for the item's quality
 *   Hi-Tech price = the same item's Manna Treads price − the inter-company margin
 *
 * The dealers are Manna Treads' customers (MANNA_TREADS_LIVE), so their prices
 * are special prices there. Hi-Tech Pretreads bills Manna Treads a fixed number
 * of rupees per kg below Manna Treads' own price, so Hi-Tech's Price List 01
 * follows Manna Treads' item by item (decided 25 Sep 2026). "The same item" is
 * its twin: the Hi-Tech item with the same code AND the same name, as the
 * snapshot says. A code alone is not enough — I-12279 is a different tread in
 * each company.
 *
 * Every price and discount is GST-inclusive as it stands. Nothing here adds or
 * removes GST.
 *
 * THE GROUPS ARE SAP'S ITEM PROPERTIES. The user names them "Type - Quality"
 * in both companies — "HOT - Black Pearl", "PCTR - Black Pearl" — and ticks one
 * on each item (25 Sep 2026). A price change is made per property: every item
 * carrying it moves by the same rupees. A dealer's discount is per property
 * too, so a dealer can get different rupees off HOT and PCTR of one quality. A
 * new property named in SAP ("BONDING GUM - Black Pearl") is a new group on
 * the screen, with nothing to change here. The code calls a property a
 * "quality" for history's sake; its name is whatever SAP says.
 *
 * Each dealer keeps the same rupees off, and each twin the same margin, when a
 * price moves. Nothing here talks to SAP: the screen shows what will change,
 * and the MD downloads DTW files — one per destination — to import. Decided
 * 25 Sep 2026: SAP is written through DTW only.
 *
 * SAP holds the dealer price as a FIXED special price ("Without Price List",
 * PriceListNum 0): a percentage cannot carry whole rupees, because SAP keeps it
 * to two decimals and recomputes the price from it.
 */

// ------------------------------------------------------------ snapshot ---

/** What Sync-SapPricingSnapshot.ps1 copies out of SAP into ERPNext. */
export interface PricingSnapshot {
  version: number;
  /** Manna Treads (version 3 on): the dealers' company, whose list is the master. */
  company: string;
  companyName: string;
  priceList: { no: number; name: string };
  syncedAt: string;
  /** `nameFrom: 'Hi-Tech'` — unnamed in Manna Treads' SAP, so Hi-Tech's name for the number is shown. */
  properties: { no: number; name: string; nameFrom?: string }[];
  items: SnapItem[];
  customers: SnapCustomer[];
  special: SnapSpecial[];
  /** Version 3: Hi-Tech Pretreads' price list, for the twins of `items`. */
  hitech?: HitechSide;
  /** Version 3: the office server's own check of SAP, worked out in PowerShell. */
  serverCheck?: ServerCheck;
}

export interface SnapItem {
  code: string;
  name: string;
  group: number;
  groupName?: string;
  /** PRECURED / HOT — from U_ProductType, or from the name where there is none. */
  type: string;
  /** The quality as SAP spells it on the item. The property is what the rules key on. */
  quality: string;
  width?: string;
  design?: string;
  length?: string;
  size?: string;
  uom: string;
  beltsPerRoll?: number | null;
  weightPerRoll?: number | null;
  stock: number;
  sales: boolean;
  frozen: boolean;
  /** SAP's last change to the item, yyyy-mm-dd. */
  updated: string;
  /** The named properties ticked on the item. */
  props: number[];
  listPrice: number | null;
  currency: string;
  /** Its Hi-Tech Pretreads twin's item code: same code, same name. */
  twin?: string | null;
  /** Why there is no twin, when Hi-Tech has the code for a different tread. */
  twinNote?: string;
}

export interface HitechSide {
  company: string;
  companyName: string;
  priceList: { no: number; name: string };
  /** The twins only. */
  items: HitechItem[];
}

export interface HitechItem {
  code: string;
  name: string;
  listPrice: number | null;
  currency: string;
  stock?: number;
  sales?: boolean;
  frozen?: boolean;
  updated?: string;
}

export interface SnapCustomer {
  code: string;
  name: string;
  group?: string;
  priceList: number;
  active: boolean;
}

export interface SnapSpecial {
  card: string;
  item: string;
  price: number;
  currency: string;
  discount: number;
  /** 0 = "Without Price List" (a fixed price); otherwise the base price list. */
  priceList: number;
  autoUpdate: boolean;
  valid: boolean;
}

/** One row of `SAP Dealer Rate Rule`. */
export interface DealerRule {
  /** The ERPNext name; absent on a rule not saved yet. */
  id?: string;
  cardCode: string;
  cardName: string;
  propertyNo: number;
  quality: string;
  rupeesOff: number;
  note?: string;
}

/**
 * A list-price change for one item property — one "Type - Quality" group such
 * as "HOT - Black Pearl" — in rupees (+ or −).
 */
export interface QualityChange {
  propertyNo: number;
  rupees: number;
}

// --------------------------------------------------------------- money ---

/**
 * To the paisa, half away from zero. The nudge is below a millionth of a
 * paisa: 146.525 × 100 is 14652.499999… in binary and would otherwise round
 * down, where the PowerShell twin (which rounds through decimal) rounds up.
 */
export function roundMoney(x: number): number {
  const cents = Math.round(Math.abs(x) * 100 + 1e-6);
  return (Math.sign(x) || 1) * (cents / 100);
}

export type SpecialPriceResult =
  | { ok: true; price: number; percent: number }
  | { ok: false; error: string };

/** The dealer price for one item. The percent is for display only. */
export function specialPrice(listPrice: number | null | undefined, rupeesOff: number): SpecialPriceResult {
  const list = Number(listPrice ?? 0);
  if (!(list > 0)) return { ok: false, error: 'no list price' };
  if (!(rupeesOff > 0)) return { ok: false, error: 'rupees off must be more than zero' };
  const price = roundMoney(list - rupeesOff);
  if (!(price > 0)) {
    return { ok: false, error: `Rs ${roundMoney(rupeesOff)} off is not less than the list price ${list}` };
  }
  const percent = Math.round(((list - price) / list) * 100 * 1e6) / 1e6;
  return { ok: true, price, percent };
}

export type HitechPriceResult = { ok: true; price: number } | { ok: false; error: string };

/** Hi-Tech Pretreads' price for an item: Manna Treads' price for its twin less the margin. */
export function hitechPrice(treadsPrice: number | null | undefined, margin: number | null | undefined): HitechPriceResult {
  const m = Number(margin ?? 0);
  if (!(m > 0)) return { ok: false, error: 'no inter-company margin is set' };
  const t = Number(treadsPrice ?? 0);
  if (!(t > 0)) return { ok: false, error: 'no Manna Treads price' };
  const price = roundMoney(t - m);
  if (!(price > 0)) return { ok: false, error: `the margin Rs ${roundMoney(m)} is not less than Manna Treads' price ${t}` };
  return { ok: true, price };
}

// ---------------------------------------------------------------- plan ---

export interface ListChangeRow {
  item: SnapItem;
  propertyNo: number;
  quality: string;
  oldPrice: number | null;
  newPrice: number;
  delta: number;
}

export type DealerAction = 'ADD' | 'UPDATE' | 'same';

export interface DealerRow {
  cardCode: string;
  cardName: string;
  item: SnapItem;
  propertyNo: number;
  quality: string;
  rupeesOff: number;
  /** List price after any quality change in this plan. */
  listPrice: number;
  listPriceNow: number | null;
  newPrice: number;
  percent: number;
  /** What SAP holds today for this dealer and item, if anything. */
  sapPrice: number | null;
  sapIsFixed: boolean | null;
  /** False when SAP holds the special price but it is switched off (Valid = tNO). */
  sapValid: boolean | null;
  action: DealerAction;
}

/** One Manna Treads item's twin in Hi-Tech, and the price it should have. */
export interface HitechRow {
  /** The Manna Treads item. */
  item: SnapItem;
  hitech: HitechItem;
  /** Manna Treads' price after this plan. */
  treadsPrice: number;
  hitechNow: number | null;
  newPrice: number;
  action: 'UPDATE' | 'same';
}

export interface PlanProblem {
  cardCode?: string;
  itemCode: string;
  message: string;
  /** An item matching two of one dealer's qualities — counted by both checks. */
  kind?: 'conflict';
}

export interface RatesPlan {
  listChanges: ListChangeRow[];
  dealerRows: DealerRow[];
  problems: PlanProblem[];
  /** Special prices in SAP whose dealer no longer has a rule for that quality. */
  orphans: { special: SnapSpecial; item?: SnapItem; cardName: string }[];
  /** Every twin, changing or not. */
  hitechRows: HitechRow[];
  hitechProblems: PlanProblem[];
  /** Manna Treads items with no Hi-Tech twin: no Hi-Tech price is made for them. */
  noTwin: SnapItem[];
  /** Why no Hi-Tech price was worked out at all, when none was. */
  hitechSkipped: string | null;
  /**
   * Items carrying more than one named property. Each item should be in one
   * "Type - Quality" group; one in two cannot move with both, and a change or a
   * discount on both of its groups is refused for it.
   */
  multiGroup: SnapItem[];
  counts: {
    listChanges: number;
    add: number;
    update: number;
    same: number;
    problems: number;
    orphans: number;
    hitech: number;
    hitechSame: number;
    noTwin: number;
  };
}

function propertyName(snapshot: PricingSnapshot, no: number): string {
  return snapshot.properties.find((p) => p.no === no)?.name ?? `Property ${no}`;
}

/**
 * Everything a confirm would do, from the snapshot, the rules, the quality
 * changes and the margin. Pure: the preview, the DTW files and the tests all
 * come from this.
 */
export function buildPlan(
  snapshot: PricingSnapshot,
  rules: DealerRule[],
  changes: QualityChange[],
  margin: number | null = null,
): RatesPlan {
  const problems: PlanProblem[] = [];
  const changeBy = new Map<number, number>();
  for (const c of changes) {
    if (c.rupees && Number.isFinite(c.rupees)) changeBy.set(c.propertyNo, (changeBy.get(c.propertyNo) ?? 0) + c.rupees);
  }
  const named = new Set(snapshot.properties.map((p) => p.no));
  const multiGroup = snapshot.items.filter((i) => i.props.filter((p) => named.has(p)).length > 1);

  // 1. New Manna Treads list prices, group (item property) by group.
  const newList = new Map<string, number | null>();
  const listChanges: ListChangeRow[] = [];
  for (const it of snapshot.items) {
    const moving = it.props.filter((p) => changeBy.has(p));
    if (moving.length > 1) {
      problems.push({ itemCode: it.code, message: `is in ${moving.length} groups being changed (${moving.map((p) => propertyName(snapshot, p)).join(', ')}) - tick one property only; its price is left alone` });
      newList.set(it.code, it.listPrice);
      continue;
    }
    if (moving.length === 1) {
      const p = moving[0];
      if (!(Number(it.listPrice) > 0)) {
        problems.push({ itemCode: it.code, message: 'has no list price in SAP, so a change in rupees cannot be applied' });
        newList.set(it.code, it.listPrice);
        continue;
      }
      const next = roundMoney(Number(it.listPrice) + (changeBy.get(p) ?? 0));
      if (!(next > 0)) {
        problems.push({ itemCode: it.code, message: `would fall to ${next}; its price is left alone` });
        newList.set(it.code, it.listPrice);
        continue;
      }
      newList.set(it.code, next);
      listChanges.push({ item: it, propertyNo: p, quality: propertyName(snapshot, p), oldPrice: it.listPrice, newPrice: next, delta: roundMoney(next - Number(it.listPrice)) });
    } else {
      newList.set(it.code, it.listPrice);
    }
  }

  // 2. Dealer prices, in Manna Treads.
  const special = new Map(snapshot.special.map((s) => [`${s.card}|${s.item}`, s]));
  const dealerRows: DealerRow[] = [];
  // Every dealer × item some rule reaches — priced, refused or in conflict —
  // so a special price there is never mistaken for one "with no discount
  // behind it".
  const ruled = new Set<string>();
  const cards = [...new Set(rules.map((r) => r.cardCode))].sort();
  for (const card of cards) {
    const mine = rules.filter((r) => r.cardCode === card);
    for (const it of snapshot.items) {
      const hit = mine.filter((r) => it.props.includes(r.propertyNo));
      if (hit.length === 0) continue;
      const key = `${card}|${it.code}`;
      ruled.add(key);
      if (hit.length > 1) {
        problems.push({ cardCode: card, itemCode: it.code, kind: 'conflict', message: `is in ${hit.length} of this dealer's price groups - tick one property only; no price is made` });
        continue;
      }
      const rule = hit[0];
      const list = newList.get(it.code) ?? null;
      const sp = specialPrice(list, rule.rupeesOff);
      if (!sp.ok) {
        problems.push({ cardCode: card, itemCode: it.code, message: sp.error });
        continue;
      }
      const now = special.get(key);
      const fixed = now ? now.priceList === 0 : null;
      const off = Boolean(now && now.valid === false);
      let action: DealerAction = 'same';
      if (!now) action = 'ADD';
      else if (off) {
        // A DTW file cannot switch a special price back on (SAP's own template
        // has no Valid column), so this is a job for SAP's window, not a file.
        problems.push({ cardCode: card, itemCode: it.code, message: 'has a special price in SAP that is switched off (Valid unticked) - tick Valid in Special Prices for Business Partners; the dealer pays the list price until then' });
      } else if (Math.abs(now.price - sp.price) > 0.004 || now.priceList !== 0 || now.autoUpdate) action = 'UPDATE';
      dealerRows.push({
        cardCode: card,
        cardName: rule.cardName,
        item: it,
        propertyNo: rule.propertyNo,
        quality: propertyName(snapshot, rule.propertyNo),
        rupeesOff: rule.rupeesOff,
        listPrice: Number(list),
        listPriceNow: it.listPrice,
        newPrice: sp.price,
        percent: sp.percent,
        sapPrice: now ? now.price : null,
        sapIsFixed: fixed,
        sapValid: now ? now.valid !== false : null,
        action,
      });
    }
  }

  // 3. Special prices with no rule behind them any more.
  const itemsByCode = new Map(snapshot.items.map((i) => [i.code, i]));
  const names = new Map(snapshot.customers.map((c) => [c.code, c.name]));
  const orphans = snapshot.special
    .filter((s) => !ruled.has(`${s.card}|${s.item}`))
    .map((s) => ({ special: s, item: itemsByCode.get(s.item), cardName: names.get(s.card) ?? s.card }));

  // 4. Hi-Tech's Price List 01: every twin at Manna Treads' price less the margin.
  const hitechRows: HitechRow[] = [];
  const hitechProblems: PlanProblem[] = [];
  const noTwin: SnapItem[] = [];
  let hitechSkipped: string | null = null;
  const hitech = snapshot.hitech;
  if (!hitech) {
    hitechSkipped = 'this copy of SAP has no Hi-Tech Pretreads prices in it - press Sync from SAP';
  } else {
    const twins = new Map(hitech.items.map((h) => [h.code, h]));
    const marginSet = Number(margin) > 0;
    if (!marginSet) hitechSkipped = 'the inter-company margin is not set (ERPNext: SAP Pricing Control)';
    for (const it of snapshot.items) {
      const tw = it.twin ? twins.get(it.twin) : undefined;
      if (!tw) {
        noTwin.push(it);
        continue;
      }
      if (!marginSet) continue;
      const hp = hitechPrice(newList.get(it.code) ?? null, margin);
      if (!hp.ok) {
        hitechProblems.push({ itemCode: it.code, message: `Hi-Tech ${tw.code}: ${hp.error}` });
        continue;
      }
      const now = tw.listPrice;
      const same = now !== null && Number(now) > 0 && Math.abs(Number(now) - hp.price) <= 0.004;
      hitechRows.push({ item: it, hitech: tw, treadsPrice: Number(newList.get(it.code)), hitechNow: now, newPrice: hp.price, action: same ? 'same' : 'UPDATE' });
    }
  }

  return {
    listChanges,
    dealerRows,
    problems,
    orphans,
    hitechRows,
    hitechProblems,
    noTwin,
    hitechSkipped,
    multiGroup,
    counts: {
      listChanges: listChanges.length,
      add: dealerRows.filter((r) => r.action === 'ADD').length,
      update: dealerRows.filter((r) => r.action === 'UPDATE').length,
      same: dealerRows.filter((r) => r.action === 'same').length,
      problems: problems.length,
      orphans: orphans.length,
      hitech: hitechRows.filter((r) => r.action === 'UPDATE').length,
      hitechSame: hitechRows.filter((r) => r.action === 'same').length,
      noTwin: noTwin.length,
    },
  };
}

// ----------------------------------------------------------- DTW files ---

function cell(v: string | number): string {
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(Math.round(v * 1e6) / 1e6);
  return /[",\r\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

/** A DTW file: two header rows (object field, then database column), CRLF — as the files already imported. */
export function dtwCsv(fields: string[], columns: string[], rows: (string | number)[][]): string {
  return [fields.join(','), columns.join(','), ...rows.map((r) => r.map(cell).join(','))].join('\r\n') + '\r\n';
}

/** A company the files go to. */
export interface DtwCompany {
  /** The SAP database to log DTW in to, e.g. MANNA_TREADS_LIVE. */
  db: string;
  name: string;
  priceListNo: number;
}

/**
 * One DTW import, in the wizard's own steps (DTW 10.00.190 help, "Importing
 * the Source Data"): Step 1 Select Data Type, Step 2 Specify Operation Type,
 * Step 3 Select a Business Object (a tree laid out like SAP's main menu),
 * Step 4 Select Data Source, Step 6 Run Simulation, Step 7 import.
 */
export interface DtwImport {
  /** Step 1 — the data type ("Appendix: Data Type"): Items are Master Data, special prices Setup Data. */
  dataType: 'Master Data' | 'Setup Data';
  /** Step 2. */
  dtwMode: 'Update Existing Data' | 'Add New Data and Update Existing Data';
  /** Step 3 — the object's place in the tree, as SAP's main menu has it. */
  objectPath: string;
  /** The DI object, for anyone checking the templates. */
  dtwObject: string;
  /** Step 4 — the (sub)object to give the file to. */
  slot: string;
  /** Anything else the wizard needs said. */
  note?: string;
}

export type DeliveryId = 'treads-price-list' | 'treads-dealer-prices' | 'hitech-price-list';

/**
 * One download — one CSV. A confirm gives at most three, one per destination,
 * in import order: 1 Manna Treads' price list, 2 Manna Treads' dealer prices,
 * 3 Hi-Tech's price list (the user, 25 Sep 2026).
 *
 * A price list is DTW's Items_Prices file alone. DTW's own help (10.00.190, on
 * the SAP server): "If you choose Update Existing Data, you can select a child
 * object without selecting a parent object." The dealer prices are one file
 * holding new and changed prices together: "Add New Data and Update Existing
 * Data means that the same source file contains new records and also records
 * for update. This option is relevant for master data and setup data only" —
 * and Special Prices for Business Partners is setup data.
 */
export interface DtwDelivery {
  id: DeliveryId;
  /** 1, 2, 3 — the import order, and the start of the file name. */
  step: number;
  title: string;
  name: string;
  /** The SAP database DTW must be logged in to. */
  company: string;
  companyName: string;
  rows: number;
  import: DtwImport;
  content: string;
  /**
   * A price list's Items header file, offered only in case a DTW insists on it
   * (the imports of 24-25 Sep 2026 used the pair). Not one of the three files.
   */
  fallback?: { name: string; content: string };
}

/** One price list's prices: DTW's Items_Prices, keyed ParentKey = ItemCode. */
function priceListDelivery(id: DeliveryId, step: number, title: string, base: string, co: DtwCompany, currency: string, rows: [string, number][]): DtwDelivery {
  return {
    id,
    step,
    title,
    name: `${step}-${base}.csv`,
    company: co.db,
    companyName: co.name,
    rows: rows.length,
    import: {
      dataType: 'Master Data',
      dtwMode: 'Update Existing Data',
      objectPath: 'Inventory › Item Master Data',
      dtwObject: 'Items (oItems)',
      slot: 'Items_Prices',
      note: 'give the file to Items_Prices only and leave Items empty — when updating, a child needs no parent',
    },
    // PriceList named outright as well as LineNum (the list's 0-based row on
    // the item), as in the files imported on 24-25 Sep 2026, so the import
    // cannot land on the wrong price list.
    content: dtwCsv(
      ['ParentKey', 'LineNum', 'PriceList', 'Price', 'Currency'],
      ['ItemCode', 'LineNum', 'PriceList', 'Price', 'Currency'],
      rows.map(([code, price]) => [code, co.priceListNo - 1, co.priceListNo, price, currency]),
    ),
    fallback: { name: `${step}-${base}-Items.csv`, content: dtwCsv(['ItemCode'], ['ItemCode'], rows.map(([code]) => [code])) },
  };
}

/**
 * The downloads for a plan: at most three, one per destination, in import
 * order. Before 25 Sep 2026 evening a confirm started up to six downloads at
 * once, and the browser let only the first through.
 */
export function buildDtwFiles(
  plan: RatesPlan,
  opts: { treads: DtwCompany; hitech: DtwCompany | null; currency: string; stamp: string },
): DtwDelivery[] {
  const out: DtwDelivery[] = [];
  if (plan.listChanges.length) {
    out.push(
      priceListDelivery('treads-price-list', 1, `${opts.treads.name} price list`, `treads-price-list-${opts.stamp}`, opts.treads, opts.currency,
        plan.listChanges.map((c) => [c.item.code, c.newPrice])),
    );
  }
  const dealer = plan.dealerRows.filter((r) => r.action !== 'same');
  if (dealer.length) {
    out.push({
      id: 'treads-dealer-prices',
      step: 2,
      title: `${opts.treads.name} dealer prices`,
      name: `2-treads-dealer-prices-${opts.stamp}.csv`,
      company: opts.treads.db,
      companyName: opts.treads.name,
      rows: dealer.length,
      import: {
        dataType: 'Setup Data',
        dtwMode: 'Add New Data and Update Existing Data',
        objectPath: 'Inventory › Price Lists › Special Prices › Special Prices for Business Partners',
        dtwObject: 'Special Prices for Business Partners (oSpecialPrices)',
        slot: 'SpecialPrices',
      },
      content: dtwCsv(
        ['ItemCode', 'CardCode', 'Price', 'Currency', 'DiscountPercent', 'PriceListNum', 'AutoUpdate'],
        ['ItemCode', 'CardCode', 'Price', 'Currency', 'Discount', 'ListNum', 'AutoUpdt'],
        dealer.map((r) => [r.item.code, r.cardCode, r.newPrice, opts.currency, 0, 0, 'tNO']),
      ),
    });
  }
  const hitech = plan.hitechRows.filter((r) => r.action === 'UPDATE');
  if (opts.hitech && hitech.length) {
    out.push(
      priceListDelivery('hitech-price-list', 3, `${opts.hitech.name} price list`, `hitech-price-list-${opts.stamp}`, opts.hitech, opts.currency,
        hitech.map((r) => [r.hitech.code, r.newPrice])),
    );
  }
  return out;
}

// --------------------------------------------------------------- check ---

export type CheckStatus = 'OK' | 'DRIFT' | 'MISSING' | 'KIND';
export type HitechStatus = 'OK' | 'DRIFT' | 'MISSING';

export interface CheckRow {
  cardCode: string;
  cardName: string;
  item: SnapItem;
  propertyNo: number;
  quality: string;
  rupeesOff: number;
  listPrice: number;
  expected: number;
  sapPrice: number | null;
  /** Rupees SAP is actually giving off the list, when it holds a price. */
  sapRupeesOff: number | null;
  status: CheckStatus;
}

export interface HitechCheckRow {
  item: SnapItem;
  hitech: HitechItem;
  /** The item's first quality, for grouping. */
  propertyNo: number | null;
  quality: string;
  treadsPrice: number;
  expected: number;
  sapPrice: number | null;
  /** Manna Treads' price less Hi-Tech's, as SAP holds them — the margin SAP is really giving. */
  sapMargin: number | null;
  status: HitechStatus;
}

export interface SapCheck {
  rows: CheckRow[];
  problems: PlanProblem[];
  hitech: HitechCheckRow[];
  hitechProblems: PlanProblem[];
  noTwin: SnapItem[];
  hitechSkipped: string | null;
}

/**
 * Does SAP hold what the saved rules and the margin call for? Dealer prices:
 * list − rupees to the paisa, as a fixed price ("Without Price List"), not a
 * percentage. Hi-Tech prices: Manna Treads' price − the margin, to the paisa.
 */
export function checkAgainstSap(snapshot: PricingSnapshot, rules: DealerRule[], margin: number | null = null): SapCheck {
  const plan = buildPlan(snapshot, rules, [], margin);
  const rows = plan.dealerRows.map((r): CheckRow => {
    let status: CheckStatus = 'OK';
    // Switched off in SAP: the dealer is billed the list price, as if missing.
    if (r.sapPrice === null || r.sapValid === false) status = 'MISSING';
    else if (r.sapIsFixed === false) status = 'KIND';
    else if (Math.abs(r.sapPrice - r.newPrice) > 0.004) status = 'DRIFT';
    return {
      cardCode: r.cardCode,
      cardName: r.cardName,
      item: r.item,
      propertyNo: r.propertyNo,
      quality: r.quality,
      rupeesOff: r.rupeesOff,
      listPrice: r.listPrice,
      expected: r.newPrice,
      sapPrice: r.sapPrice,
      sapRupeesOff: r.sapPrice === null ? null : roundMoney(r.listPrice - r.sapPrice),
      status,
    };
  });
  const named = new Set(snapshot.properties.map((p) => p.no));
  const hitech = plan.hitechRows.map((r): HitechCheckRow => {
    const now = r.hitechNow !== null && Number(r.hitechNow) > 0 ? Number(r.hitechNow) : null;
    const first = [...r.item.props].filter((p) => named.has(p)).sort((a, b) => a - b)[0] ?? null;
    return {
      item: r.item,
      hitech: r.hitech,
      propertyNo: first,
      quality: first === null ? '' : propertyName(snapshot, first),
      treadsPrice: r.treadsPrice,
      expected: r.newPrice,
      sapPrice: now,
      sapMargin: now === null ? null : roundMoney(r.treadsPrice - now),
      status: now === null ? 'MISSING' : r.action === 'same' ? 'OK' : 'DRIFT',
    };
  });
  return { rows, problems: plan.problems, hitech, hitechProblems: plan.hitechProblems, noTwin: plan.noTwin, hitechSkipped: plan.hitechSkipped };
}

// ------------------------------------------------- the office server's check ---
//
// Sync-SapPricingSnapshot.ps1 checks SAP itself on every sync, with the
// PowerShell twin of these rules, and stores its counts in the snapshot. The
// screen compares them with its own: two implementations agreeing is the
// assurance that a DTW file built here says what the rules say.

export type StatusCounts = Record<CheckStatus, number>;
export type HitechCounts = Record<HitechStatus, number>;

export interface CheckCounts {
  dealer: StatusCounts;
  hitech: HitechCounts;
  noTwin: number;
  conflicts: number;
}

export interface ServerCheck extends CheckCounts {
  margin: number | null;
  /** The rules it checked with, as `card|property|rupees`. */
  rules: string[];
}

const noCounts = (): StatusCounts => ({ OK: 0, DRIFT: 0, MISSING: 0, KIND: 0 });
const noHitechCounts = (): HitechCounts => ({ OK: 0, DRIFT: 0, MISSING: 0 });

export function checkCounts(c: SapCheck): CheckCounts {
  const dealer = noCounts();
  for (const r of c.rows) dealer[r.status]++;
  const hitech = noHitechCounts();
  for (const r of c.hitech) hitech[r.status]++;
  return { dealer, hitech, noTwin: c.noTwin.length, conflicts: c.problems.filter((p) => p.kind === 'conflict').length };
}

/** A rule as the office server writes it: `card|property|rupees`. */
export function ruleSignature(r: Pick<DealerRule, 'cardCode' | 'propertyNo' | 'rupeesOff'>): string {
  return `${r.cardCode}|${r.propertyNo}|${String(roundMoney(r.rupeesOff))}`;
}

export type ServerAgreement =
  | { state: 'none' }
  | { state: 'stale'; why: string }
  | { state: 'agree' }
  | { state: 'disagree'; differences: string[] };

export function compareServerCheck(
  server: ServerCheck | undefined,
  ours: CheckCounts,
  savedRules: DealerRule[],
  margin: number | null,
): ServerAgreement {
  if (!server) return { state: 'none' };
  const theirs = new Set(server.rules ?? []);
  const mine = new Set(savedRules.map(ruleSignature));
  const sameRules = theirs.size === mine.size && [...mine].every((k) => theirs.has(k));
  if (!sameRules) return { state: 'stale', why: 'the dealer prices have changed since the office server last checked' };
  if (roundMoney(Number(server.margin ?? 0)) !== roundMoney(Number(margin ?? 0))) {
    return { state: 'stale', why: 'the inter-company margin has changed since the office server last checked' };
  }
  const differences: string[] = [];
  for (const s of ['OK', 'DRIFT', 'MISSING', 'KIND'] as const) {
    if ((server.dealer?.[s] ?? 0) !== ours.dealer[s]) differences.push(`dealer prices ${s}: this screen ${ours.dealer[s]}, office server ${server.dealer?.[s] ?? 0}`);
  }
  for (const s of ['OK', 'DRIFT', 'MISSING'] as const) {
    if ((server.hitech?.[s] ?? 0) !== ours.hitech[s]) differences.push(`Hi-Tech prices ${s}: this screen ${ours.hitech[s]}, office server ${server.hitech?.[s] ?? 0}`);
  }
  if ((server.noTwin ?? 0) !== ours.noTwin) differences.push(`items with no Hi-Tech twin: this screen ${ours.noTwin}, office server ${server.noTwin ?? 0}`);
  if ((server.conflicts ?? 0) !== ours.conflicts) differences.push(`items in two of a dealer's qualities: this screen ${ours.conflicts}, office server ${server.conflicts ?? 0}`);
  return differences.length ? { state: 'disagree', differences } : { state: 'agree' };
}

// ----------------------------------------------------------- summaries ---
//
// The screen opens on these, not on the rows: with the real catalogue one
// quality change can touch hundreds of items for every dealer (444 Black Pearl
// items x 100 dealers is 44,400 dealer prices). A summary row per type ×
// quality and per dealer opens onto the detail when clicked.

/**
 * The item's type, as the office says it: HOT, PCTR (precured tread rubber),
 * BONDING GUM — read from the item for DISPLAY only. The groups prices move by
 * are the item properties ("HOT - Black Pearl"), not this.
 */
export type ItemKind = 'HOT' | 'PCTR' | 'BONDING GUM' | 'OTHER';

/** The order the screen lists types in. */
export const KINDS: ItemKind[] = ['HOT', 'PCTR', 'BONDING GUM', 'OTHER'];

/**
 * From the type, then from the name when the type does not say — only 604 of
 * 1,778 Hi-Tech FG items carry PRECURED or HOT in U_ProductType, and Manna
 * Treads has no such field at all (its names say "TREAD RUBBER PRECURED …",
 * "PCTR 240 …", "BONDING GUM -BLACK PEARL"). Gum is never a tread, so it is
 * looked for first; precured wins over hot, as in the apps' own category rule.
 * The PowerShell twin is Get-ItemKind in sap-pricing/RupeeRules.ps1.
 */
export function itemKind(i: Pick<SnapItem, 'type' | 'name'>): ItemKind {
  for (const t of [(i.type ?? '').toUpperCase(), (i.name ?? '').toUpperCase()]) {
    if (/\bGUM\b/.test(t)) return 'BONDING GUM';
    if (t.includes('PRECURED') || /\bPCTR\b/.test(t)) return 'PCTR';
    if (/\bHOT\b/.test(t)) return 'HOT';
  }
  return 'OTHER';
}

/** One group — one named item property, "HOT - Black Pearl" — on the price screen. */
export interface QualitySummary {
  /** String(propertyNo): what the change boxes are keyed by. */
  key: string;
  propertyNo: number;
  /** The property's name in SAP. */
  name: string;
  label: string;
  items: SnapItem[];
  /** The items' types, for a hint ("5 PCTR"). */
  kinds: Partial<Record<ItemKind, number>>;
  /** Today's list prices, and after this plan's change; both only where priced. */
  listNow: number[];
  listNew: number[];
  /** The rupees this plan moves the group by; 0 when unchanged. */
  change: number;
  changedItems: number;
  /** Dealers with a discount on this group. */
  dealers: number;
  /** Hi-Tech's prices for the group's twins, today and after this plan. */
  hitechNow: number[];
  hitechNew: number[];
  hitechChanging: number;
  noTwin: number;
}

/**
 * One row per named item property, in property order — every property, even
 * one no item carries yet, so a group newly named in SAP shows at once.
 */
export function summariseQualities(
  snapshot: PricingSnapshot,
  plan: RatesPlan,
  rules: DealerRule[],
  changes: QualityChange[],
): QualitySummary[] {
  const newBy = new Map(plan.listChanges.map((c) => [c.item.code, c.newPrice]));
  const hitechBy = new Map(plan.hitechRows.map((r) => [r.item.code, r]));
  const lonely = new Set(plan.noTwin.map((i) => i.code));
  const changeBy = new Map<number, number>();
  for (const c of changes) changeBy.set(c.propertyNo, (changeBy.get(c.propertyNo) ?? 0) + c.rupees);
  return [...snapshot.properties]
    .sort((a, b) => a.no - b.no)
    .map((p) => {
      const items = snapshot.items.filter((i) => i.props.includes(p.no));
      const hr = items.map((i) => hitechBy.get(i.code)).filter((r): r is HitechRow => Boolean(r));
      const kinds: Partial<Record<ItemKind, number>> = {};
      for (const i of items) kinds[itemKind(i)] = (kinds[itemKind(i)] ?? 0) + 1;
      return {
        key: String(p.no),
        propertyNo: p.no,
        name: p.name,
        label: p.name,
        items,
        kinds,
        listNow: items.map((i) => Number(i.listPrice)).filter((x) => x > 0),
        listNew: items.map((i) => newBy.get(i.code) ?? Number(i.listPrice)).filter((x) => x > 0),
        change: roundMoney(changeBy.get(p.no) ?? 0),
        changedItems: items.filter((i) => newBy.has(i.code)).length,
        dealers: new Set(rules.filter((r) => r.propertyNo === p.no).map((r) => r.cardCode)).size,
        hitechNow: hr.map((r) => Number(r.hitechNow)).filter((x) => x > 0),
        hitechNew: hr.map((r) => r.newPrice),
        hitechChanging: hr.filter((r) => r.action === 'UPDATE').length,
        noTwin: items.filter((i) => lonely.has(i.code)).length,
      };
    });
}

/** Group once — the real catalogue gives a dealer-row list hundreds of thousands long. */
function groupBy<T>(rows: T[], key: (r: T) => string): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const r of rows) {
    const k = key(r);
    const list = m.get(k);
    if (list) list.push(r);
    else m.set(k, [r]);
  }
  return m;
}

/** Hi-Tech rows (plan or check) grouped by the Manna Treads item's first named property, in property order. */
export function hitechByQuality<T extends { item: SnapItem }>(
  snapshot: PricingSnapshot,
  rows: T[],
): { key: string; propertyNo: number | null; quality: string; rows: T[] }[] {
  const named = new Set(snapshot.properties.map((p) => p.no));
  const first = (i: SnapItem) => [...i.props].filter((p) => named.has(p)).sort((a, b) => a - b)[0] ?? null;
  const by = groupBy(rows, (r) => String(first(r.item) ?? ''));
  return [...by.entries()]
    .map(([k, rs]) => ({ key: k, propertyNo: k === '' ? null : Number(k), quality: k === '' ? 'No group' : propertyName(snapshot, Number(k)), rows: rs }))
    .sort((a, b) => (a.propertyNo ?? 999) - (b.propertyNo ?? 999));
}

export interface DealerLine {
  propertyNo: number;
  quality: string;
  rupeesOff: number;
  rows: DealerRow[];
  add: number;
  update: number;
  same: number;
}

export interface DealerSummary {
  cardCode: string;
  cardName: string;
  group?: string;
  priceList?: number;
  active?: boolean;
  /** One per quality the dealer has a rule on, in property order. */
  lines: DealerLine[];
  add: number;
  update: number;
  same: number;
  /** The dealer's new prices across every item, for a range. */
  prices: number[];
  problems: PlanProblem[];
  orphans: RatesPlan['orphans'];
}

const tally = (rows: DealerRow[], a: DealerAction) => rows.filter((r) => r.action === a).length;

/**
 * One summary per dealer that has a rule, a problem, or a price in SAP with no
 * rule behind it — sorted by name, the way the MD looks a dealer up.
 */
export function summariseDealers(snapshot: PricingSnapshot, plan: RatesPlan, rules: DealerRule[]): DealerSummary[] {
  const cust = new Map(snapshot.customers.map((c) => [c.code, c]));
  const rowsByCard = groupBy(plan.dealerRows, (r) => r.cardCode);
  const rulesByCard = groupBy(rules, (r) => r.cardCode);
  const problemsByCard = groupBy(plan.problems.filter((p) => p.cardCode), (p) => p.cardCode!);
  const orphansByCard = groupBy(plan.orphans, (o) => o.special.card);
  const codes = new Set<string>([...rulesByCard.keys(), ...orphansByCard.keys(), ...problemsByCard.keys()]);
  return [...codes]
    .map((code): DealerSummary => {
      const mine = [...(rulesByCard.get(code) ?? [])].sort((a, b) => a.propertyNo - b.propertyNo);
      const rows = rowsByCard.get(code) ?? [];
      const rowsByProp = groupBy(rows, (r) => String(r.propertyNo));
      const lines = mine.map((r): DealerLine => {
        const lr = rowsByProp.get(String(r.propertyNo)) ?? [];
        return {
          propertyNo: r.propertyNo,
          quality: propertyName(snapshot, r.propertyNo),
          rupeesOff: r.rupeesOff,
          rows: lr,
          add: tally(lr, 'ADD'),
          update: tally(lr, 'UPDATE'),
          same: tally(lr, 'same'),
        };
      });
      const c = cust.get(code);
      return {
        cardCode: code,
        cardName: c?.name ?? mine[0]?.cardName ?? code,
        group: c?.group,
        priceList: c?.priceList,
        active: c?.active,
        lines,
        add: tally(rows, 'ADD'),
        update: tally(rows, 'UPDATE'),
        same: tally(rows, 'same'),
        prices: rows.map((r) => r.newPrice),
        problems: problemsByCard.get(code) ?? [],
        orphans: orphansByCard.get(code) ?? [],
      };
    })
    .sort((a, b) => a.cardName.localeCompare(b.cardName));
}

export interface CheckLine {
  propertyNo: number;
  quality: string;
  rupeesOff: number;
  rows: CheckRow[];
  counts: StatusCounts;
}

export interface CheckDealer {
  cardCode: string;
  cardName: string;
  lines: CheckLine[];
  counts: StatusCounts;
  /** Rows that are not OK. */
  bad: number;
}

export function summariseCheck(rows: CheckRow[]): CheckDealer[] {
  const byCard = groupBy(rows, (r) => r.cardCode);
  return [...byCard.entries()]
    .map(([code, mine]): CheckDealer => {
      const counts = noCounts();
      for (const r of mine) counts[r.status]++;
      const byProp = groupBy(mine, (r) => String(r.propertyNo));
      const props = [...byProp.keys()].map(Number).sort((a, b) => a - b);
      const lines = props.map((p): CheckLine => {
        const lr = byProp.get(String(p))!;
        const c = noCounts();
        for (const r of lr) c[r.status]++;
        return { propertyNo: p, quality: lr[0].quality, rupeesOff: lr[0].rupeesOff, rows: lr, counts: c };
      });
      return { cardCode: code, cardName: mine[0].cardName, lines, counts, bad: mine.length - counts.OK };
    })
    .sort((a, b) => b.bad - a.bad || a.cardName.localeCompare(b.cardName));
}

/** Rules as they would be after the MD's edits: what is saved on confirm. */
export function ruleKey(r: Pick<DealerRule, 'cardCode' | 'propertyNo'>): string {
  return `${r.cardCode}|${r.propertyNo}`;
}

export interface RuleDiff {
  create: DealerRule[];
  update: DealerRule[];
  remove: DealerRule[];
}

/**
 * What saving the draft would do. With `names` (property number → the name
 * SAP gives it today) every rule is saved under its group's current name, so
 * one whose group was only renamed is updated too.
 */
export function diffRules(saved: DealerRule[], draft: DealerRule[], names?: Map<number, string>): RuleDiff {
  const byKey = new Map(saved.map((r) => [ruleKey(r), r]));
  const draftKeys = new Set(draft.map(ruleKey));
  const create: DealerRule[] = [];
  const update: DealerRule[] = [];
  for (const raw of draft) {
    const d = names?.has(raw.propertyNo) ? { ...raw, quality: names.get(raw.propertyNo)! } : raw;
    const s = byKey.get(ruleKey(d));
    if (!s) create.push(d);
    else if (
      Math.abs(s.rupeesOff - d.rupeesOff) > 0.0001 ||
      (s.note ?? '') !== (d.note ?? '') ||
      s.cardName !== d.cardName ||
      (names !== undefined && (s.quality ?? '') !== (d.quality ?? ''))
    ) {
      update.push({ ...d, id: s.id });
    }
  }
  const remove = saved.filter((s) => !draftKeys.has(ruleKey(s)));
  return { create, update, remove };
}

/** A discount of zero or less is not a discount; confirm refuses to save one. */
export function badRules(rules: DealerRule[]): DealerRule[] {
  return rules.filter((r) => !(Number.isFinite(r.rupeesOff) && r.rupeesOff > 0));
}

const nameKey = (s: string) => s.toUpperCase().replace(/[\s-]+/g, '');

/**
 * Rules saved under a group name SAP no longer gives that property — the
 * group was renamed (or renumbered) since. A rule follows the property NUMBER,
 * so after "Black Pearl" became "Hot - Black Pearl" a rule made for Black Pearl
 * now covers hot Black Pearl only. Shown so the MD can check each one; saving
 * (confirm) records the current name. Also rules on a number that is no
 * longer a named group at all.
 */
export function staleRules(snapshot: PricingSnapshot, rules: DealerRule[]): { rule: DealerRule; was: string; now: string | null }[] {
  const names = new Map(snapshot.properties.map((p) => [p.no, p.name]));
  return rules
    .filter((r) => {
      const now = names.get(r.propertyNo);
      return now === undefined || (Boolean(r.quality) && nameKey(r.quality) !== nameKey(now));
    })
    .map((r) => ({ rule: r, was: r.quality, now: names.get(r.propertyNo) ?? null }));
}
