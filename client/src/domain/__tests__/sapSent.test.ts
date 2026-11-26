/**
 * What every Sales Order says about SAP. `shared/fixtures/sap_sent.json`
 * states the rule; `app/test/sap_sent_test.dart` holds the phone to the same
 * cases.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/sap_sent.json';
import { sapSent } from '../sapSent';

describe('what an order says about SAP', () => {
  for (const c of fixture.cases) {
    it(c.why, () => {
      const got = sapSent({
        poStatus: c.po_status,
        gmApprovedBy: c.gm_approved_by,
        mtSalesOrder: c.mt_sales_order,
        sapSalesOrder: c.sap_sales_order,
      });
      expect(got).toEqual({
        sent: c.expect.sent,
        label: c.expect.label,
        approvedBy: c.expect.approved_by,
        numbers: c.expect.numbers,
      });
    });
  }
});
