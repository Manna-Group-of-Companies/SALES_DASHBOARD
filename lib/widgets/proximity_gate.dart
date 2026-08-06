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
/// Fails closed. If the lookup itself cannot run — no signal, server refusing —
/// this returns false and says why, rather than waving the rep through. A guard
/// that opens whenever the network is down is a guard that gets bypassed by
/// turning on flight mode, and duplicate leads are exactly what a rep in a
/// hurry would create that way.
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
    if (context.mounted) {
      await _tell(
        context,
        title: 'Could not check for duplicates',
        body: 'The app could not read what is already on record here, so it '
            'will not $subject. Get a signal and try again.\n\n${humanError(e)}',
      );
    }
    return false;
  }

  if (near.isEmpty) return true;
  if (!context.mounted) return false;

  await _showBlocked(context, near: near, subject: subject, radius: radiusMetres);
  return false;
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
                    ? 'There is already a place on record within $km of where '
                        'you are standing, so you cannot $subject here.'
                    : 'There are already ${near.length} places on record '
                        'within $km of where you are standing, so you cannot '
                        '$subject here.',
                style: const TextStyle(fontSize: 13.5, height: 1.4),
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
              const Text(
                'If this really is a different shop, ask your sales manager to '
                'remove the duplicate. Reps cannot delete leads or customers '
                'themselves.',
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
