import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/trip_points.dart';

class TripTracker {
  static final TripTracker I = TripTracker._();
  TripTracker._();

  final ValueNotifier<String?> activeTrip = ValueNotifier<String?>(null);
  StreamSubscription<Position>? _sub;
  DateTime? _lastSaved;
  static const Duration interval = Duration(minutes: 5);

  bool isRecording(String tripName) => activeTrip.value == tripName;

  Future<String?> start(String tripName) async {
    if (activeTrip.value == tripName) return null;
    if (activeTrip.value != null) {
      return 'Another trip (${activeTrip.value}) is already recording. Stop it first.';
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on GPS/location first.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return 'Location permission denied. Allow location to record the route.';
    }
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(minutes: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Manna — recording trip route',
        notificationText:
        'Logging your route while the trip is active. Tap to open.',
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon:
        AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    );
    activeTrip.value = tripName;
    _lastSaved = null;
    // Log an immediate first point so the route starts right away.
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      await _save(tripName, pos);
    } catch (_) {}
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) {
      final now = DateTime.now();
      if (_lastSaved == null || now.difference(_lastSaved!) >= interval) {
        _save(tripName, pos);
      }
    }, onError: (_) {});
    return null;
  }

  /// Records a point on the phone, then tries to send what is queued.
  ///
  /// The order is the whole fix. This used to upload directly and mark the
  /// throttle *before* trying — so a point that failed to send was lost, and
  /// the failure also blocked the next attempt for five minutes. A patchy
  /// signal did not thin the route out, it emptied it.
  ///
  /// Writing to the phone cannot fail for want of a network, so the throttle
  /// now advances on something that actually happened.
  Future<void> _save(String tripName, Position pos) async {
    _lastSaved = DateTime.now();
    await TripPoints.add(
        TripPoint(tripName, pos.latitude, pos.longitude, nowStamp()));
    // Best effort. Anything that does not go stays queued for the next one.
    unawaited(TripPoints.flush());
  }

  /// Sends whatever is waiting. Safe to call at any time — on resume, on the
  /// dashboard refresh, or when a trip ends.
  Future<int> flushPending() => TripPoints.flush();

  /// How many points are still on the phone.
  Future<int> pendingCount() => TripPoints.count();

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _lastSaved = null;
    activeTrip.value = null;
    // A trip that has just ended is the moment its route matters most, so the
    // queue is pushed once more rather than waiting for the next fix.
    unawaited(TripPoints.flush());
  }
}

