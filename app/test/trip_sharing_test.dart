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

  _writeBack();
  _whoMayKey();

  group('parseTagged', () {
    test('reads the pipe-wrapped form the app writes', () {
      expect(parseTagged('|A|B|'), ['A', 'B']);
      expect(parseTagged('|Pareeth Kb|'), ['Pareeth Kb']);
      expect(parseTagged(''), isEmpty);
      expect(parseTagged(null), isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------

// Phone-only: the dashboard is HR's and never keys a rep's expense, so this is
// not in the shared fixture.
void _whoMayKey() {
  group('who may key an expense on a shared trip', () {
    TripExpenseRole role(String? me) => tripExpenseRole(
        owner: 'Jaimon D', tagged: const ['Pareeth Kb'], me: me);

    test('a rep tagged on a trip can add their own expenses', () {
      // TRP-01108: Jaimon's colleague rode along, paid for things, and the
      // trip was view-only to them — there was no way to claim it.
      expect(role('Pareeth Kb'), TripExpenseRole.tagged);
      expect(canAddTripExpense(role('Pareeth Kb')), isTrue);
    });

    test('the owner still can', () {
      expect(role('Jaimon D'), TripExpenseRole.owner);
      expect(canAddTripExpense(role('Jaimon D')), isTrue);
    });

    test('somebody not on the trip cannot, nor a login with no sales person',
        () {
      expect(canAddTripExpense(role('Amjad Pr')), isFalse);
      expect(canAddTripExpense(role(null)), isFalse);
      expect(canAddTripExpense(role('')), isFalse);
      expect(canAddTripExpense(role('null')), isFalse);
    });

    test('a tagged rep can only put an expense against themselves', () {
      // Or common. Never on the owner's sheet, or another passenger's.
      expect(
          expenseOwnerChoices(TripExpenseRole.tagged,
              ['Jaimon D', 'Pareeth Kb', 'Amjad Pr'], 'Pareeth Kb'),
          ['Pareeth Kb']);
      expect(
          expenseOwnerChoices(TripExpenseRole.owner,
              ['Jaimon D', 'Pareeth Kb'], 'Jaimon D'),
          ['Jaimon D', 'Pareeth Kb']);
    });

    test('a tagged rep changes only the rows tagged to them', () {
      final mine = {'name': 'r1', kExpenseOwnerField: 'Pareeth Kb'};
      final owners = {'name': 'r2', kExpenseOwnerField: 'Jaimon D'};
      final common = {'name': 'r3'};
      final t = TripExpenseRole.tagged;
      expect(canChangeTripExpense(t, mine, 'Pareeth Kb'), isTrue);
      expect(canChangeTripExpense(t, owners, 'Pareeth Kb'), isFalse);
      // A common row is the journey's — a passenger deleting the toll would
      // take it off the driver's claim.
      expect(canChangeTripExpense(t, common, 'Pareeth Kb'), isFalse);
    });

    test('the owner changes any row, and an outsider none', () {
      final common = {'name': 'r3'};
      expect(canChangeTripExpense(TripExpenseRole.owner, common, 'Jaimon D'),
          isTrue);
      expect(
          canChangeTripExpense(TripExpenseRole.none,
              {kExpenseOwnerField: 'Amjad Pr'}, 'Amjad Pr'),
          isFalse);
    });
  });
}

void _writeBack() {
  group('writing a trip expense back', () {
    test('keeps the person it is tagged to', () {
      // The bug this exists for: the writer rebuilt each row from a fixed list
      // of keys, `custom_for_person` was not on it, and every tag was stripped
      // on the way to the server. The expense saved fine and read back common.
      final row = tripExpenseRow({
        'category': 'Food',
        'amount': 250,
        kExpenseOwnerField: 'Pareeth Kb',
      });
      expect(row[kExpenseOwnerField], 'Pareeth Kb');
    });

    test('sends the field even when common, so a tag can be cleared', () {
      // Omitting the key leaves the previous owner in place. Null is what
      // takes an expense back to common.
      final row = tripExpenseRow({'category': 'Toll', 'amount': 80});
      expect(row.containsKey(kExpenseOwnerField), isTrue);
      expect(row[kExpenseOwnerField], isNull);
    });

    test('does not lose a tag on a row the user never touched', () {
      /*
       * Frappe replaces a child table wholesale, so adding ONE expense
       * rewrites all of them. A field missing from the writer is deleted from
       * every existing row too - which is why this was worse than it looked.
       */
      final existing = [
        {'name': 'row1', 'category': 'Food', 'amount': 250, kExpenseOwnerField: 'Jaimon D'},
        {'name': 'row2', 'category': 'Toll', 'amount': 80},
      ];
      final written = existing.map(tripExpenseRow).toList();
      expect(written[0][kExpenseOwnerField], 'Jaimon D');
      expect(written[0]['name'], 'row1');
      expect(written[1][kExpenseOwnerField], isNull);
    });

    test('carries every field the row is read back by', () {
      // If a field is added to Trip Expense and not to the writer, it is lost
      // on the next save. This lists what the app relies on.
      final row = tripExpenseRow({'category': 'Fuel', 'amount': 100});
      for (final k in [
        'category',
        'expense_name',
        'amount',
        kExpenseOwnerField,
        'has_bill',
        'bill_photo',
        'status',
        'custom_approved_amount',
        'custom_approval_remarks',
        'remarks',
      ]) {
        expect(row.containsKey(k), isTrue, reason: 'missing $k');
      }
    });
  });
}
