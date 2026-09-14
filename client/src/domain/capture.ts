/**
 * Where a place's location may be moved to, and by whom.
 *
 * The verified pair is what every punch-in on the phone is measured against,
 * and a capture that writes it directly has nobody checking it. S.N Agencies
 * Karunagapally ended up with a pin 15.8 km from the shop; the rep standing at
 * the counter was refused every visit, and because the record read `Verified`
 * it never appeared in anyone's queue to be caught.
 *
 * The dashboard is the easiest place to create exactly that pin — `capture`
 * here writes the *browser's* position, and a manager's browser is at the
 * office. So a capture from here may correct a pin but may not relocate one.
 *
 * Paired with `app/lib/core/capture_rules.dart` and pinned by
 * `shared/fixtures/capture.json`.
 */

import { haversineKm, hasFix } from './geo';

/**
 * How far a self-verifying capture may move a place already on record.
 *
 * The phone's punch-in radius, deliberately. Below it nothing breaks — the
 * shop is still punchable from where it stands. Above it the shop is not,
 * which is the whole failure this prevents. Kept in step with
 * `kPunchInRadiusMetres` in `app/lib/core/proximity.dart`.
 */
export const MAX_SELF_VERIFIED_MOVE_METRES = 2000;

export interface CaptureVerdict {
  allowed: boolean;
  /** How far this would move the pin, or undefined when there was none to move. */
  metresMoved?: number;
  /** One sentence for whoever is being refused. */
  message?: string;
}

function describe(metres: number): string {
  return metres < 1000 ? `${Math.round(metres)} m away` : `${(metres / 1000).toFixed(1)} km away`;
}

/**
 * Whether this capture may be written.
 *
 * `selfVerifying` is true when the capture writes the verified pair itself —
 * which, from the dashboard, it always does. A rep's capture on the phone is
 * false: it lands as `Pending Verification` and a human sees it before it
 * counts, so it is never refused on distance. Refusing it is precisely what
 * left a wrong pin with no way back.
 */
export function checkCapture(input: {
  selfVerifying: boolean;
  latitude: number;
  longitude: number;
  existingLatitude?: number | null;
  existingLongitude?: number | null;
}): CaptureVerdict {
  if (!input.selfVerifying) return { allowed: true };

  const existing = {
    latitude: input.existingLatitude ?? undefined,
    longitude: input.existingLongitude ?? undefined,
  };
  if (!hasFix(existing)) return { allowed: true };

  const metresMoved =
    haversineKm(existing, { latitude: input.latitude, longitude: input.longitude }) * 1000;

  if (metresMoved <= MAX_SELF_VERIFIED_MOVE_METRES) return { allowed: true, metresMoved };

  return {
    allowed: false,
    metresMoved,
    message:
      `This would move the saved location ${describe(metresMoved)}, which would stop ` +
      'anyone punching in at the place itself. Have the rep capture it while they are ' +
      'standing there.',
  };
}
