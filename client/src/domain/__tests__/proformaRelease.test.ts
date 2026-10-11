/**
 * When the rep may hand an order's proforma to the customer, against the
 * shared fixture the phone's suite reads too.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/proforma_release.json';
import { PROFORMA_HELD, proformaHeld } from '../proformaRelease';

describe('proforma release', () => {
  it('the held message matches the fixture word for word', () => {
    expect(PROFORMA_HELD).toBe(fixture.messages.held);
  });

  for (const c of fixture.cases) {
    it(c.why, () => {
      expect(
        proformaHeld({
          customer: c.customer,
          orderTotal: c.order_total,
          poStatus: c.po_status,
          proformaStatus: c.proforma_status,
        }),
      ).toBe(c.held);
    });
  }
});
