// What the app will and will not offer as an update.
//
// The rule fails silent in every direction: anything unreadable means "no
// update" rather than a prompt a rep cannot act on. These tests exist because
// the failure mode is invisible — a bad manifest that produced a prompt would
// only be discovered by a rep tapping Update and getting nothing.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/app_update.dart';

const _apk = 'https://github.com/Mannagoc/SALES_DASHBOARD/releases/download/'
    'android-v1.1.0+143/manna-field-sales.apk';

Map<String, dynamic> _manifest({
  Object? version = '1.1.0',
  Object? build = 143,
  Object? apk = _apk,
  Object? notes,
}) =>
    {'version': version, 'build': build, 'apk': apk, 'notes': notes};

void main() {
  group('reading version.json', () {
    test('a well-formed manifest is read whole', () {
      final u = parseUpdateManifest(_manifest(notes: 'Dispatch planning'));
      expect(u, isNotNull);
      expect(u!.version, '1.1.0');
      expect(u.build, 143);
      expect(u.apkUrl, _apk);
      expect(u.notes, 'Dispatch planning');
    });

    test('a build number arriving as a string is still a number', () {
      // Frappe and hand-edited JSON both do this, and it decides the whole
      // comparison — reading it as null would silently fall back to the
      // version name, which CI does not bump.
      expect(parseUpdateManifest(_manifest(build: '143'))!.build, 143);
    });

    test('no answer at all is not an update', () {
      expect(parseUpdateManifest(null), isNull);
      expect(parseUpdateManifest('<html>404</html>'), isNull);
      expect(parseUpdateManifest(const []), isNull);
    });

    test('a manifest with nowhere to download from is refused', () {
      // A prompt whose button cannot do anything is worse than no prompt.
      expect(parseUpdateManifest(_manifest(apk: '')), isNull);
      expect(parseUpdateManifest(_manifest(apk: null)), isNull);
      expect(parseUpdateManifest(_manifest(apk: 'null')), isNull);
    });

    test('a non-https download link is refused', () {
      // This string is handed to a downloader and its result to Android's
      // package installer. It is not a place to accept anything at all.
      expect(parseUpdateManifest(_manifest(apk: 'http://example.com/a.apk')),
          isNull);
      expect(parseUpdateManifest(_manifest(apk: 'file:///sdcard/a.apk')), isNull);
      expect(
          parseUpdateManifest(_manifest(apk: 'javascript:alert(1)')), isNull);
    });

    test('a manifest with no version is refused', () {
      expect(parseUpdateManifest(_manifest(version: '')), isNull);
      expect(parseUpdateManifest(_manifest(version: null)), isNull);
    });

    test('a missing build number is tolerated, not fatal', () {
      // Falls back to comparing version names — see isWorthOffering.
      final u = parseUpdateManifest(_manifest(build: null));
      expect(u, isNotNull);
      expect(u!.build, isNull);
    });
  });

  group('whether to offer it', () {
    AvailableUpdate at({String version = '1.1.0', int? build}) =>
        AvailableUpdate(version: version, build: build, apkUrl: _apk);

    test('a newer build is offered even when the version name has not moved',
        () {
      // The case this feature turns on. pubspec.yaml said 1.1.0+2 from launch
      // until this was built, so the version name cannot be the signal.
      expect(
        isWorthOffering(
            available: at(build: 143), currentVersion: '1.1.0', currentBuild: 2),
        isTrue,
      );
    });

    test('the build already installed is not offered again', () {
      expect(
        isWorthOffering(
            available: at(build: 143), currentVersion: '1.1.0', currentBuild: 143),
        isFalse,
      );
    });

    test('an older build is never offered — no downgrades', () {
      // Most likely a half-finished rollback. Walking a rep backwards past a
      // rule their build already enforces is worth refusing outright.
      expect(
        isWorthOffering(
            available: at(build: 100), currentVersion: '1.1.0', currentBuild: 143),
        isFalse,
      );
    });

    test('with no build numbers, the version name decides', () {
      expect(
        isWorthOffering(
            available: at(version: '1.2.0'),
            currentVersion: '1.1.0',
            currentBuild: null),
        isTrue,
      );
      expect(
        isWorthOffering(
            available: at(version: '1.0.0'),
            currentVersion: '1.1.0',
            currentBuild: null),
        isFalse,
      );
    });

    test('an unparseable version name is not an update', () {
      // compareVersions returns 0 for junk rather than guessing, and 0 lands
      // on "no update" — the safe side.
      expect(
        isWorthOffering(
            available: at(version: 'latest'),
            currentVersion: '1.1.0',
            currentBuild: null),
        isFalse,
      );
    });
  });

  group('the whole decision', () {
    test('a newer published build becomes an offer', () {
      final u = updateToOffer(
          manifest: _manifest(), currentVersion: '1.1.0', currentBuild: 2);
      expect(u, isNotNull);
      expect(u!.label, '1.1.0 (143)');
    });

    test('a backend that did not answer says nothing to the rep', () {
      expect(
        updateToOffer(
            manifest: null, currentVersion: '1.1.0', currentBuild: 2),
        isNull,
      );
    });

    test('a readable manifest for the build already running says nothing', () {
      expect(
        updateToOffer(
            manifest: _manifest(build: 2),
            currentVersion: '1.1.0',
            currentBuild: 2),
        isNull,
      );
    });

    test('a newer build with an unusable link says nothing', () {
      // Both halves have to hold: newer AND fetchable.
      expect(
        updateToOffer(
            manifest: _manifest(build: 900, apk: 'http://x/a.apk'),
            currentVersion: '1.1.0',
            currentBuild: 2),
        isNull,
      );
    });
  });
}
