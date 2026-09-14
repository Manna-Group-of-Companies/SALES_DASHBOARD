import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// How coarse a fix may be and still be worth writing down as a place.
///
/// `LocationAccuracy.high` is a request, not a promise. Indoors — which is
/// where a rep stands when they capture a shop — Android will happily answer
/// from cell towers instead of satellites and report an accuracy of several
/// kilometres. Nothing used to look at that figure, so a tower fix was written
/// into the verified fields and became the shop's permanent position; the rep
/// was then refused every punch-in from the counter they were standing at.
///
/// 100 m is loose enough for a real GPS fix through a shopfront and tight
/// enough that a tower fix never passes.
const double kMaxCaptureAccuracyMetres = 100;

/// How much benefit of the doubt a coarse fix earns at punch-in.
///
/// Punching in is judged more leniently than capturing: the pin is already on
/// record and the question is only whether the rep is at it, so a fix that is
/// merely mediocre should not refuse an honest visit. Capped, though — beyond
/// this the honest answer is "your GPS is not ready", not a wider and wider
/// circle that would eventually let a punch through from the next district.
const double kMaxAccuracyAllowanceMetres = 500;

/// A fix too coarse to write down.
///
/// Carries its own sentence: `humanError` shows the message of an exception it
/// recognises, and the accuracy is the whole point — "wait for GPS" means
/// nothing without saying how far out the phone currently thinks it is.
class CoarseFixException implements Exception {
  final double accuracyMetres;

  const CoarseFixException(this.accuracyMetres);

  @override
  String toString() =>
      'GPS is only accurate to about ${accuracyMetres.round()} m right now. '
      'Step outside, wait a few seconds for it to settle, and try again.';
}

/// The phone's current position.
///
/// [requireAccurate] refuses a fix too coarse to be worth recording. Pass it
/// wherever the coordinate is being *written down* as a place — capturing a
/// shop, a lead or a site. Reads that only measure against a pin do not need
/// it: they have [kMaxAccuracyAllowanceMetres] to absorb the error instead,
/// and refusing there would strand a rep at a counter over a bad minute of
/// signal.
Future<Position> getCurrentLocation({bool requireAccurate = false}) async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Location services are off. Turn on GPS.');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    throw Exception('Location permission denied.');
  }
  final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));

  // A non-positive accuracy means the platform did not say. Treated as usable
  // rather than refused: rounding the other way would block every capture on a
  // phone that reports nothing, which is a worse failure than the one this
  // guards against.
  if (requireAccurate &&
      pos.accuracy > 0 &&
      pos.accuracy > kMaxCaptureAccuracyMetres) {
    throw CoarseFixException(pos.accuracy);
  }
  return pos;
}
