// Which builds the gate lets through.
//
// Two failure modes matter here and they pull in opposite directions: letting a
// stale build write past rules it does not know about, and locking a working
// rep out of the app over a settings field. The tests pin both — the gate
// closes on a definite answer and on nothing else.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/app_version.dart';

void main() {
  group('Comparing versions', () {
    test('orders by each part in turn', () {
      expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
      expect(compareVersions('1.1.0', '1.0.9'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('does not compare part-by-part as text', () {
      // The mistake this pins: '10' < '9' as strings, so 1.10.0 would read as
      // older than 1.9.0 and every rep on the newer build would be blocked.
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    });

    test('a missing part counts as zero', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('a build suffix is ignored', () {
      // pubspec carries 1.1.0+2; the field will not.
      expect(compareVersions('1.1.0+2', '1.1.0'), 0);
      expect(compareVersions('1.1.0+99', '1.1.1'), lessThan(0));
    });

    test('junk compares equal rather than guessing', () {
      // Guessing either way is worse than doing nothing: one locks out a
      // working rep, the other lets a stale build through.
      expect(compareVersions('banana', '1.0.0'), 0);
      expect(compareVersions('1.0.0', ''), 0);
    });
  });

  group('The gate', () {
    test('lets a build newer than the minimum through', () {
      expect(checkVersion('1.2.0', '1.1.0').blocked, isFalse);
    });

    test('lets a build exactly at the minimum through', () {
      expect(checkVersion('1.1.0', '1.1.0').blocked, isFalse);
    });

    test('blocks a build older than the minimum', () {
      final g = checkVersion('1.0.0', '1.1.0');
      expect(g.blocked, isTrue);
      expect(g.required, '1.1.0');
    });
  });

  group('The gate never closes on silence', () {
    test('a blank minimum allows everything', () {
      // Clearing the field in Desk must turn the gate off, not lock out the
      // whole field team.
      for (final blank in [null, '', '   ', 'null']) {
        expect(checkVersion('1.0.0', blank).blocked, isFalse,
            reason: 'blocked on ${blank ?? 'null'}');
      }
    });

    test('an unparseable minimum allows everything', () {
      expect(checkVersion('1.0.0', 'soon').blocked, isFalse);
      expect(checkVersion('1.0.0', 'v2').blocked, isFalse);
    });

    test('unknown is not blocked', () {
      // What Api.appVersionGate returns when the lookup fails.
      expect(const VersionGate(VersionVerdict.unknown).blocked, isFalse);
    });
  });

  group('What the rep is told', () {
    test('the default names the version they need', () {
      final g = checkVersion('1.0.0', '1.4.2');
      expect(g.text, contains('1.4.2'));
      expect(g.text, contains('Update'));
    });

    test("the office's own wording wins when they set one", () {
      final g = checkVersion('1.0.0', '1.4.2',
          messageRaw: 'Collect the new app from Pareeth before Monday.');
      expect(g.text, 'Collect the new app from Pareeth before Monday.');
    });

    test('a blank custom message falls back rather than showing nothing', () {
      for (final blank in ['', '   ', 'null']) {
        final g = checkVersion('1.0.0', '1.4.2', messageRaw: blank);
        expect(g.text, contains('1.4.2'));
      }
    });
  });

  test('the shipped version is a version', () {
    // Guards against a typo in kAppVersion silently disabling the gate: an
    // unparseable current version compares equal to everything.
    expect(compareVersions(kAppVersion, '0.0.1'), greaterThan(0));
  });
}
