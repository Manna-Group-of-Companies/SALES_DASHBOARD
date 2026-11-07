// One trip at a time.
//
// A rep's day is one trip: it holds the odometer, the recorded route, and every
// visit punched while it runs. Two at once and the newest silently takes all of
// it while the older one records nothing and never closes — which is how a trip
// from 2026-08-28 was still showing "Active · recording" on 2026-09-07.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/trip_rules.dart';

void main() {
  group('nothing running', () {
    test('a trip can be started', () {
      expect(tripStartRefusal(const []), isNull);
    });
  });

  group('one trip still running', () {
    test('refuses, and says which trip is in the way', () {
      final r = tripStartRefusal(const [
        RunningTrip(
            name: 'TRIP-2026-00042',
            date: '2026-08-28',
            purpose: 'customer visit'),
      ]);
      expect(r, isNotNull);
      expect(r, contains('2026-08-28'));
      expect(r, isNot(contains('TRIP-')));
      expect(r, contains('End it first'));
    });

    test('still names the trip when the rep skipped the purpose', () {
      // Most reps do skip it — the Trips list is full of rows that are just a
      // date. A refusal that leans on the purpose would name nothing at all.
      final r = tripStartRefusal(
          const [RunningTrip(name: 'TRIP-2026-00042', date: '2026-09-01')]);
      expect(r, contains('2026-09-01'));
      expect(r, isNot(contains('TRIP-')));
    });
  });

  group('more than one still running', () {
    // Trips started before this rule existed are still open on the record, so
    // a rep can genuinely have two in the way.
    final two = const [
      RunningTrip(
          name: 'TRIP-2026-00042',
          date: '2026-08-28',
          purpose: 'customer visit'),
      RunningTrip(
          name: 'TRIP-2026-00051',
          date: '2026-09-07',
          purpose: 'customer visit'),
    ];

    test('names both, so ending one does not just move the refusal', () {
      final r = tripStartRefusal(two);
      expect(r, contains('2026-08-28'));
      expect(r, contains('2026-09-07'));
      expect(r, isNot(contains('TRIP-')));
    });

    test('asks for them to be ended first', () {
      expect(tripStartRefusal(two), contains('End them first'));
    });

    test('lists a few and counts the rest rather than filling the screen', () {
      final many = [
        for (var i = 1; i <= 5; i++)
          RunningTrip(name: 'TRIP-2026-0004$i', date: '2026-09-0$i'),
      ];
      final r = tripStartRefusal(many)!;
      expect(r, contains('5 trips'));
      expect(r, contains('2 more'));
      // The last two are counted, not spelled out.
      expect(r, isNot(contains('2026-09-05')));
    });
  });

  group('how a trip is named back to the rep', () {
    test('reads like the Trips list: date, then purpose', () {
      expect(
          describeRunningTrip(const RunningTrip(
              name: 'TRIP-2026-00042',
              date: '2026-08-28',
              purpose: 'customer visit')),
          '2026-08-28 · customer visit');
    });

    test('never shows the ERPNext name (7 Nov 2026)', () {
      final a = describeRunningTrip(
          const RunningTrip(name: 'TRIP-2026-00042', date: '2026-08-28'));
      expect(a, isNot(contains('TRIP-')));
    });

    test('says "in progress" when the trip has neither date nor purpose', () {
      expect(describeRunningTrip(const RunningTrip(name: 'TRIP-2026-00042')),
          'in progress');
    });
  });
}
