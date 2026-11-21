// What a rep or manager is told when Hi-Tech moves an item's delivery date.
// `shared/fixtures/ship_date_watch.json` states the rule; this file asserts
// the same cases against `shipDateChangesSince`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/ship_date_watch.dart';

void main() {
  final raw =
      File('../shared/fixtures/ship_date_watch.json').readAsStringSync();
  final doc = json.decode(raw) as Map<String, dynamic>;
  final cases = doc['cases'] as List;

  group('shared/fixtures/ship_date_watch.json', () {
    for (final c in cases) {
      final m = c as Map<String, dynamic>;
      test(m['why'], () {
        final previousRaw = m['previous'];
        final previous = previousRaw == null
            ? null
            : (previousRaw as Map).map((k, v) => MapEntry('$k', '$v'));
        final lines = (m['lines'] as List)
            .map((l) => (l as Map).cast<String, dynamic>())
            .toList();
        final expected = (m['changes'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

        final changes = shipDateChangesSince(previous, lines);
        expect(changes.length, expected.length, reason: m['why'] as String);
        for (var i = 0; i < expected.length; i++) {
          expect(changes[i].lineId, expected[i]['lineId']);
          expect(changes[i].from, expected[i]['from']);
          expect(changes[i].to, expected[i]['to']);
          expect(changes[i].closed, expected[i]['closed']);
        }
      });
    }
  });

  test('a date appearing describes itself as still editable', () {
    final c =
        const ShipDateChange(lineId: 'r', itemName: 'X', from: '', to: '2026-11-20');
    expect(describeShipDateChange(c), contains('still editable'));
  });

  test('a move describes both dates', () {
    final c = const ShipDateChange(
        lineId: 'r', itemName: 'X', from: '2026-11-20', to: '2026-11-18');
    final d = describeShipDateChange(c);
    expect(d, contains('2026-11-18'));
    expect(d, contains('2026-11-20'));
  });

  test('a closed line describes itself as closed, not as a move to blank',
      () {
    final c =
        const ShipDateChange(lineId: 'r', itemName: 'X', from: '2026-11-20', to: '');
    expect(describeShipDateChange(c), contains('closed in SAP'));
  });
}
