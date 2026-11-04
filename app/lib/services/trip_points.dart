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

import 'package:manna_field_sales/core/errors.dart';
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

  static Future<int>? _inFlight;

  /// Sends everything queued, oldest first, and returns how many got through.
  ///
  /// The network going stops the run and keeps the rest. Carrying on would
  /// spend a dead network on every point in the queue, and the order matters —
  /// a route drawn out of sequence is worse than one that is simply short.
  ///
  /// A trip the server REFUSES does not stop it. That used to: the refused
  /// trip stayed at the head of the queue, every later trip queued behind it
  /// for good, and past [_maxQueued] their points started falling off the
  /// end. Its points are kept and retried; the other trips go.
  ///
  /// Points are grouped per trip so a day's backlog is one write per trip
  /// rather than one per point: [Api.appendTripGpsPoints] re-reads the trip and
  /// appends the lot.
  ///
  /// One run at a time. A fix arrives every five minutes and the home screen
  /// flushes on every resume; two runs overlapping read the same trip, and
  /// the second write replaces the first.
  ///
  /// [send] is for tests; it defaults to [Api.appendTripGpsPoints].
  static Future<int> flush(
      {Future<void> Function(String trip, List<TripPoint> points)? send}) {
    return _inFlight ??= _flush(send ?? Api.appendTripGpsPoints)
        .whenComplete(() => _inFlight = null);
  }

  static Future<int> _flush(
      Future<void> Function(String trip, List<TripPoint> points) send) async {
    List<String> raw;
    try {
      raw = (await _prefs).getStringList(_key) ?? <String>[];
    } catch (_) {
      return 0;
    }
    if (raw.isEmpty) return 0;

    // Each point travels with the exact stored string it came from, which is
    // what removing it matches on. Re-encoding the point would not do: a
    // coordinate stored as 76 comes back as 76.0, and the sent point would
    // stay queued and be sent again on every run.
    //
    // Rows that will not decode are dropped along with what is sent: they can
    // never go, and left in place the queue would never empty.
    final done = <String>{};
    final byTrip = <String, List<(String, TripPoint)>>{};
    for (final s in raw) {
      final p = _decode(s);
      if (p == null) {
        done.add(s);
        continue;
      }
      // Grouped in the order the trips first appear, so the oldest trip's
      // backlog goes first.
      byTrip.putIfAbsent(p.trip, () => []).add((s, p));
    }

    var sent = 0;
    for (final entry in byTrip.entries) {
      try {
        await send(entry.key, [for (final (_, p) in entry.value) p]);
        sent += entry.value.length;
        done.addAll([for (final (s, _) in entry.value) s]);
      } catch (e) {
        if (isNetworkFailure(e)) break;
        // Refused. Kept for the next run; the other trips still go.
      }
    }

    // Removes what went, from the queue AS IT IS NOW — never writes back the
    // copy read at the start. A fix recorded while the upload was in flight
    // is in the queue now and was not in that copy, and writing the copy back
    // is exactly how it used to be wiped.
    if (done.isNotEmpty) {
      try {
        final prefs = await _prefs;
        final now = prefs.getStringList(_key) ?? <String>[];
        await prefs.setStringList(
            _key, now.where((s) => !done.contains(s)).toList());
      } catch (_) {}
    }
    return sent;
  }

  static TripPoint? _decode(String s) {
    try {
      return TripPoint.fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
