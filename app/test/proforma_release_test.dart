// When the rep may hand an order's proforma to the customer, against the
// shared fixture the dashboard's suite reads too.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proforma_release.dart';

void main() {
  final fixture = json.decode(
          File('../shared/fixtures/proforma_release.json').readAsStringSync())
      as Map<String, dynamic>;

  test('the held message matches the fixture word for word', () {
    expect(kProformaHeld, (fixture['messages'] as Map)['held']);
  });

  group('proforma release', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'], () {
        expect(
          proformaHeld(
            customer: Map<String, dynamic>.from(c['customer'] as Map),
            orderTotal: (c['order_total'] as num).toDouble(),
            poStatus: c['po_status'],
            proformaStatus: c['proforma_status'],
          ),
          c['held'],
        );
      });
    }
  });
}
