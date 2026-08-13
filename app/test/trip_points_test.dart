// Route points queued on the phone.
//
// The property that matters is that a point, once taken, cannot be lost by
// anything short of the phone itself. Points used to go straight to the server
// and a failed send dropped them silently — which is why a day's driving came
// back as three points.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/services/trip_points.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a point survives being written down', () {
    test('adding one queues it', () async {
      await TripPoints.add(
          const TripPoint('TRP-1', 9.5916, 76.5222, '2026-08-10 09:00:00'));
      expect(await TripPoints.count(), 1);
    });

    test('points accumulate while there is no network', () async {
      for (var i = 0; i < 12; i++) {
        await TripPoints.add(
            TripPoint('TRP-1', 9.59 + i / 1000, 76.52, '2026-08-10 09:$i:00'));
      }
      expect(await TripPoints.count(), 12);
    });

    test('points from different trips queue together', () async {
      await TripPoints.add(
          const TripPoint('TRP-1', 9.59, 76.52, '2026-08-10 09:00:00'));
      await TripPoints.add(
          const TripPoint('TRP-2', 10.1, 76.4, '2026-08-10 09:05:00'));
      expect(await TripPoints.count(), 2);
    });
  });

  group('a point keeps the time it was taken', () {
    test('the stamp survives the round trip', () {
      const p = TripPoint('TRP-1', 9.5916, 76.5222, '2026-08-10 09:00:00');
      final back = TripPoint.fromJson(p.toJson());
      expect(back, isNotNull);
      expect(back!.at, '2026-08-10 09:00:00');
      expect(back.lat, 9.5916);
      expect(back.lng, 76.5222);
      expect(back.trip, 'TRP-1');
    });

    test('a point sent late still describes where the rep was', () {
      // Stamping on arrival would draw the route through wherever the rep
      // regained signal rather than where they had actually been.
      const morning = TripPoint('TRP-1', 9.59, 76.52, '2026-08-10 09:00:00');
      expect(TripPoint.fromJson(morning.toJson())!.at, '2026-08-10 09:00:00');
    });
  });

  group('rubbish does not jam the queue', () {
    test('a row with no trip is refused', () {
      expect(
          TripPoint.fromJson({'lat': 9.5, 'lng': 76.5, 'at': 'x'}), isNull);
    });

    test('a row with no coordinates is refused', () {
      expect(TripPoint.fromJson({'trip': 'TRP-1', 'at': 'x'}), isNull);
    });

    test('integer coordinates are accepted', () {
      // JSON round-trips whole numbers as int, and refusing those would drop
      // every point taken on an exact degree.
      final p = TripPoint.fromJson({'trip': 'T', 'lat': 9, 'lng': 76, 'at': 'x'});
      expect(p, isNotNull);
      expect(p!.lat, 9.0);
    });
  });

  group('the queue is bounded', () {
    test('a runaway queue keeps the most recent points', () async {
      // A day of five-minute points is under 300. This only matters if a
      // tracker is left running for weeks with no signal at all.
      for (var i = 0; i < 2100; i++) {
        await TripPoints.add(
            TripPoint('TRP-1', 9.0 + i / 10000, 76.0, 'stamp-$i'));
      }
      final n = await TripPoints.count();
      expect(n, lessThanOrEqualTo(2000));
      expect(n, greaterThan(1900),
          reason: 'it should trim, not empty itself');
    });
  });
}
