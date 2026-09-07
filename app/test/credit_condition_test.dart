// The credit condition state machine, read from the shared fixture the
// dashboard's suite reads too.
//
// The one rule that matters here is that a rep cannot close their own
// obligation. It is worth nothing if either app forgets it, and there is no
// Server Script on this site to catch the one that does — so both are held to
// the same cases.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/credit_condition.dart';

void main() {
  final raw = File('../shared/fixtures/credit_condition.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;

  CondAction actionOf(String s) => switch (s) {
        'respond' => CondAction.respond,
        'close' => CondAction.close,
        'reopen' => CondAction.reopen,
        _ => throw ArgumentError('unknown action $s'),
      };

  group('who may move a condition', () {
    for (final c in (fixture['transitions'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final got = nextConditionStatus(
          status: c['from'] as String,
          action: actionOf(c['action'] as String),
          actor: c['actor'] as String,
        );
        if (c['expect'] == 'REFUSED') {
          expect(got, isNull);
        } else {
          expect(got, c['expect']);
        }
      });
    }
  });

  group('when a condition is overdue', () {
    for (final c in (fixture['overdue'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        expect(
          conditionOverdue(
            status: c['status'] as String,
            dueDateIso: c['due'] as String,
            today: DateTime.parse('${c['today']} 09:00:00'),
          ),
          c['expect'],
        );
      });
    }
  });

  group('the rule the whole feature exists for', () {
    test('nobody but the GM can close, whatever role they claim', () {
      for (final actor in ['rep', 'sales_manager', 'production_manager', 'hr', '']) {
        expect(
          canMoveCondition(
              status: kCondAwaiting, action: CondAction.close, actor: actor),
          isFalse,
          reason: 'actor=$actor',
        );
      }
      expect(
        canMoveCondition(
            status: kCondAwaiting, action: CondAction.close, actor: 'gm'),
        isTrue,
      );
    });

    test('a rep answering does not close it', () {
      expect(
        nextConditionStatus(
            status: kCondOpen, action: CondAction.respond, actor: 'rep'),
        kCondAwaiting,
      );
    });
  });
}
