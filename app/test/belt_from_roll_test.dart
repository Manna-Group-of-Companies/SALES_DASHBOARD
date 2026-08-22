// A belt comes out of a roll.
//
// `shared/fixtures/belt_from_roll.json` states the rule; this file asserts the
// phone obeys it, and `client/src/domain/__tests__/beltFromRoll.test.ts`
// asserts the dashboard does. Both read the same cases, so the two cannot
// drift apart again.
//
// The bug this closes was found in the field on 21 August 2026: a rep ordering
// five rolls and one loose belt against a pool of 48 rolls was told the belt
// would be made to order.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/pool_allocation.dart';

void main() {
  final raw = File('../shared/fixtures/belt_from_roll.json').readAsStringSync();
  final cases = (json.decode(raw)['allocate'] as List).cast<Map<String, dynamic>>();

  double n(dynamic v) => (v as num).toDouble();
  int i(dynamic v) => (v as num).toInt();

  PoolAllocation run(Map<String, dynamic> c) => allocateFromPool(
        wantRolls: n(c['want']['rolls']),
        wantBelts: i(c['want']['belts']),
        poolRolls: n(c['pool']['rolls']),
        poolBelts: i(c['pool']['belts']),
        beltsPerRoll: i(c['pool']['beltsPerRoll']),
      );

  group('serving loose belts by opening a roll', () {
    for (final c in cases) {
      test(c['why'] as String, () {
        final got = run(c);
        final want = c['expect'] as Map<String, dynamic>;
        expect(got.rolls, n(want['rolls']));
        expect(got.belts, i(want['belts']));
        expect(got.rollsOpened, i(want['rollsOpened']));
        expect(got.shortRolls, n(want['shortRolls']));
        expect(got.shortBelts, i(want['shortBelts']));
      });
    }

    test('never takes more rolls off the shelf than are on it', () {
      // Whole rolls promised plus rolls opened for belts both leave the roll
      // count. Getting this wrong oversells the shelf by exactly the rolls
      // that were cut, which is the failure the old code hid by never
      // cutting any.
      for (final c in cases) {
        final got = run(c);
        expect(got.rolls + got.rollsOpened,
            lessThanOrEqualTo(n(c['pool']['rolls'])));
      }
    });

    test('accounts for every unit asked for, as stock or as production', () {
      for (final c in cases) {
        final got = run(c);
        expect(got.rolls + got.shortRolls, n(c['want']['rolls']));
        expect(got.belts + got.shortBelts, i(c['want']['belts']));
      }
    });

    test('never promises more than was asked for', () {
      for (final c in cases) {
        final got = run(c);
        expect(got.rolls, lessThanOrEqualTo(n(c['want']['rolls'])));
        expect(got.belts, lessThanOrEqualTo(i(c['want']['belts'])));
      }
    });
  });

  group('the case a rep actually hit', () {
    test('five rolls and one belt against 48 rolls is entirely from stock', () {
      final got = allocateFromPool(
        wantRolls: 5,
        wantBelts: 1,
        poolRolls: 48,
        poolBelts: 0,
        beltsPerRoll: 6,
      );
      expect(got.splits, isFalse, reason: 'nothing should be made to order');
      expect(got.rolls, 5);
      expect(got.belts, 1);
      expect(got.rollsOpened, 1);
    });
  });
}
