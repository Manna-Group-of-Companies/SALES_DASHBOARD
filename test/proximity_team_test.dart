// The duplicate check is scoped to one business unit.
//
// Manna Treads and Manna Tyre Retreads sell different things to the same trade,
// so one tyre shop is legitimately a customer of both. Each unit's rep must be
// able to put that shop on their own list without the other unit's record
// standing in the way. The duplicate worth stopping is two reps on the *same*
// team claiming one shop.
//
// The arithmetic itself is covered in proximity_test.dart. What is pinned here
// is the filtering: who counts as a clash and who does not.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proximity.dart';

const kLat = 9.5916;
const kLng = 76.5222;

/// A record 200 m away, owned by [rep].
NearbyPlace near(String name, String rep, {String kind = 'Lead'}) => NearbyPlace(
      name: name,
      label: name,
      kind: kind,
      owner: rep,
      metres: metresBetween(kLat, kLng, kLat + 0.0018, kLng),
    );

/// Stands in for the server-side filter: only records owned by **another** rep
/// in the caller's unit are ever fetched.
List<NearbyPlace> visibleTo(
        List<NearbyPlace> all, Map<String, String> unitOf, String myUnit,
        {String me = ''}) =>
    all.where((p) => unitOf[p.owner] == myUnit && p.owner != me).toList();

void main() {
  const units = {
    'Jaimon D': 'Manna Treads',
    'Pareeth Kb': 'Manna Treads',
    'Amjad Pr': 'Manna Treads',
    'Subhash': 'Manna Tyre Retreads',
    'Prasad V': 'Manna Tyre Retreads',
    'Kailas Babu': 'Manna Tyres UAE',
  };

  final all = [
    near('LEAD-TREADS', 'Jaimon D'),
    near('CUST-RETREADS', 'Subhash', kind: 'Customer'),
    near('LEAD-UAE', 'Kailas Babu'),
  ];

  group('one shop, two units', () {
    test('a Treads rep is blocked only by Treads records', () {
      final seen = visibleTo(all, units, 'Manna Treads');
      expect(seen.map((p) => p.name), ['LEAD-TREADS']);
    });

    test('a Retreads rep is blocked only by Retreads records', () {
      final seen = visibleTo(all, units, 'Manna Tyre Retreads');
      expect(seen.map((p) => p.name), ['CUST-RETREADS']);
    });

    test('the same shop can be on both units at once', () {
      // The bug: a Retreads customer at this spot stopped a Treads rep from
      // raising their own lead for it, though the two sell different products
      // and neither is a duplicate of the other.
      final treads = visibleTo(all, units, 'Manna Treads');
      final retreads = visibleTo(all, units, 'Manna Tyre Retreads');
      expect(treads.any((p) => p.name == 'CUST-RETREADS'), isFalse);
      expect(retreads.any((p) => p.name == 'LEAD-TREADS'), isFalse);
    });
  });

  group('within one unit', () {
    test('a teammate\'s record blocks', () {
      final all = [near('LEAD-MATE', 'Pareeth Kb')];
      expect(visibleTo(all, units, 'Manna Treads', me: 'Jaimon D'),
          hasLength(1));
    });

    test('every other rep of the unit counts, not just one', () {
      final all = [near('A', 'Pareeth Kb'), near('B', 'Amjad Pr')];
      expect(visibleTo(all, units, 'Manna Treads', me: 'Jaimon D'),
          hasLength(2));
    });
  });

  group('a rep is never blocked by their own work', () {
    test('my own lead next door does not stop me raising another', () {
      // A rep who has put one shop on the map and walks next door is doing
      // their job. If the two really are the same place, they are the one
      // person who can see that.
      final all = [near('MY-LEAD', 'Jaimon D')];
      expect(visibleTo(all, units, 'Manna Treads', me: 'Jaimon D'), isEmpty);
    });

    test('my own record is skipped but a teammate\'s beside it is not', () {
      final all = [near('MINE', 'Jaimon D'), near('THEIRS', 'Pareeth Kb')];
      final seen = visibleTo(all, units, 'Manna Treads', me: 'Jaimon D');
      expect(seen.map((p) => p.name), ['THEIRS']);
    });

    test('the only rep on a unit can never be blocked', () {
      final solo = {'Solo Rep': 'Manna Solo'};
      final all = [near('MINE-1', 'Solo Rep'), near('MINE-2', 'Solo Rep')];
      expect(visibleTo(all, solo, 'Manna Solo', me: 'Solo Rep'), isEmpty);
    });
  });

  group('records with no unit', () {
    test('a record whose rep has no unit blocks nobody', () {
      // It belongs to no team, so there is no team for it to be a duplicate
      // within.
      final all = [near('ORPHAN', 'Nobody')];
      for (final u in ['Manna Treads', 'Manna Tyre Retreads']) {
        expect(visibleTo(all, units, u), isEmpty, reason: u);
      }
    });

    test('a caller with no unit sees nothing rather than everything', () {
      // Blocking on every record in the country would stop a rep working over
      // a clash with a team they are not on.
      expect(visibleTo(all, units, ''), isEmpty);
    });
  });

  test('the radius is unchanged by any of this', () {
    expect(kDuplicateRadiusMetres, 1000);
  });
}
