// The server's clock, as the phone keeps it.
//
// A punch taken with no signal is stamped off this, and an app opened in a
// dead zone has heard nothing from the server yet — so the last skew the
// server reported has to survive a restart, and must never beat a live one.

import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/server_clock.dart';

void main() {
  test('a live header corrects the device clock', () {
    final ahead = DateTime.now().toUtc().add(const Duration(minutes: 40));
    ServerClock.I.syncFromHeader(HttpDate.format(ahead));
    final drift = ServerClock.I.now().difference(DateTime.now()).inMinutes;
    expect(drift, inInclusiveRange(39, 40));
  });

  test('a saved skew never overrides a live one', () async {
    SharedPreferences.setMockInitialValues({'serverClockSkewMs': 3600000});
    final ahead = DateTime.now().toUtc().add(const Duration(minutes: 10));
    ServerClock.I.syncFromHeader(HttpDate.format(ahead));
    await ServerClock.I.restore();
    final drift = ServerClock.I.now().difference(DateTime.now()).inMinutes;
    expect(drift, inInclusiveRange(9, 10),
        reason: 'the server said 10 minutes this run; the saved hour is older');
  });

  test('an unreadable header changes nothing', () {
    final before = ServerClock.I.now().difference(DateTime.now()).inMinutes;
    ServerClock.I.syncFromHeader('not a date');
    final after = ServerClock.I.now().difference(DateTime.now()).inMinutes;
    expect(after, before);
  });
}
