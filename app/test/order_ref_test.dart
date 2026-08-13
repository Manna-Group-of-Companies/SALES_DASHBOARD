// Which order a booking points at, and who an order is for.
//
// The bug this guards against is quiet and expensive: a lead order's booking
// written into `sales_order`, where it either fails a link check or — worse —
// silently holds stock against nothing. Exactly one of the two fields is ever
// set, and that choice is made here rather than at each call site.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/order_ref.dart';

void main() {
  group('Where a booking points', () {
    test('a customer order books against sales_order', () {
      const ref = OrderRef('SAL-ORD-2026-00123');
      expect(ref.isLead, isFalse);
      expect(ref.field, 'sales_order');
      expect(ref.doctype, 'Sales Order');
    });

    test('a lead order books against lead_order', () {
      const ref = OrderRef.lead('LO-00042');
      expect(ref.isLead, isTrue);
      expect(ref.field, 'lead_order');
      expect(ref.doctype, 'Lead Order');
    });

    test('the filter matches the field it is stored in', () {
      expect(const OrderRef('SO-1').filter, '["sales_order","=","SO-1"]');
      expect(const OrderRef.lead('LO-1').filter, '["lead_order","=","LO-1"]');
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
