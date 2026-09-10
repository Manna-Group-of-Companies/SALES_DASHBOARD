// Kilos to rolls and belts, read from the shared fixture the dashboard's suite
// reads too.
//
// The cases that matter most are the ones with no weights. Frappe has no null
// for an Int or a Float, so an item nobody has weighed is indistinguishable
// from one weighing nothing — and 288 items are about to receive real SAP
// stock in exactly that state.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/stock_from_kg.dart';

void main() {
  final raw = File('../shared/fixtures/stock_from_kg.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;

  group('kilos to rolls and belts', () {
    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final got = stockFromKg(
          kg: c['kg'] as num,
          weightPerRoll: c['weight_per_roll'] as num,
          beltsPerRoll: c['belts_per_roll'] as num,
        );
        final want = c['expect'] as Map<String, dynamic>;
        expect(got.known, want['known']);
        if (got.known) {
          expect(got.rolls, want['rolls']);
          expect(got.looseBelts, want['loose_belts']);
          expect(got.totalBelts, want['total_belts']);
          expect(got.weightPerBelt,
              closeTo((want['weight_per_belt'] as num).toDouble(), 0.001));
        } else {
          expect(got.rolls, isNull);
          expect(got.totalBelts, isNull);
        }
      });
    }
  });

  group('the mistakes this rule exists to prevent', () {
    test('never yields infinity, whatever the zero', () {
      for (final pair in [
        [0, 6],
        [38.4, 0],
        [0, 0],
      ]) {
        final got = stockFromKg(
            kg: 500, weightPerRoll: pair[0], beltsPerRoll: pair[1]);
        expect(got.known, isFalse, reason: 'w=${pair[0]} b=${pair[1]}');
        expect(got.rolls, isNull);
        expect(got.totalBelts, isNull);
      }
    });

    test('an unweighed item is never reported as zero rolls', () {
      // Zero reads as "out of stock". The truth is "we cannot convert this".
      final got = stockFromKg(kg: 512.5, weightPerRoll: 0, beltsPerRoll: 0);
      expect(got.known, isFalse);
      expect(got.rolls, isNull);
      expect(got.kg, 512.5);
    });

    test('an empty shelf with good weights is a KNOWN zero', () {
      // Nothing on the shelf is an answer; no weights is the absence of one.
      final got = stockFromKg(kg: 0, weightPerRoll: 38.4, beltsPerRoll: 6);
      expect(got.known, isTrue);
      expect(got.rolls, 0);
      expect(got.totalBelts, 0);
    });

    test('Nos and Litre items are not asked the question at all', () {
      final got = stockFromKg(
          kg: 40, weightPerRoll: 38.4, beltsPerRoll: 6, isWeighed: false);
      expect(got.known, isFalse);
      expect(got.reason, StockUnknownReason.notWeighed);
    });

    test('rounds DOWN, never up - an offcut is not a belt', () {
      // 149.2 kg is 23.3 belts: 23 sellable and a 2 kg remnant.
      final got = stockFromKg(kg: 149.2, weightPerRoll: 38.4, beltsPerRoll: 6);
      expect(got.totalBelts, 23);
      expect(got.rolls, 3);
      expect(got.looseBelts, 5);
      expect(got.rolls! * 6 + got.looseBelts!, got.totalBelts);
    });

    test('survives binary floating point at an exact roll boundary', () {
      // 34.0 / 1.7 is 19.999999999999996; a naive floor loses a whole roll.
      final got = stockFromKg(kg: 34.0, weightPerRoll: 34.0, beltsPerRoll: 20);
      expect(got.totalBelts, 20);
      expect(got.rolls, 1);
      expect(got.looseBelts, 0);
    });
  });

  group('weight per belt, when the master left it at zero', () {
    test('derives it from the roll, exactly, for the real imported values', () {
      expect(weightPerBelt(weightPerRoll: 38.4, beltsPerRoll: 6), 6.4);
      expect(weightPerBelt(weightPerRoll: 35.0, beltsPerRoll: 14), 2.5);
      expect(weightPerBelt(weightPerRoll: 34.0, beltsPerRoll: 20), 1.7);
    });

    test('a stored value wins over the derivation', () {
      expect(
          weightPerBelt(
              storedWeightPerBelt: 6.5, weightPerRoll: 38.4, beltsPerRoll: 6),
          6.5);
    });

    test('is null rather than zero when it cannot be derived', () {
      expect(weightPerBelt(weightPerRoll: 0, beltsPerRoll: 6), isNull);
      expect(weightPerBelt(weightPerRoll: 38.4, beltsPerRoll: 0), isNull);
    });
  });
}
