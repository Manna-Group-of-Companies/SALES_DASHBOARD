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

  group('a trip left running from an earlier day', () {
    // 24 Nov 2026: Nikhil Tk's trip of 14 Nov ran until the 16th and his trip
    // of 11 Nov until the 19th. The visits of the 16th and the 18th went onto
    // those old trips, and the Trips list showed no trip on either day.
    const today = '2026-11-16';

    test('says nothing when the only running trip is today\'s', () {
      const running = [RunningTrip(name: 'TRP-01080', date: today)];
      expect(tripsLeftOpen(running, today), isEmpty);
      expect(tripLeftOpenWarning(running, today), isNull);
    });

    test('says nothing when no trip is running', () {
      expect(tripLeftOpenWarning(const [], today), isNull);
    });

    test('warns about a trip from yesterday or before, and names its day', () {
      const running = [RunningTrip(name: 'TRP-01072', date: '2026-11-14')];
      final w = tripLeftOpenWarning(running, today)!;
      expect(w, contains('2026-11-14'));
      expect(w, contains('End it'));
      expect(w, isNot(contains('TRP-')));
    });

    test('names every old trip, oldest first, so one End does not hide another',
        () {
      const running = [
        RunningTrip(name: 'TRP-01072', date: '2026-11-14'),
        RunningTrip(name: 'TRP-01041', date: '2026-11-11'),
      ];
      expect(tripsLeftOpen(running, today).map((t) => t.name),
          ['TRP-01041', 'TRP-01072']);
      final w = tripLeftOpenWarning(running, today)!;
      expect(w, contains('2 trips'));
      expect(w.indexOf('2026-11-11'), lessThan(w.indexOf('2026-11-14')));
    });

    test('leaves today\'s trip out of the warning when an old one is open too',
        () {
      const running = [
        RunningTrip(name: 'TRP-01080', date: today),
        RunningTrip(name: 'TRP-01072', date: '2026-11-14'),
      ];
      expect(tripsLeftOpen(running, today).map((t) => t.name), ['TRP-01072']);
    });

    test('a trip with no date is not warned about — there is no day to name',
        () {
      const running = [RunningTrip(name: 'TRP-01000')];
      expect(tripLeftOpenWarning(running, today), isNull);
    });
  });

  group('punching out with a trip still running', () {
    // 24 Nov 2026, the user: one trip at a time, and the trip is ended before
    // the rep punches out. Nikhil Tk punched out every evening from 11 to 19
    // Nov with his 11 Nov trip still running.

    test('a rep with no trip running may punch out', () {
      expect(punchOutRefusal(const []), isNull);
    });

    test('today\'s running trip stops the punch-out, and the trip is named', () {
      final r = punchOutRefusal(const [
        RunningTrip(name: 'TRP-01138', date: '2026-11-24'),
      ]);
      expect(r, isNotNull);
      expect(r, contains('2026-11-24'));
      expect(r, contains('End the trip first'));
      expect(r, isNot(contains('TRP-')));
    });

    test('a trip left running from an earlier day stops it too', () {
      final r = punchOutRefusal(const [
        RunningTrip(name: 'TRP-01041', date: '2026-11-11'),
      ]);
      expect(r, contains('2026-11-11'));
    });

    test('names every running trip, so ending one does not just move the '
        'refusal', () {
      final r = punchOutRefusal(const [
        RunningTrip(name: 'TRP-01072', date: '2026-11-14'),
        RunningTrip(name: 'TRP-01041', date: '2026-11-11'),
      ])!;
      expect(r, contains('2 of your trips'));
      expect(r, contains('2026-11-14'));
      expect(r, contains('2026-11-11'));
      expect(r, contains('End them first'));
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
