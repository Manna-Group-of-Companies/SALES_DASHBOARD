// What each proforma line puts in each column.
//
// Checked against `shared/fixtures/proforma_columns.json`, the same file the
// dashboard's `client/src/domain/__tests__/proforma.test.ts` reads. The phone
// renders a PDF and the dashboard renders HTML, but to a customer they are one
// document — so a column that differs between them is a customer being sent two
// versions of the same quote.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proforma_columns.dart';

Map<String, dynamic> _fixture() =>
    json.decode(File('../shared/fixtures/proforma_columns.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final fx = _fixture();

  group('shared fixture: the columns', () {
    test('is the set the fixture names, with the old ones gone', () {
      expect(fx['columns'],
          ['#', 'Description', 'Rolls', 'Belts', 'Cans', 'Qty', 'MRP', 'Amount']);
      final removed = (fx['removed'] as Map).keys.map((e) => '$e').toList()..sort();
      expect(removed, ['gst', 'hsn', 'item_code', 'per']);
    });
  });

  group('shared fixture: each line', () {
    for (final raw in fx['lines'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final line = (c['line'] as Map).cast<String, dynamic>();
        final got = proformaCells(line);
        final e = (c['expect'] as Map).cast<String, dynamic>();
        if (e.containsKey('rolls')) expect(got.rolls, e['rolls']);
        if (e.containsKey('belts')) expect(got.belts, e['belts']);
        if (e.containsKey('cans')) expect(got.cans, e['cans']);
        if (e.containsKey('qty')) expect(got.qty, e['qty']);
        if (e.containsKey('mrp')) {
          expect(got.mrp, closeTo((e['mrp'] as num).toDouble(), 0.01));
        }
        if (e.containsKey('mrp_unit')) expect(got.mrpUnit, e['mrp_unit']);
        if (e.containsKey('amount')) {
          expect(got.amount, closeTo((e['amount'] as num).toDouble(), 0.01));
        }
        if (e.containsKey('reconciles_on')) {
          expect(reconcilesOn(line), e['reconciles_on']);
        }
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('every row multiplies out against something the customer can see', () {
    test('reconciles on the column its category is billed by', () {
      for (final raw in fx['lines'] as List) {
        final c = (raw as Map).cast<String, dynamic>();
        final line = (c['line'] as Map).cast<String, dynamic>();
        final cells = proformaCells(line);
        if (cells.amount == 0) continue;

        final on = reconcilesOn(line);
        final shown = on == 'cans'
            ? double.parse(cells.cans)
            : double.parse(cells.qty.split(' ').first);
        expect(shown * cells.mrp, closeTo(cells.amount, 0.1),
            reason: '${c['why']} — $shown x ${cells.mrp}');
      }
    });
  });

  group('a packing column never prints a zero', () {
    test('leaves the cell empty instead', () {
      // Empty reads as "not applicable"; 0 reads as "none supplied". Hot
      // rubber is not cut into belts at all — that is not the same as a roll
      // that yielded none.
      final ctr = proformaCells(
          {kFieldCategory: 'CTR', kFieldRolls: 1, kFieldBelts: 0});
      expect(ctr.belts, '');
      expect(ctr.cans, '');
      expect(proformaCells({kFieldCategory: 'BG', kFieldRolls: 0}).rolls, '');
    });
  });

  group('the solution row that used not to add up', () {
    test('bills by the can, not by the litre', () {
      final vs = proformaCells({
        kFieldCategory: 'VS',
        kFieldWeight: 90,
        kFieldRatePerKg: 195,
        'qty': 3,
        'rate': 195,
        'amount': 585,
      });
      expect(vs.cans, '3');
      expect(vs.qty, '90 L');
      expect(vs.mrpUnit, 'per can');
      expect(double.parse(vs.cans) * vs.mrp, closeTo(vs.amount, 0.01));
    });
  });

  group('rubbish in a field does not become NaN on a customer document', () {
    test('reads as nothing instead', () {
      final cells = proformaCells({
        kFieldCategory: 'PCTR',
        kFieldRolls: 'x',
        kFieldWeight: null,
        'rate': 'abc',
        'amount': 0,
      });
      expect(cells.rolls, '');
      expect(cells.mrp.isNaN, isFalse);
      expect(cells.amount, 0);
    });
  });
}
