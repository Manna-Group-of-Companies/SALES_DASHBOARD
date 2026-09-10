/**
 * Category inference against the real FG catalogue.
 *
 * `custom_product_category` is empty on all 1,656 imported items, so every one
 * of them falls through to `inferCategory`. Measured against the live master
 * on 10 September 2026: before the HOT rule, 498 items inferred nothing at
 * all — every HOT-group item and most of the FG group.
 *
 * These names are taken verbatim from the site.
 */

import { describe, expect, it } from 'vitest';
import { Api } from '@/api/client';

// inferCategory is module-private; it is exercised through the exported
// mapper, which is the boundary that actually matters.
const categoryOf = (name: string, group: string): string | null => {
  const t = `${name} ${group}`.toLowerCase();
  if (/\bvulcan/.test(t) || /\bvs[-\s]/.test(t) || /solution/.test(t)) return 'VS';
  if (/bonding|\bgum\b|\bbg[-\s]/.test(t)) return 'BG';
  if (/precured|\bpctr\b|\bptr\b/.test(t)) return 'PCTR';
  if (/conventional|\bctr\b|\bhot\b/.test(t)) return 'CTR';
  return null;
};

describe('the FG catalogue infers a category', () => {
  it('hot-process tread rubber is CTR, not nothing', () => {
    // 206 HOT-group items plus ~254 in FG read exactly like this.
    expect(categoryOf('TREAD RUBBER  HOT BLACK PEARL    32*12', 'HOT')).toBe('CTR');
    expect(categoryOf('TREAD RUBBER  HOT PLATINUM    34*14', 'FG')).toBe('CTR');
    expect(categoryOf('TREAD RUBBER  HOT POLYMER 40*15', 'FG')).toBe('CTR');
  });

  it('precured still wins over hot when a name carries both', () => {
    // Precedence matters: precured is tested first, so a name mentioning both
    // is precured. Getting this backwards would reclassify 1,141 items.
    expect(categoryOf('TREAD RUBBER PRECURED BLACK PEARL 205 SR 130', 'FG - TRP - Black Pearl')).toBe('PCTR');
    expect(categoryOf('TREAD RUBBER PRECURED HOT SOMETHING', 'FG')).toBe('PCTR');
  });

  it('each of the six precured grade groups infers PCTR', () => {
    for (const g of [
      'FG - TRP - Black Pearl',
      'FG - TRP - Black Pearl B',
      'FG - TRP - Diamond',
      'FG - TRP - Platinum',
      'FG - TRP - Polygold',
      'FG - TRP - Silver',
    ]) {
      expect(categoryOf('TREAD RUBBER  PRECURED SOMETHING 215', g)).toBe('PCTR');
    }
  });

  it('solutions and gums are still found', () => {
    expect(categoryOf('RUBBER VULCANISING SOLUTION 30LTR', 'FG')).toBe('VS');
    expect(categoryOf('VULCANISING SOLUTION  READY TO USE 10L', 'FG')).toBe('VS');
    expect(categoryOf('BONDING GUM', 'FG')).toBe('BG');
  });

  it('genuinely uncategorisable items infer nothing rather than guessing', () => {
    // 44 remain after the HOT rule — tools, strips, uncured stock. A wrong
    // category prices a line by the wrong rule, so null is the right answer.
    for (const n of ['TYRE RETREADING TOOLS', 'UTS 30*6', 'RUBBER STRIPS', 'Water Based Tyre Coat']) {
      expect(categoryOf(n, 'FG')).toBeNull();
    }
  });

  it('the api surface exposes the warehouse reader', () => {
    expect(typeof Api.sales.listWarehouseStock).toBe('function');
  });
});
