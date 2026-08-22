// Whether there is a newer build to offer, and where to get it.
//
// WHY THIS EXISTS
//
// Until 21 August 2026 a new build reached the reps as an APK on WhatsApp.
// Somebody had to remember to send it, every rep had to remember to install it,
// and there was no way to tell who was still on what. `app_version.dart`'s gate
// could refuse an old build but could not fix one — it told the rep to "ask the
// office for the new app file", which is exactly the step that kept failing.
//
// CI now publishes every build to a GitHub Release, together with a small
// `version.json` describing it. This file is the decision that reads it: is
// what is published newer than what is running, and is there something to
// download. The fetching and the installing live in
// `services/update_service.dart`; none of that is here, so the rule can be
// tested without a network or a phone.
//
// WHICH WAY IT FAILS
//
// **Silent.** Anything unreadable — no answer, malformed JSON, a missing URL,
// a version that will not parse — means "no update", never a prompt. A rep
// standing in a shop is not helped by a nag they cannot act on, and the
// version gate is what actually protects the fleet from a build that is too
// old. This only ever offers a convenience.
//
// It also never offers a **downgrade**. A release that is older than what is
// installed is treated as no update at all: the most likely cause is a
// half-finished rollback, and walking a rep backwards past a rule their build
// already enforces is the one outcome worth refusing outright.

import 'package:manna_field_sales/core/app_version.dart';

/// What CI published, as the app needs to read it.
class AvailableUpdate {
  /// Marketing version, `major.minor.patch`.
  final String version;

  /// The monotonic build number. This is the signal that actually decides an
  /// update, because it increases on every CI run whether or not anybody
  /// remembered to bump `pubspec.yaml` — which, historically, nobody did.
  final int? build;

  /// Direct link to the APK. Always https; see [parseUpdateManifest].
  final String apkUrl;

  /// What changed, if CI was given anything to say. May be empty.
  final String notes;

  const AvailableUpdate({
    required this.version,
    required this.build,
    required this.apkUrl,
    this.notes = '',
  });

  /// How the build is named to a rep: "1.1.0 (143)".
  String get label => build == null ? version : '$version ($build)';
}

/// Read `version.json`. Returns null for anything that cannot be trusted.
///
/// [raw] is the decoded JSON — a Map when the download worked, and typically
/// null or something unexpected when it did not.
AvailableUpdate? parseUpdateManifest(dynamic raw) {
  if (raw is! Map) return null;

  final version = '${raw['version'] ?? ''}'.trim();
  final apk = '${raw['apk'] ?? ''}'.trim();

  if (version.isEmpty || version == 'null') return null;

  // Nothing to offer without somewhere to get it. A prompt whose button
  // cannot do anything is worse than no prompt.
  if (apk.isEmpty || apk == 'null') return null;

  // https only. This string is handed to a downloader and the result is handed
  // to Android's package installer; it is not a place to accept whatever a
  // JSON file happens to contain.
  if (!apk.startsWith('https://')) return null;

  final buildRaw = raw['build'];
  final build =
      buildRaw is num ? buildRaw.toInt() : int.tryParse('${buildRaw ?? ''}'.trim());

  final notes = '${raw['notes'] ?? ''}'.trim();

  return AvailableUpdate(
    version: version,
    build: build,
    apkUrl: apk,
    notes: notes == 'null' ? '' : notes,
  );
}

/// Whether [available] is worth offering over what is running.
///
/// The build number decides it when both sides have one, because CI increments
/// that on every run and the version name may sit still for months. The
/// version name is the fallback for a manifest written by hand, or for a build
/// installed before build numbers were being published.
bool isWorthOffering({
  required AvailableUpdate available,
  required String currentVersion,
  required int? currentBuild,
}) {
  if (available.build != null && currentBuild != null) {
    return available.build! > currentBuild;
  }

  // No build number on one side or the other: fall back to the marketing
  // version. `compareVersions` returns 0 for anything it cannot parse, which
  // lands on "no update" — the safe side.
  return compareVersions(available.version, currentVersion) > 0;
}

/// The whole decision, from a decoded manifest to a yes or no.
///
/// Returns the update to offer, or null when there is nothing to say.
AvailableUpdate? updateToOffer({
  required dynamic manifest,
  required String currentVersion,
  required int? currentBuild,
}) {
  final available = parseUpdateManifest(manifest);
  if (available == null) return null;
  return isWorthOffering(
    available: available,
    currentVersion: currentVersion,
    currentBuild: currentBuild,
  )
      ? available
      : null;
}
