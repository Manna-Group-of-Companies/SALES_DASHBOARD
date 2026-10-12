import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/trip_points.dart';

class TripTracker {
  static final TripTracker I = TripTracker._();
  TripTracker._();

  final ValueNotifier<String?> activeTrip = ValueNotifier<String?>(null);
  StreamSubscription<Position>? _sub;

  /// Asks for a fix on a schedule, rather than waiting to be given one.
  ///
  /// The position stream alone was not enough. Android's fused provider emits
  /// on *change*, so a phone sitting still in a shop — or parked, or in a
  /// pocket while the rep has a cup of tea — can produce nothing for an hour,
  /// and the route came back with one point on it. This timer asks outright
  /// every five minutes, so a stationary rep still leaves a trail.
  Timer? _ticker;

  DateTime? _lastSaved;
  static const Duration interval = Duration(minutes: 5);

  /// True when recording is running on "while using the app" only.
  ///
  /// The route will still be logged, but it is at the mercy of the handset:
  /// lock the phone or leave the app for long enough and Android may stop
  /// feeding it. Surfaced so a screen can say so rather than letting a rep
  /// discover it from an empty route at the end of the day.
  bool needsAlwaysPermission = false;

  /// Opens this app's settings page, where "Allow all the time" lives.
  /// Android will not grant it from a dialog — the rep has to set it there.
  Future<void> openLocationSettings() => Geolocator.openAppSettings();

  bool isRecording(String tripName) => activeTrip.value == tripName;

  /// True while [start] is between its first check and setting [activeTrip].
  /// Without it a second caller saw "not recording" and started a second run.
  bool _starting = false;

  /// When [resumeIfNeeded] last tried, so a resume that cannot succeed is not
  /// retried on every rebuild of the home screen.
  DateTime? _autoResumeTriedAt;
  static const Duration _autoResumeCooldown = Duration(minutes: 2);

  /// Starts recording [tripName].
  ///
  /// [interactive] is whether a person just asked for this by tapping a
  /// button. Only then may it show a permission dialog. An automatic start
  /// (see [resumeIfNeeded]) never prompts. A permission request pauses and
  /// resumes the app, and the home screen calls [resumeIfNeeded] on every
  /// resume. On 11 Oct 2026 a phone where location had been refused for good
  /// ran that loop 412 times in four minutes: Punch Out blinked, and Android's
  /// permission screen crashed under the load.
  Future<String?> start(String tripName, {bool interactive = true}) async {
    if (activeTrip.value == tripName) return null;
    if (activeTrip.value != null) {
      return 'Another trip (${activeTrip.value}) is already recording. Stop it first.';
    }
    if (_starting) return null;
    _starting = true;
    try {
      return await _start(tripName, interactive);
    } finally {
      _starting = false;
    }
  }

  Future<String?> _start(String tripName, bool interactive) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on GPS/location first.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && interactive) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return 'Location permission denied. Allow location to record the route.';
    }

    // "While using the app" is not enough for a trip.
    //
    // Android grants that first, and it keeps location alive only while the
    // app is on screen or a foreground service is running. The service does
    // run — but a rep who locks the phone and drives for an hour is exactly
    // the case this has to survive, and on many handsets whileInUse is quietly
    // dropped once the screen goes off.
    //
    // Asking a second time is what Android requires: "Allow all the time"
    // cannot be requested until the basic grant exists. Recording still starts
    // if they refuse — a partial route beats none — and the caller is told so
    // it can explain.
    needsAlwaysPermission = perm == LocationPermission.whileInUse;
    if (needsAlwaysPermission && interactive) {
      try {
        final again = await Geolocator.requestPermission();
        needsAlwaysPermission = again != LocationPermission.always;
      } catch (_) {}
    }
    /*
     * The two platforms keep a phone recording in completely different ways,
     * and passing AndroidSettings on an iPhone silently gets you neither.
     *
     * Android holds a foreground service with an ongoing notification. iOS has
     * no such thing: it needs `allowBackgroundLocationUpdates`, the `location`
     * background mode in Info.plist, and `pauseLocationUpdatesAutomatically`
     * turned OFF — iOS otherwise decides for itself that a stationary phone
     * has stopped travelling and quietly stops the stream, which on a rep sat
     * in traffic loses the rest of the trip.
     *
     * Until 18 Aug 2026 only the Android half existed, so an iPhone fell back
     * to plain foreground settings and the route stopped the moment the screen
     * locked.
     */
    final LocationSettings settings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            allowBackgroundLocationUpdates: true,
            pauseLocationUpdatesAutomatically: false,
            // The blue bar. Deliberate: a rep should be able to see that the
            // app is tracking them, and be able to stop it.
            showBackgroundLocationIndicator: true,
            activityType: ActivityType.automotiveNavigation,
          )
        : AndroidSettings(
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

    // Belt and braces with the stream above. Whichever produces a fix first
    // wins; the throttle in _save stops them recording the same minute twice.
    _ticker?.cancel();
    _ticker = Timer.periodic(interval, (_) async {
      if (activeTrip.value != tripName) return;
      final now = DateTime.now();
      if (_lastSaved != null && now.difference(_lastSaved!) < interval) return;
      try {
        final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                timeLimit: Duration(seconds: 45)));
        await _save(tripName, pos);
      } catch (_) {
        // No fix this time — indoors, or the radio is busy. The next tick
        // tries again, and nothing is lost because nothing was recorded.
      }
    });
    return null;
  }

  /// Picks recording back up if it should be running and is not.
  ///
  /// The tracker lives in memory, so an app that Android has killed and the
  /// rep has reopened is no longer recording even though the trip is still
  /// Active on the server. There is a banner offering to resume, but it only
  /// helps a rep who opens the app and notices it — and a rep driving all
  /// afternoon has no reason to.
  ///
  /// Safe to call as often as you like. It does nothing when already running,
  /// tries at most once per [_autoResumeCooldown], and never asks for
  /// permission. If location is not granted, the banner's Resume button is
  /// how the rep fixes it.
  Future<void> resumeIfNeeded() async {
    if (activeTrip.value != null || _starting) return;
    if (Session.I.salesPerson == null) return;
    final now = DateTime.now();
    final last = _autoResumeTriedAt;
    if (last != null && now.difference(last) < _autoResumeCooldown) return;
    _autoResumeTriedAt = now;
    try {
      final trip = await Api.getActiveTrip();
      final name = '${trip?['name'] ?? ''}';
      if (name.isEmpty || name == 'null') return;
      await start(name, interactive: false);
    } catch (_) {}
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
    _ticker?.cancel();
    _ticker = null;
    _lastSaved = null;
    activeTrip.value = null;
    _autoResumeTriedAt = null;
    // A trip that has just ended is the moment its route matters most, so the
    // queue is pushed once more rather than waiting for the next fix.
    unawaited(TripPoints.flush());
  }
}

