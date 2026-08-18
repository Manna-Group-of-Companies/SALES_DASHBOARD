/**
 * The join between the two production flows.
 *
 * Checked against `shared/fixtures/production_order.json`, the same file
 * `app/test/production_order_test.dart` reads.
 */

import { describe, expect, it } from 'vitest';
import cases from '../../../../shared/fixtures/production_order.json';
import { alreadyDiverted, needsStockDiversion, type DivertLookup } from '../productionOrders';

describe('shared fixture: needs diversion', () => {
  for (const c of cases.needs_diversion) {
    it(c.why, () => {
      expect(needsStockDiversion(c.line)).toBe(c.expect);
    });
  }
});

describe('shared fixture: already diverted', () => {
  for (const c of cases.already_diverted) {
    it(c.why, () => {
      const orders = c.orders.map((o) => ({
        salesOrderId: o.sales_order_id ?? undefined,
        itemCode: o.item_code,
        purpose: o.purpose,
      })) as DivertLookup[];
      expect(alreadyDiverted(c.sales_order, c.item_code, orders)).toBe(c.expect);
    });
  }
});
