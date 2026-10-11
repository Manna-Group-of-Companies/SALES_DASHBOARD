// Production sees the order and the rep who sold it, never the customer —
// "just like in SAP" (the user, 26 Sep 2026). The production screens are fed
// through Api.withholdCustomer, so these pin that nothing naming or reaching
// the customer survives it, and that what the floor needs does.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/services/api.dart';

void main() {
  Map<String, dynamic> order() => {
        'name': 'SAL-ORD-2026-00147',
        'customer': 'ZZ-TEST-A',
        'customer_name': 'ZZ Test Dealer A',
        'address_display': '1 Test Road, Kottayam',
        'customer_address': 'ZZ-TEST-A-Billing',
        'shipping_address': '1 Test Road, Kottayam',
        'shipping_address_name': 'ZZ-TEST-A-Shipping',
        'contact_person': 'ZZ-TEST-A-Contact',
        'contact_display': 'Test Contact',
        'contact_mobile': '9999999999',
        'contact_phone': '0481000000',
        'contact_email': 'dealer@example.com',
        'territory': 'India',
        'custom_sales_person': 'Test Rep',
        'custom_sap_sales_order': '426',
        'destination': 'Test Rep - Kottayam',
        'items': [
          {'item_code': 'I-14636', 'qty': 2}
        ],
      };

  test('every customer field is removed', () {
    final o = Api.withholdCustomer(order());
    for (final f in Api.customerFields) {
      expect(o.containsKey(f), isFalse, reason: '$f reached production');
    }
    expect(o.values.whereType<String>().any((v) => v.contains('ZZ Test Dealer')),
        isFalse);
  });

  test('the order, the rep, the SAP number, the route and the lines stay', () {
    final o = Api.withholdCustomer(order());
    expect(o['name'], 'SAL-ORD-2026-00147');
    expect(o['custom_sales_person'], 'Test Rep');
    expect(o['custom_sap_sales_order'], '426');
    expect(o['destination'], 'Test Rep - Kottayam');
    expect((o['items'] as List).length, 1);
  });
}
