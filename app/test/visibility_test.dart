// Which customers, leads and routes a rep may see.
//
// Checked against `shared/fixtures/visibility.json`, the same file the
// dashboard's `client/src/domain/__tests__/visibility.test.ts` reads. This one
// decides whether one unit's customers can be seen by another, so it is exactly
// the rule that must not differ between the phone and the dashboard.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/visibility.dart';

Map<String, dynamic> _fixture() {
  final f = File('../shared/fixtures/visibility.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _fixture();

  final people = (fx['people'] as List)
      .map((e) => VisPerson.fromRow((e as Map).cast<String, dynamic>()))
      .toList();

  group('shared fixture: the field names and the pooled units', () {
    test('reads the fields the fixture names', () {
      final f = (fx['fields'] as Map).cast<String, dynamic>();
      expect(kFieldUnit, f['unit']);
      expect(kFieldCustomerOwner, f['customer_owner']);
      expect(kFieldLeadOwner, f['lead_owner']);
      expect(kFieldRouteOwner, f['route_owner']);
    });

    test('pools exactly the units the fixture pools', () {
      expect(kPooledUnits, fx['pooled_units']);
    });
  });

  group('shared fixture: which units are pooled', () {
    for (final raw in fx['pooled'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        expect(isPooledUnit(c['unit'] as String?), c['expect']);
      });
    }
  });

  group('shared fixture: who sees whose records', () {
    for (final raw in fx['visible'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final got = visibleReps(people, c['person'] as String?)..sort();
        if (c['expect'] != null) {
          final want = (c['expect'] as List).map((e) => '$e').toList()..sort();
          expect(got, want);
        }
        for (final x in (c['expect_excludes'] as List? ?? const [])) {
          expect(got, isNot(contains('$x')));
        }
      });
    }
  });

  group('shared fixture: what an unassigned record needs to be seen', () {
    for (final raw in fx['owner_values'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        final got = visibleOwnerValues(people, c['person'] as String?)..sort();
        final want = (c['expect'] as List).map((e) => '$e').toList()..sort();
        expect(got, want);
      });
    }
  });

  group('shared fixture: who may assign an owner', () {
    for (final raw in fx['can_assign'] as List) {
      final c = (raw as Map).cast<String, dynamic>();
      test(c['why'] as String, () {
        expect(canAssignOwner(people, c['person'] as String?), c['expect']);
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('pooling never leaks across units', () {
    test('shows a UAE rep no Indian customers, and vice versa', () {
      final uae = visibleReps(people, 'Kailas Babu');
      for (final other in ['Amjad Pr', 'Sirajudheen Kasim', 'Prasad V']) {
        expect(uae, isNot(contains(other)));
      }
      expect(visibleReps(people, 'Amjad Pr'), ['Amjad Pr']);
    });

    test('never returns the whole company for anybody', () {
      for (final p in people) {
        expect(visibleReps(people, p.name).length, lessThan(people.length));
      }
    });
  });

  group('it fails closed', () {
    test('gives an unresolvable login nothing rather than everything', () {
      expect(visibleReps(people, null), isEmpty);
      expect(visibleReps(people, 'nobody@nowhere'), isEmpty);
      expect(visibleReps(const [], 'Kailas Babu'), isEmpty);
    });

    test('does not read a missing unit as membership of the pool', () {
      final orphan = [
        ...people,
        const VisPerson(name: 'No Unit', unit: ''),
      ];
      expect(visibleReps(orphan, 'No Unit'), ['No Unit']);
    });

    test('leaves a disabled person with nothing, rather than their old team',
        () {
      expect(visibleReps(people, 'Ex UAE Rep'), isEmpty);
    });
  });

  group('who is covering for whom', () {
    test('knows a UAE rep is looking at a colleague\'s customer', () {
      expect(isCoveringFor(people, 'Kailas Babu', 'Manikandan'), isTrue);
    });

    test('does not call a rep\'s own customer a cover', () {
      expect(isCoveringFor(people, 'Kailas Babu', 'Kailas Babu'), isFalse);
      expect(isCoveringFor(people, 'Kailas Babu', null), isFalse);
    });

    test('is never true outside a pooled unit, because nothing is shared', () {
      expect(isCoveringFor(people, 'Amjad Pr', 'Sirajudheen Kasim'), isFalse);
    });

    test('says a UAE rep shares and an Indian rep does not', () {
      expect(sharesWithUnit(people, 'Renjith'), isTrue);
      expect(sharesWithUnit(people, 'Amjad Pr'), isFalse);
      expect(sharesWithUnit(people, 'nobody'), isFalse);
    });
  });
}
