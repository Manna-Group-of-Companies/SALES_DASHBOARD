// Route points held on the phone until there is a network to send them on.
//
// Points used to go straight to the server, and a point that failed to send was
// simply gone. A rep driving through a valley with no signal recorded nothing
// for that stretch, and the route came back looking like three points for a
// day's driving — which is what reps were seeing.
//
// Worse, the throttle was advanced *before* the upload was attempted, so a
// failed send also blocked the next attempt for five minutes. A patchy signal
// did not degrade the route, it emptied it.
//
// So every point is written to the phone first, which cannot fail for want of
// a network, and the queue is drained whenever a send succeeds. The phone is
// the record; the server is a copy of it.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/services/api.dart';

/// One recorded position, with the moment it was actually taken.
///
/// The timestamp is captured here rather than at upload. A point sent two
/// hours late describes where the rep was two hours ago, and stamping it on
/// arrival would draw the route through places they had already left.
class TripPoint {
  final String trip;
  final double lat;
  final double lng;

  /// `yyyy-MM-dd HH:mm:ss`, from the phone at the moment of the fix.
  final String at;

  const TripPoint(this.trip, this.lat, this.lng, this.at);

  Map<String, dynamic> toJson() =>
      {'trip': trip, 'lat': lat, 'lng': lng, 'at': at};

  static TripPoint? fromJson(Map<String, dynamic> j) {
    final trip = '${j['trip'] ?? ''}';
    if (trip.isEmpty) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return TripPoint(trip, lat, lng, '${j['at'] ?? ''}');
  }
}

class TripPoints {
  static const _key = 'tripGpsQueue';

  /// A day of five-minute points is under 300. This is a long way above any
  /// honest day, and exists only so a tracker left running for a week on a
  /// phone that never sees signal cannot fill the device.
  static const int _maxQueued = 2000;

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  /// Records a point. Never throws — losing a point to a failed write would be
  /// the very thing this exists to prevent.
  static Future<void> add(TripPoint p) async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getStringList(_key) ?? <String>[];
      raw.add(jsonEncode(p.toJson()));
      // Oldest go first if it ever comes to that: the recent part of a route
      // is the part somebody is still going to ask about.
      if (raw.length > _maxQueued) {
        raw.removeRange(0, raw.length - _maxQueued);
      }
      await prefs.setStringList(_key, raw);
    } catch (_) {}
  }

  static Future<int> count() async {
    try {
      return (await _prefs).getStringList(_key)?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Sends everything queued, oldest first, and returns how many got through.
  ///
  /// Stops at the first failure and keeps the rest. Carrying on would spend a
  /// dead network on every point in the queue, and the order matters — a route
  /// drawn out of sequence is worse than one that is simply short.
  ///
  /// Points are grouped per trip so a day's backlog is one write per trip
  /// rather than one per point: [Api.appendTripGpsPoints] re-reads the trip and
  /// appends the lot.
  static Future<int> flush() async {
    List<String> raw;
    try {
      raw = (await _prefs).getStringList(_key) ?? <String>[];
    } catch (_) {
      return 0;
    }
    if (raw.isEmpty) return 0;

    final points = <TripPoint>[];
    for (final s in raw) {
      try {
        final p = TripPoint.fromJson(
            (jsonDecode(s) as Map).cast<String, dynamic>());
        if (p != null) points.add(p);
      } catch (_) {
        // A row that will not decode can never be sent. Dropping it is the
        // only way the queue ever empties.
      }
    }
    if (points.isEmpty) {
      await _clear();
      return 0;
    }

    // Grouped in the order the trips first appear, so the oldest trip's
    // backlog goes first.
    final byTrip = <String, List<TripPoint>>{};
    for (final p in points) {
      byTrip.putIfAbsent(p.trip, () => []).add(p);
    }

    var sent = 0;
    final remaining = <TripPoint>[];
    var failed = false;
    for (final entry in byTrip.entries) {
      if (failed) {
        remaining.addAll(entry.value);
        continue;
      }
      try {
        await Api.appendTripGpsPoints(entry.key, entry.value);
        sent += entry.value.length;
      } catch (_) {
        failed = true;
        remaining.addAll(entry.value);
      }
    }

    try {
      final prefs = await _prefs;
      await prefs.setStringList(
          _key, [for (final p in remaining) jsonEncode(p.toJson())]);
    } catch (_) {}
    return sent;
  }

  static Future<void> _clear() async {
    try {
      await (await _prefs).remove(_key);
    } catch (_) {}
  }
}
