import 'dart:async';
import 'dart:io' show HttpDate;

import 'package:shared_preferences/shared_preferences.dart';

/// The clock the app judges time-of-day rules against.
///
/// A rep controls the phone's clock, so `DateTime.now()` cannot decide whether
/// a punch falls inside its allowed window. Every Frappe response carries a
/// `Date` header, so the app learns the server's skew for free and corrects for
/// it. The server re-checks every punch anyway — this only stops the app from
/// offering a punch the server is going to refuse.
///
/// The skew is also kept on the phone. A punch taken with no signal is stamped
/// here and sent later with that stamp, and an app opened in a dead zone has
/// heard no `Date` header yet — without the saved skew it would stamp straight
/// off the handset. The saved figure is the last thing the server said; it
/// cannot see a clock moved since, which is why a queued punch is only as good
/// as the phone's clock between its last contact and the punch.
class ServerClock {
  static final ServerClock I = ServerClock._();
  ServerClock._();

  static const _prefsKey = 'serverClockSkewMs';

  Duration _skew = Duration.zero;

  /// True once a live header has been read this run. A saved skew must never
  /// overwrite one heard from the server since the app started.
  bool _live = false;

  Duration _saved = Duration.zero;

  /// Feeds in the `Date` header of any response. Cheap, so the session
  /// interceptor calls it on every single one.
  void syncFromHeader(String? httpDate) {
    if (httpDate == null || httpDate.isEmpty) return;
    try {
      _skew = HttpDate.parse(httpDate).difference(DateTime.now().toUtc());
      _live = true;
      // Written only when it has moved by more than the header's own
      // one-second resolution can explain, so this is not a disk write on
      // every response.
      if ((_skew - _saved).abs() > const Duration(seconds: 5)) {
        _saved = _skew;
        unawaited(_persist(_skew));
      }
    } catch (_) {
      // Unparseable header — keep whatever skew we already had.
    }
  }

  /// Picks the last saved skew back up. Called once at start-up; does nothing
  /// if the server has already been heard from.
  Future<void> restore() async {
    try {
      final ms = (await SharedPreferences.getInstance()).getInt(_prefsKey);
      if (ms == null) return;
      final saved = Duration(milliseconds: ms);
      if (_live) {
        // The server got in first, and its figure stands. But _saved has to
        // learn what is on disk, or a live skew within five seconds of zero
        // is never written and a stale figure waits for the next dead-zone
        // launch.
        if ((_skew - saved).abs() > const Duration(seconds: 5)) {
          _saved = _skew;
          unawaited(_persist(_skew));
        } else {
          _saved = saved;
        }
        return;
      }
      _skew = _saved = saved;
    } catch (_) {
      // No saved figure is the same as a first launch: device clock.
    }
  }

  static Future<void> _persist(Duration skew) async {
    try {
      await (await SharedPreferences.getInstance())
          .setInt(_prefsKey, skew.inMilliseconds);
    } catch (_) {}
  }

  /// Now, as the server sees it, rendered in the phone's own timezone. Before
  /// the first response lands this is the device clock corrected by the last
  /// skew the server ever reported.
  ///
  /// Inside [at], the moment given there instead: a write kept on the phone
  /// and sent later runs as of when the rep made it, so every "today" and
  /// "now" it stamps — and every time-of-day rule it is judged by — is the
  /// moment they did it, not the moment the signal came back.
  DateTime now() {
    final z = Zone.current[_zoneKey];
    if (z is DateTime) return z;
    return DateTime.now().add(_skew);
  }

  static const Symbol _zoneKey = #mannaWrittenAt;

  /// Runs [f] with [now] answering [moment].
  static Future<T> at<T>(DateTime moment, Future<T> Function() f) =>
      runZoned(f, zoneValues: {_zoneKey: moment});
}
