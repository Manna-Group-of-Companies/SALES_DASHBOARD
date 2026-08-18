// Shared trips: whether one counts as being with the manager, and whose money
// each expense was.
//
// Checked against `shared/fixtures/trip_sharing.json`, the same file the
// dashboard's `client/src/domain/__tests__/tripSharing.test.ts` reads. One rep
// raises a trip and tags the colleagues who came along, so "whose expense is
// this" has to be answered identically on a phone and on the web — or two
// sheets disagree about what somebody spent.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/expenses.dart';

Map<String, dynamic> _fixture() =>
    json.decode(File('../shared/fixtures/trip_sharing.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _trip(Map t) => {
      'sales_person': t['sales_person'],
      'tagged_csv': (t['tagged'] as List).isEmpty
          ? ''
          : '|${(t['tagged'] as List).join('|')}|',
    };

List<Map<String, dynamic>> _rows(dynamic v) =>
    (v as List).map((e) => (e as Map).cast<String, dynamic>()).toList();

void main() {
  final fx = _fixture();

  group('shared fixture: the field names', () {
    test('reads the field the fixture names', () {
      expect(kExpenseOwnerField, (fx['fields'] as Map)['expense_owner']);
    });
  });

  group('shared fixture: a trip with the manager', () {
    for (final raw in fx['with_manager'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        expect(
            travelledWithManager(_trip(c['trip'] as Map),
                c['person'] as String, c['manager_name'] as String),
            c['expect']);
      });
    }
  });

  group('shared fixture: whose expense is it', () {
    for (final raw in fx['expenses'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      final e = (c['expense'] as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final exp = (c['expect'] as Map).cast<String, dynamic>();
        expect(expenseOwner(e), exp['owner']);
        expect(isCommonExpense(e), exp['common']);
      });
    }
  });

  group('shared fixture: splitting a trip', () {
    for (final raw in fx['totals'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final split = splitExpenses(_rows(c['expenses']));
        final e = (c['expect'] as Map).cast<String, dynamic>();
        if (e['common'] != null) {
          expect(split.common, closeTo((e['common'] as num).toDouble(), 0.01));
        }
        if (e['trip_total'] != null) {
          expect(split.total, closeTo((e['trip_total'] as num).toDouble(), 0.01));
        }
        final own = (e['own'] as Map?)?.cast<String, dynamic>() ?? {};
        own.forEach((person, amount) {
          expect(split.own[person] ?? 0,
              closeTo((amount as num).toDouble(), 0.01),
              reason: person);
        });
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('the bug that made the column read zero', () {
    test('counted nothing while the trips were sitting right there', () {
      // Live on 18 Aug 2026: TRP-00258 and TRP-00301 both carried
      // `|Pareeth Kb|`, and the caller compared the TOKEN `Pareeth`.
      final trip = _trip({'sales_person': 'Jaimon D', 'tagged': ['Pareeth Kb']});
      expect(travelledWithManager(trip, 'Jaimon D', 'Pareeth'), isFalse);
      expect(travelledWithManager(trip, 'Jaimon D', 'Pareeth Kb'), isTrue);
    });
  });

  group('the common pot is reported, not divided', () {
    test('is left whole rather than split between the travellers', () {
      final split = splitExpenses([
        {'amount': 900}
      ]);
      expect(split.common, 900);
      expect(split.own, isEmpty);
      expect(
          personalExpense([
            {'amount': 900}
          ], 'Jaimon D'),
          0);
    });
  });

  group('money never appears from nowhere', () {
    test('always totals to the sum of the rows', () {
      final s = splitExpenses([
        {'custom_for_person': 'A', 'amount': 10.5},
        {'custom_for_person': 'B', 'amount': 20.25},
        {'amount': 5.25},
        {'custom_for_person': '', 'amount': 4},
      ]);
      final own = s.own.values.fold<double>(0, (t, n) => t + n);
      expect(own + s.common, closeTo(s.total, 0.01));
      expect(s.total, closeTo(40, 0.01));
    });

    test('treats a missing or rubbish amount as nothing, not NaN', () {
      final s = splitExpenses([
        {'custom_for_person': 'A'},
        {'amount': 'x'}
      ]);
      expect(s.total, 0);
      expect(s.common.isNaN, isFalse);
    });
  });

  group('parseTagged', () {
    test('reads the pipe-wrapped form the app writes', () {
      expect(parseTagged('|A|B|'), ['A', 'B']);
      expect(parseTagged('|Pareeth Kb|'), ['Pareeth Kb']);
      expect(parseTagged(''), isEmpty);
      expect(parseTagged(null), isEmpty);
    });
  });
}
