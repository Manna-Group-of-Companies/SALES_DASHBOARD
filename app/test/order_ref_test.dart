// Which order a document points at, and who an order is for.
//
// A customer's order lives in `Sales Order`, a lead's in `Lead Order`. The
// choice is made here rather than at each call site, so a lead order is never
// looked up — or linked — as a Sales Order.
//
// `field` and `filter` went with `Manna Stock Reservation` in b5f645f: SAP owns
// the booking now, and nothing in ERPNext holds stock against an order.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/order_ref.dart';

void main() {
  group('Where an order lives', () {
    test('a customer order lives in Sales Order', () {
      const ref = OrderRef('SAL-ORD-2026-00123');
      expect(ref.isLead, isFalse);
      expect(ref.doctype, 'Sales Order');
    });

    test('a lead order lives in Lead Order', () {
      const ref = OrderRef.lead('LO-00042');
      expect(ref.isLead, isTrue);
      expect(ref.doctype, 'Lead Order');
    });

    test('the two never collide, even on the same name', () {
      // Nothing stops a Lead Order and a Sales Order sharing a name one day.
      // They must still be different references.
      expect(const OrderRef('X-1'), isNot(const OrderRef.lead('X-1')));
      expect(const OrderRef('X-1'), const OrderRef('X-1'));
    });
  });

  group('Who the order is for', () {
    test('a customer shows its customer name', () {
      final p = OrderParty.customer(
          {'name': 'CUST-001', 'customer_name': 'Renjith Tyres'});
      expect(p.name, 'CUST-001');
      expect(p.label, 'Renjith Tyres');
      expect(p.isLead, isFalse);
      expect(p.kindLabel, 'Customer');
    });

    test('a lead prefers the company over the contact', () {
      // The order is for the business, not the person who happened to be in
      // the shop when the rep called.
      final p = OrderParty.lead({
        'name': 'CRM-LEAD-2026-00029',
        'lead_name': 'Manikandan',
        'company_name': 'Sky Tyres',
      });
      expect(p.label, 'Sky Tyres');
      expect(p.isLead, isTrue);
      expect(p.kindLabel, 'Lead');
    });

    test('a lead with no company falls back to the contact', () {
      final p = OrderParty.lead(
          {'name': 'CRM-LEAD-1', 'lead_name': 'Manikandan', 'company_name': ''});
      expect(p.label, 'Manikandan');
    });

    test("Frappe's literal 'null' does not reach the screen", () {
      final p = OrderParty.lead({
        'name': 'CRM-LEAD-1',
        'lead_name': 'Manikandan',
        'company_name': 'null',
      });
      expect(p.label, 'Manikandan');
    });

    test('a party with nothing but a name still renders', () {
      expect(OrderParty.customer({'name': 'CUST-9'}).label, 'CUST-9');
      expect(OrderParty.lead({'name': 'LEAD-9'}).label, 'LEAD-9');
    });
  });
}
