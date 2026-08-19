// How far through production a line is, as the floor sees it.
//
// Checked against `shared/fixtures/production_progress.json`, the same file
// the dashboard's
// `client/src/domain/__tests__/productionProgress.test.ts` reads.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/models/product_category.dart';

Map<String, dynamic> _fixture() {
  final f = File('../shared/fixtures/production_progress.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _fixture();

  final sequences = <String, List<String>>{
    'minimum_stock': fromStockStages,
    'pctr': stagesFor(ProductCategory.pctr),
    'generic': stagesFor(ProductCategory.other),
  };

  group('shared fixture: the sequences the fixture names', () {
    test('match what the code actually uses', () {
      final want = (fx['sequences'] as Map).cast<String, dynamic>();
      for (final entry in want.entries) {
        final expected = (entry.value as List).map((e) => '$e').toList();
        expect(sequences[entry.key], expected, reason: entry.key);
      }
    });
  });

  group('shared fixture: what the floor is shown', () {
    for (final raw in fx['progress'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final seq = sequences[c['sequence']]!;
        final stage = c['stage'];
        final want = (c['expect'] as Map).cast<String, dynamic>();

        expect(workPosition(seq, stage), want['position']);
        if (want['total'] != null) expect(workTotal(seq), want['total']);
        if (want['progress'] != null) {
          expect(workProgress(seq, stage), (want['progress'] as num).toDouble());
        }
        if (want['complete'] != null) {
          expect(workComplete(seq, stage), want['complete']);
        }
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('the floor is never shown a stage it cannot reach', () {
    test('drops Dispatched from every cycle, and nothing else', () {
      for (final category in ProductCategory.values) {
        final seq = stagesFor(category);
        expect(workSequence(seq), isNot(contains(kStageDispatched)));
        expect(workSequence(seq).length, seq.length - 1);
      }
    });

    test('ends every cycle on Packed, which is what makes packed mean finished',
        () {
      for (final seq in [
        ...ProductCategory.values.map(stagesFor),
        fromStockStages,
      ]) {
        expect(workSequence(seq).last, 'Packed');
        expect(workComplete(seq, 'Packed'), isTrue);
        expect(workProgress(seq, 'Packed'), 1.0);
      }
    });
  });

  group('an unset stage', () {
    test('reads as the start however Frappe returned it', () {
      final seq = stagesFor(ProductCategory.pctr);
      for (final v in [null, '', '   ', 'null']) {
        expect(workPosition(seq, v), 1, reason: 'stage $v');
        expect(workProgress(seq, v), 0, reason: 'stage $v');
        expect(workComplete(seq, v), isFalse, reason: 'stage $v');
      }
    });
  });
}
