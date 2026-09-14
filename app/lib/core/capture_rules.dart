// Where a place's location may be moved to, and by whom.
//
// The verified pair is what every punch-in is measured against, and a capture
// that writes it directly has nobody checking it. S.N Agencies Karunagapally
// ended up with a pin 15.8 km from the shop; the rep standing at the counter
// was refused every visit, and because the record read `Verified` it never
// appeared in anyone's queue to be caught.
//
// So a self-verifying capture may correct a pin but may not relocate one. A
// rep's capture is never refused on distance — it is queued for a human, and
// refusing it is what left the wrong pin with no way back.
//
// Paired with `client/src/domain/capture.ts` and pinned by
// `shared/fixtures/capture.json`.

import 'package:manna_field_sales/core/proximity.dart';

/// How far a self-verifying capture may move a place that is already on record.
///
/// The punch-in radius, deliberately. Below it nothing breaks — the shop is
/// still punchable from where it stands. Above it the shop is not, which is
/// the whole failure this prevents.
const double kMaxSelfVerifiedMoveMetres = kPunchInRadiusMetres;

class CaptureVerdict {
  final bool allowed;

  /// How far this capture would move the pin, or null when there was no
  /// usable pin to move.
  final double? metresMoved;

  const CaptureVerdict(this.allowed, this.metresMoved);

  /// One sentence for whoever is being refused. They are at a desk, not in a
  /// shop, so it names the thing they should do instead.
  String get message {
    final away = metresMoved == null
        ? 'somewhere else'
        : metresMoved! < 1000
            ? '${metresMoved!.round()} m away'
            : '${(metresMoved! / 1000).toStringAsFixed(1)} km away';
    return 'This would move the saved location $away, which would stop anyone '
        'punching in at the place itself. Have the rep capture it while they '
        'are standing there.';
  }
}

/// Whether this capture may be written.
///
/// [selfVerifying] is true when the capture writes the verified pair itself —
/// a manager on the phone, or anyone on the dashboard.
CaptureVerdict checkCapture({
  required bool selfVerifying,
  required double lat,
  required double lng,
  double? existingLat,
  double? existingLng,
}) {
  if (!selfVerifying) return const CaptureVerdict(true, null);
  if (existingLat == null ||
      existingLng == null ||
      !isRealCoordinate(existingLat, existingLng)) {
    return const CaptureVerdict(true, null);
  }
  final moved = metresBetween(existingLat, existingLng, lat, lng);
  return CaptureVerdict(moved <= kMaxSelfVerifiedMoveMetres, moved);
}

/// A capture refused for moving a place too far.
///
/// Carries its own sentence — `humanError` shows the message of an exception
/// it recognises by name.
class CaptureRefused implements Exception {
  final CaptureVerdict verdict;

  const CaptureRefused(this.verdict);

  @override
  String toString() => verdict.message;
}
