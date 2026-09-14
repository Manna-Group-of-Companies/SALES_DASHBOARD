// Where a place's location may be moved to, and by whom.
//
// Checked against `shared/fixtures/capture.json`, the same file the
// dashboard's `client/src/domain/__tests__/capture.test.ts` reads. The verified
// pair is what every punch-in measures against, and a capture that writes it
// directly has nobody checking it — so the two apps must agree exactly on when
// one is allowed, or the dashboard goes on creating the pins the phone refuses.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/capture_rules.dart';
import 'package:manna_field_sales/core/proximity.dart';

Map<String, dynamic> _fixture() =>
    json.decode(File('../shared/fixtures/capture.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final fixture = _fixture();
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('the fixture has cases to run', () {
    expect(cases, isNotEmpty);
  });

  test('the limit both apps enforce is the punch-in radius', () {
    // Stated in the fixture as well as in the code so a change on one side
    // fails the other side's build rather than passing quietly.
    expect(kMaxSelfVerifiedMoveMetres, (fixture['limit_metres'] as num).toDouble());
    expect(kMaxSelfVerifiedMoveMetres, kPunchInRadiusMetres);
  });

  group('shared/fixtures/capture.json', () {
    for (final c in cases) {
      final existing = c['existing'] as Map<String, dynamic>?;
      final captured = c['captured'] as Map<String, dynamic>;

      test(c['why'] as String, () {
        final verdict = checkCapture(
          selfVerifying: c['self_verifying'] as bool,
          lat: (captured['lat'] as num).toDouble(),
          lng: (captured['lng'] as num).toDouble(),
          existingLat: existing == null
              ? null
              : (existing['lat'] as num).toDouble(),
          existingLng: existing == null
              ? null
              : (existing['lng'] as num).toDouble(),
        );
        expect(verdict.allowed, c['expect_allowed'] as bool);
      });
    }
  });

  group('what the person refused is told', () {
    test('the message names the distance, not just the refusal', () {
      final v = checkCapture(
        selfVerifying: true,
        lat: 9.19733,
        lng: 76.5344,
        existingLat: 9.0544,
        existingLng: 76.5344,
      );
      expect(v.allowed, isFalse);
      expect(v.message, contains('km away'));
      // The one thing the person at a desk can actually do about it.
      expect(v.message, contains('rep'));
    });
  });
}
