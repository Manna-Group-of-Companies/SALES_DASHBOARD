// How much of an order line remains to be dispatched.
//
// Checked against `shared/fixtures/dispatch.json`, the same file
// `client/src/domain/__tests__/dispatch.test.ts` reads.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/dispatch.dart';

Map<String, dynamic> _fixture() {
  // Relative to `app/`, which is where `flutter test` runs from.
  final f = File('../shared/fixtures/dispatch.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _fixture();

  group('shared fixture: remaining to dispatch', () {
    for (final raw in fx['remaining'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final line = (c['line'] as Map).cast<String, dynamic>();
        final expect_ = (c['expect'] as Map).cast<String, dynamic>();
        final left = remainingToDispatch(line);
        expect(left.rolls, expect_['rolls']);
        expect(left.looseBelts, expect_['loose_belts']);
      });
    }
  });

  group('shared fixture: fully dispatched', () {
    for (final raw in fx['fully_dispatched'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final line = (c['line'] as Map).cast<String, dynamic>();
        expect(isFullyDispatched(line), c['expect']);
      });
    }
  });
}
