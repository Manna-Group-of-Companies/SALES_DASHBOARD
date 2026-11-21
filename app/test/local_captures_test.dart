// A location once captured must not be asked for again (14 Nov 2026, the
// user). The lists every page opens from could still say "Not Captured"
// after a capture: kept in the outbox with no signal, or read from the copy
// on the phone made before it.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/services/local_captures.dart';

Map<String, dynamic> _row(String status, String modified) => {
      'name': 'Drona Tyres',
      'custom_location_status': status,
      'modified': modified,
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalCaptures.clearForTest();
  });

  Future<void> capture() => LocalCaptures.record(
      doctype: 'Customer',
      name: 'Drona Tyres',
      status: 'Pending Verification',
      lat: 11.07342,
      lng: 76.21732,
      selfVerified: false,
      recapture: false);

  test('a list read before the capture still shows it captured', () async {
    await capture();
    final rows = await LocalCaptures.overlay(
        'Customer', [_row('Not Captured', '2026-01-01 10:00:00.000000')]);
    expect(rows.single['custom_location_status'], 'Pending Verification');
    expect(rows.single['custom_latitude'], 11.07342);
  });

  test('a manager sending it back after the capture asks again', () async {
    await capture();
    final rows = await LocalCaptures.overlay(
        'Customer', [_row('Not Captured', '2099-01-01 10:00:00.000000')]);
    expect(rows.single['custom_location_status'], 'Not Captured');
  });

  test('once the server has it, the server is the truth', () async {
    await capture();
    final rows = await LocalCaptures.overlay(
        'Customer', [_row('Verified', '2099-01-01 10:00:00.000000')]);
    expect(rows.single['custom_location_status'], 'Verified');
    // And the note is gone: a later rejection is not overridden.
    final later = await LocalCaptures.overlay(
        'Customer', [_row('Not Captured', '2099-02-01 10:00:00.000000')]);
    expect(later.single['custom_location_status'], 'Not Captured');
  });

  test('another doctype of the same name is not touched', () async {
    await capture();
    final rows = await LocalCaptures.overlay(
        'Lead', [_row('Not Captured', '2026-01-01 10:00:00.000000')]);
    expect(rows.single['custom_location_status'], 'Not Captured');
  });
}
