// What every Sales Order says about SAP. Read from the shared fixture the
// dashboard's suite reads too, so a rep and a manager are told the same thing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sap_sent.dart';

void main() {
  final fixture = json.decode(
          File('../shared/fixtures/sap_sent.json').readAsStringSync())
      as Map<String, dynamic>;

  group('what an order says about SAP', () {
    for (final c
        in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final got = SapSent.fromOrder({
          'custom_po_status': c['po_status'],
          'custom_gm_approved_by': c['gm_approved_by'],
          'custom_mt_sales_order': c['mt_sales_order'],
          'custom_sap_sales_order': c['sap_sales_order'],
        });
        final want = c['expect'] as Map<String, dynamic>;
        expect(got.sent, want['sent']);
        expect(got.label, want['label']);
        expect(got.approvedBy, want['approved_by']);
        expect(got.numbers, want['numbers']);
      });
    }
  });

  group('which orders reached SAP since this device last looked', () {
    for (final c in (fixture['news'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final orders = [
          for (final o in (c['orders'] as List).cast<Map<String, dynamic>>())
            {
              'name': o['id'],
              'custom_po_status': o['po_status'],
              'custom_mt_sales_order': o['mt_sales_order'],
              'custom_sap_sales_order': o['sap_sales_order'],
            }
        ];
        final seen = (c['seen'] as List?)?.cast<String>();
        final got = sapSentNews(seen, orders);
        expect(got.news.map((o) => o['name']).toList(), c['expect_news']);
        expect(got.seen, c['expect_seen']);
      });
    }
  });

  test('a list row with none of the fields fetched says nothing', () {
    expect(SapSent.fromOrder(const {}).isEmpty, isTrue);
  });
}
