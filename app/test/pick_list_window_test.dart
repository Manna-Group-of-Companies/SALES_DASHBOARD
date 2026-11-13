// A pick list opens two days before the order's delivery date (13 Nov 2026).
// The cases are shared with manna_pick_list_submit: shared/fixtures/pick_list_window.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/pick_list.dart';

String? _iso(DateTime? d) => d == null
    ? null
    : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  final fixture = json.decode(File('../shared/fixtures/pick_list_window.json').readAsStringSync()) as Map;

  test('the phone opens picking as many days ahead as the fixture says', () {
    expect(kPickOpensDaysBefore, fixture['days_before']);
  });

  group('shared/fixtures/pick_list_window.json', () {
    for (final c in (fixture['cases'] as List).cast<Map>()) {
      test('${c['why']}', () {
        final today = DateTime.parse('${c['today']}');
        expect(_iso(pickOpensOn(c['delivery_date'])), c['opens_on']);
        expect(pickIsOpen(c['delivery_date'], today), c['open']);
      });
    }
  });

  test('the time of day does not matter: late on the day before opening is still locked', () {
    expect(pickIsOpen('2026-11-16', DateTime(2026, 11, 13, 23, 59)), isFalse);
    expect(pickIsOpen('2026-11-16', DateTime(2026, 11, 14, 0, 1)), isTrue);
  });

  test('a delivery date with a time on it reads as its day', () {
    expect(_iso(pickOpensOn('2026-11-15 00:00:00')), '2026-11-13');
  });

  test("ERPNext's string 'null' is no date, so the order is not held back", () {
    expect(pickOpensOn('null'), isNull);
    expect(pickIsOpen('null', DateTime(2026, 11, 13)), isTrue);
  });
}
