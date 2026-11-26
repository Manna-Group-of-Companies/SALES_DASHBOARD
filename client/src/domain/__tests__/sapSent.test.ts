/**
 * What every Sales Order says about SAP. `shared/fixtures/sap_sent.json`
 * states the rule; `app/test/sap_sent_test.dart` holds the phone to the same
 * cases.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/sap_sent.json';
import { sapSent, sapSentNews } from '../sapSent';

describe('what an order says about SAP', () => {
  for (const c of fixture.cases) {
    it(c.why, () => {
      const got = sapSent({
        poStatus: c.po_status,
        gmApprovedBy: c.gm_approved_by,
        mtSalesOrder: c.mt_sales_order,
        sapSalesOrder: c.sap_sales_order,
        sapOrderStatus: c.sap_order_status,
        sapSalesOrderStatus: c.sap_sales_order_status,
      });
      expect(got).toEqual({
        sent: c.expect.sent,
        label: c.expect.label,
        approvedBy: c.expect.approved_by,
        numbers: c.expect.numbers,
        status: c.expect.status,
      });
    });
  }
});

describe('which orders reached SAP since this device last looked', () => {
  for (const c of fixture.news) {
    it(c.why, () => {
      const orders = c.orders.map((o) => ({
        id: o.id,
        poStatus: o.po_status,
        mtSalesOrder: o.mt_sales_order,
        sapSalesOrder: o.sap_sales_order,
      }));
      const got = sapSentNews(c.seen, orders);
      expect(got.news.map((o) => o.id)).toEqual(c.expect_news);
      expect(got.seen).toEqual(c.expect_seen);
    });
  }
});
