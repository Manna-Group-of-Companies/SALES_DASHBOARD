// The one place that decides whether a rep may put a place on the map here.
//
// Both callers — capturing a lead's location, and punching in on a lead — ask
// the same question and must get the same answer, so the question is asked in
// exactly one function. Two copies of this would drift, and the copy that
// drifted looser would be the one reps learned to use.

import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/proximity.dart';
import 'package:manna_field_sales/services/api.dart';

/// Runs the duplicate check and, if anything is nearby, tells the rep and
/// refuses. Returns true only when the ground is genuinely clear.
///
/// Fails closed when the server refuses the lookup. With no signal it lets the
/// rep through, because the write is kept on the phone and this same check
/// runs before it is sent — flight mode only delays the check, it does not
/// skip it.
Future<bool> ensureNothingNearby(
  BuildContext context, {
  required double lat,
  required double lng,
  required String subject,
  Set<String> exclude = const {},
  double radiusMetres = kDuplicateRadiusMetres,
}) async {
  late final List<NearbyPlace> near;
  try {
    near = await Api.nearbyPlaces(
        lat: lat, lng: lng, radiusMetres: radiusMetres, exclude: exclude);
  } catch (e) {
    // No signal and nothing kept to judge by (13 Nov 2026): let the rep carry
    // on. The write is then kept on the phone, and the same check runs on the
    // server's records when it is sent — a duplicate is refused there, on the
    // item, with the reason (Api._refuseIfDuplicate, and the punch queue's own
    // check). The guard does not open: it moves to where it can run.
    if (isNetworkFailure(e)) return true;
    if (context.mounted) {
      await _tell(
        context,
        title: 'Could not check for duplicates',
        body: 'The app could not read what is already on record here, so it '
            'will not $subject.\n\n${humanError(e)}',
      );
    }
    return false;
  }

  if (near.isEmpty) return true;
  if (!context.mounted) return false;

  await _showBlocked(context, near: near, subject: subject, radius: radiusMetres);
  return false;
}

/// What [nearbyGate] found.
enum NearbyGate {
  /// Nothing of another rep's is nearby.
  clear,

  /// Something is, or the check was refused; the rep has been told.
  blocked,

  /// There is no signal to check with. Nothing has been shown, and nothing
  /// has been decided — the caller must not treat this as [clear].
  unreachable,
}

/// [ensureNothingNearby] for a caller that can wait for the answer.
///
/// The punch card can: a lead visit punched in with no signal is queued, and
/// the check runs when it is sent, before anything is written (see
/// `services/pending_punches.dart`). So "no signal" comes back as its own
/// answer instead of a refusal. That is not the guard opening — the visit is
/// still never recorded without the check passing.
Future<NearbyGate> nearbyGate(
  BuildContext context, {
  required double lat,
  required double lng,
  required String subject,
  Set<String> exclude = const {},
  double radiusMetres = kDuplicateRadiusMetres,
}) async {
  late final List<NearbyPlace> near;
  try {
    near = await Api.nearbyPlaces(
        lat: lat, lng: lng, radiusMetres: radiusMetres, exclude: exclude);
  } catch (e) {
    if (isNetworkFailure(e)) return NearbyGate.unreachable;
    if (context.mounted) {
      await _tell(
        context,
        title: 'Could not check for duplicates',
        body: 'The app could not read what is already on record here, so it '
            'will not $subject.\n\n${humanError(e)}',
      );
    }
    return NearbyGate.blocked;
  }
  if (near.isEmpty) return NearbyGate.clear;
  if (context.mounted) {
    await _showBlocked(context,
        near: near, subject: subject, radius: radiusMetres);
  }
  return NearbyGate.blocked;
}

Future<void> _showBlocked(
  BuildContext context, {
  required List<NearbyPlace> near,
  required String subject,
  required double radius,
}) {
  final km = radius >= 1000
      ? '${(radius / 1000).toStringAsFixed(radius % 1000 == 0 ? 0 : 1)} km'
      : '${radius.round()} m';

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(children: const [
        Icon(Icons.wrong_location_outlined, color: Color(0xFFB3261E)),
        SizedBox(width: 8),
        Expanded(child: Text('Already on record here')),
      ]),
      content: SingleChildScrollView(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                near.length == 1
                    ? 'Another rep on your team already has a place on record '
                        'within $km of where you are standing, so you cannot '
                        '$subject here.'
                    : '${near.length} places belonging to other reps on your '
                        'team are already on record within $km of where you '
                        'are standing, so you cannot $subject here.',
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 6),
              // The two questions a rep asks on seeing this, answered before
              // they ring the office to ask them.
              const Text('Your own leads and customers never block you.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              // Named, so the rep can see at a glance whether this is genuinely
              // the same shop or a different one that happens to be close.
              ...near.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                              p.kind == 'Lead'
                                  ? Icons.person_search
                                  : Icons.storefront,
                              size: 18,
                              color: Colors.black54),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.label,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  Text(
                                      '${p.kind} · ${p.distanceLabel} · '
                                      '${p.ownerLabel}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54)),
                                ]),
                          ),
                        ]),
                  )),
              const Divider(),
              const Text('Different shop? Ask your sales manager.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ]),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}

Future<void> _tell(BuildContext context,
        {required String title, required String body}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(fontSize: 13.5, height: 1.4)),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
