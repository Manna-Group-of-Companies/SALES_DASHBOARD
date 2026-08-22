// What counts as a duplicate order, read from the shared fixture.
//
// The rule is stated in `shared/fixtures/duplicate_order.json`; this only
// asserts the phone obeys it. The failure mode worth guarding is a warning that
// fires too often — a rep who learns to dismiss it blind is worse off than one
// who never saw it, which is why "no overlap" and "not open" have as many cases
// here as the positive ones.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/duplicate_order.dart';

void main() {
  final raw =
      File('../shared/fixtures/duplicate_order.json').readAsStringSync();
  final cases = (json.decode(raw)['find'] as List).cast<Map<String, dynamic>>();

  group('spotting an order the customer already has open', () {
    for (final c in cases) {
      test(c['why'] as String, () {
        final got = findDuplicate(
          mine: (c['mine'] as List).map((e) => '$e').toList(),
          otherOpenOrders: (c['others'] as Map).map((k, v) =>
              MapEntry('$k', (v as List).map((e) => '$e').toList())),
        );
        final want = c['expect'];

        if (want == null) {
          expect(got, isNull);
          return;
        }
        expect(got, isNotNull);
        expect(got!.order, want['order']);
        expect(got.items, (want['items'] as List).map((e) => '$e').toList());
      });
    }

    test('never names an order that shares nothing', () {
      for (final c in cases) {
        final others = (c['others'] as Map).map((k, v) =>
            MapEntry('$k', (v as List).map((e) => '$e').toList()));
        final got = findDuplicate(
          mine: (c['mine'] as List).map((e) => '$e').toList(),
          otherOpenOrders: others,
        );
        if (got == null) continue;
        // Everything reported as shared must genuinely be on both sides.
        for (final item in got.items) {
          expect(others[got.order]!.map((s) => s.trim()), contains(item));
        }
      }
    });
  });

  group('what the rep is told', () {
    test('one shared product is named outright', () {
      final text = duplicateWarningText(
          const DuplicateFinding(order: 'SAL-ORD-1', items: ['TREAD X']));
      expect(text, contains('TREAD X'));
      expect(text, contains('SAL-ORD-1'));
    });

    test('several are counted rather than listed', () {
      // A shop counter is not the place for a list of six item codes.
      final text = duplicateWarningText(const DuplicateFinding(
          order: 'SAL-ORD-2', items: ['A', 'B', 'C']));
      expect(text, contains('3 products'));
      expect(text, contains('SAL-ORD-2'));
    });
  });
}
