// The join between the two production flows.
//
// Checked against `shared/fixtures/production_order.json`, the same file
// `client/src/domain/__tests__/productionOrders.test.ts` reads.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/production_order.dart';

Map<String, dynamic> _fixture() {
  // Relative to `app/`, which is where `flutter test` runs from.
  final f = File('../shared/fixtures/production_order.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _fixture();

  group('shared fixture: needs diversion', () {
    for (final raw in fx['needs_diversion'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final line = (c['line'] as Map).cast<String, dynamic>();
        expect(needsStockDiversion(line), c['expect']);
      });
    }
  });

  group('shared fixture: already diverted', () {
    for (final raw in fx['already_diverted'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final orders = (c['orders'] as List)
            .map((o) => (o as Map).cast<String, dynamic>())
            .map((o) => DivertLookup(
                  salesOrderId: o['sales_order_id'] as String?,
                  itemCode: o['item_code'] as String,
                  purpose: o['purpose'] as String,
                ))
            .toList();
        expect(
          alreadyDiverted(c['sales_order'] as String, c['item_code'] as String, orders),
          c['expect'],
        );
      });
    }
  });
}
