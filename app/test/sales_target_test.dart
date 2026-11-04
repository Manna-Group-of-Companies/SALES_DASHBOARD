// How far a rep is towards a monthly target.
//
// Checked against `shared/fixtures/sales_target_progress.json`, the same file
// the dashboard's `client/src/domain/__tests__/salesTarget.test.ts` reads.
// What counts as achieved (invoiced lines only) is the server's; this pins
// what both apps make of the totals it returns.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sales_target.dart';

void main() {
  final fixture = json.decode(File('../shared/fixtures/sales_target_progress.json')
      .readAsStringSync()) as Map<String, dynamic>;

  group('shared/fixtures/sales_target_progress.json', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final r = TargetRow.fromJson(c['row'] as Map);
        expect(r.hasTarget, c['has_target']);
        expect(r.hasInvoices, c['has_invoices']);
        expect(r.achieved, closeTo((c['achieved'] as num).toDouble(), 1e-9));
        expect(r.fraction, closeTo((c['fraction'] as num).toDouble(), 1e-9));
      });
    }
  });

  test('reads the Server Script reply, lines and edit rights included', () {
    final m = TargetMonth.fromJson({
      'month': 'Nov',
      'year': 2026,
      'is_gm': 0,
      'can_edit': ['Amjad Pr'],
      'rows': [
        {
          'sales_person': 'Amjad Pr',
          'currency': 'INR',
          'target_name': 'TGT-00007',
          'target_amount': 100000,
          'target_unit': 'Currency',
          'invoiced_amount': 18000,
          'invoiced_kg': 72,
          'lines': [
            {
              'order': 'SAL-ORD-2026-00156',
              'customer_name': 'A Tyres',
              'item_name': 'PCTR 10x16',
              'invoice': '41234',
              'invoice_date': '2026-11-02',
              'amount': 18000,
              'kg': 72,
            }
          ],
        }
      ],
    });
    expect(m.canEdit, {'Amjad Pr'});
    final r = m.rowFor('Amjad Pr')!;
    expect(r.lines.single.invoice, '41234');
    expect(r.hasInvoices, isTrue);
    expect(r.fraction, closeTo(0.18, 1e-9));
    expect(m.rowFor('Nobody'), isNull);
  });
}
