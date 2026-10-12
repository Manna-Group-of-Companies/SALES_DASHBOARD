// Which screens a sales manager may open on the phone.
//
// Checked against `shared/fixtures/manager_scope.json`, the same file the
// dashboard's `client/src/domain/__tests__/managerScope.test.ts` reads. Until
// 11 October 2026 the phone offered every manager the order pipeline while
// the dashboard offered it to one team only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/manager_scope.dart';

void main() {
  final fixture = json.decode(
          File('../shared/fixtures/manager_scope.json').readAsStringSync())
      as Map<String, dynamic>;

  group('shared/fixtures/manager_scope.json', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final got = screensForUser(
                isGM: c['role'] == 'general_manager',
                managedTeam: c['team'] as String?)
            .map((s) => s.name)
            .toList()
          ..sort();
        final want = (c['screens'] as List).cast<String>().toList()..sort();
        expect(got, want);
      });
    }
  });

  test('every screen name in the fixture is one the phone knows', () {
    final known = ManagerScreen.values.map((s) => s.name).toSet();
    final named = {
      ...(fixture['party_screens'] as List).cast<String>(),
      ...(fixture['order_screens'] as List).cast<String>(),
    };
    expect(named.difference(known), isEmpty);
  });

  test('a manager with no team record is never offered the order pipeline', () {
    expect(
        canOpenAs(
            isGM: false, managedTeam: null, screen: ManagerScreen.orders),
        isFalse);
  });
}
