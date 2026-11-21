// The 10-day payment commitment ladder (17 Nov 2026). The cases are shared with the
// dashboard and the Server Scripts: shared/fixtures/payment_commitment.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/payment_commitment.dart';

void main() {
  final fx = json.decode(File('../shared/fixtures/payment_commitment.json').readAsStringSync()) as Map;
  List<Map> cases(String k) => (fx[k] as List).cast<Map>();
  double n(Object? v) => (v as num).toDouble();

  test('the limits are the fixture\'s', () {
    final l = fx['limits'] as Map;
    expect(l['max_days'], kPcMaxDays);
    expect(l['overdue_days_trigger'], kPcOverdueDays);
    expect(n(l['overdue_rounding']), kOverdueTolerance);
  });

  group('what an order needs', () {
    for (final c in cases('needs')) {
      test('${c['why']}', () {
        final r = pcNeeds((c['customer'] as Map).cast<String, dynamic>(), n(c['order_total']));
        final e = c['expect'] as Map;
        expect([r.overdue30, r.overLimit, r.excess, r.needs], [e['overdue30'], e['over_limit'], n(e['excess']), e['needs']]);
      });
    }
  });

  group('where it goes', () {
    for (final c in cases('route')) {
      test('${c['why']}', () => expect(
          pcRoute(
              needs: c['needs'] as bool,
              overLimit: c['over_limit'] as bool,
              excess: n(c['excess']),
              authority: n(c['authority']),
              gmLock: c['gm_lock'] as bool,
              capReached: c['cap_reached'] as bool),
          c['expect']));
    }
  });

  group('the GM lock', () {
    for (final c in cases('gm_lock')) {
      test('${c['why']}', () => expect(pcGmLock((c['commitments'] as List).cast<Map>()), c['expect']));
    }
  });

  group('an approval', () {
    for (final c in cases('approval')) {
      test('${c['why']}', () => expect(
          pcCheckApproval(approvedOn: '${c['approved_on']}', commitment: '${c['commitment']}', remarks: '${c['remarks']}'),
          c['expect']));
    }
  });

  group('tracking', () {
    for (final c in cases('track')) {
      test('${c['why']}', () => expect(
          pcTrack(
              status: '${c['status']}',
              approvedOn: '${c['approved_on']}',
              commitment: '${c['commitment']}',
              today: '${c['today']}',
              overdueNow: n(c['overdue_now']),
              syncedAt: '${c['synced_at']}'),
          c['expect']));
    }
  });

  group('order stage', () {
    for (final c in cases('order_status')) {
      test('${c['why']}', () => expect(
          pcOrderStage(poStatus: '${c['po_status']}', pushed: c['pushed'] as bool, commitment: '${c['commitment']}'),
          c['expect']));
    }
  });
}
