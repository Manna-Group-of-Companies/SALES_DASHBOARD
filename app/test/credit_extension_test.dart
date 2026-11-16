// Temporary credit extension (16 Nov 2026). The cases are shared with the
// Server Script, the dashboard and the SAP job: shared/fixtures/credit_extension.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/credit_extension.dart';

void main() {
  final fx = json.decode(File('../shared/fixtures/credit_extension.json').readAsStringSync()) as Map;
  List<Map> cases(String k) => (fx[k] as List).cast<Map>();
  double n(Object? v) => (v as num).toDouble();

  test('the manager\'s limit is the fixture\'s', () {
    expect((fx['limits'] as Map)['manager_max_days'], kExtensionManagerMaxDays);
  });

  group('routing', () {
    for (final c in cases('routing')) {
      test('${c['why']}', () => expect(xtRouteStatus(c['missed_before'] as int, c['open_extension'] as bool), c['expect']));
    }
  });

  group('manager approval', () {
    for (final c in cases('manager_approval')) {
      test('${c['why']}', () => expect(
          xtCheckManager(
              amount: n(c['amount']),
              authority: n(c['authority']),
              approvedOn: '${c['approved_on']}',
              commitment: '${c['commitment']}',
              reason: '${c['reason']}',
              remarks: '${c['remarks']}'),
          c['expect']));
    }
  });

  group('GM approval', () {
    for (final c in cases('gm_approval')) {
      test('${c['why']}', () => expect(
          xtCheckGm(amount: n(c['amount']), today: '${c['today']}', commitment: '${c['commitment']}', remarks: '${c['remarks']}'),
          c['expect']));
    }
  });

  group('transitions', () {
    for (final c in cases('transitions')) {
      test('${c['why']}', () => expect(xtNextStatus('${c['action']}', '${c['from']}', '${c['actor']}') ?? 'REFUSED', c['expect']));
    }
  });

  group('payment status', () {
    for (final c in cases('payment_status')) {
      test('${c['why']}', () {
        final p = xtPaymentStatus(n(c['amount']), n(c['paid']));
        expect(p.status, c['expect']);
        expect(p.remaining, n(c['remaining']));
      });
    }
  });

  group('outcome', () {
    for (final c in cases('outcome')) {
      test('${c['why']}', () => expect(xtOutcome(n(c['amount']), n(c['paid']), '${c['today']}', '${c['commitment']}'), c['expect']));
    }
  });

  test('a button needs the server\'s word and the rule\'s', () {
    final stale = CreditExtension({'status': kXtPendingGm, 'actor': 'manager', 'can_approve': 1});
    expect(stale.canApprove, isFalse);
    final mine = CreditExtension({'status': kXtPendingManager, 'actor': 'manager', 'can_approve': 1, 'can_escalate': 1});
    expect(mine.canApprove, isTrue);
    expect(mine.canEscalate, isTrue);
    expect(CreditExtension({'status': kXtPendingManager, 'actor': 'manager'}).waitingOnMe, isFalse);
  });

  test('10 calendar days across a year end', () {
    expect(xtCheckManager(amount: 1, authority: 5, approvedOn: '2026-12-27', commitment: '2027-01-06', reason: 'r', remarks: 'r'), isNull);
    expect(xtCheckManager(amount: 1, authority: 5, approvedOn: '2026-12-27', commitment: '2027-01-07', reason: 'r', remarks: 'r'), 'too_long');
  });
}
