// Credit-period requests (16 Nov 2026): up to 30 days the manager decides and
// pushes; 31 to 40 the GM does, after the manager escalates. The cases are
// shared with the Server Script, the dashboard and the credit sync:
// shared/fixtures/credit_period_request.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manna_field_sales/core/credit_period_request.dart';

void main() {
  final fx = json.decode(File('../shared/fixtures/credit_period_request.json').readAsStringSync()) as Map;

  test('the limits are the fixture\'s', () {
    expect(fx['limits'], {'manager_max_days': kCreditPeriodManagerMaxDays, 'gm_max_days': kCreditPeriodGmMaxDays});
  });

  group('transitions (shared fixture)', () {
    for (final c in (fx['transitions'] as List).cast<Map>()) {
      test('${c['why']}', () {
        final got = cprNextStatus('${c['action']}', '${c['from']}', c['days'] as int, '${c['actor']}');
        expect(got ?? 'REFUSED', c['expect']);
      });
    }
  });

  group('submit (shared fixture)', () {
    for (final c in (fx['submit'] as List).cast<Map>()) {
      test('${c['why']}', () => expect(cprSubmitStatus(c['days'] as int) ?? 'REFUSED', c['expect']));
    }
  });

  group('bands (shared fixture)', () {
    for (final c in (fx['bands'] as List).cast<Map>()) {
      test('${c['why']}', () => expect(cprBand(c['days'] as int), c['band']));
    }
  });

  group('labels (shared fixture)', () {
    for (final c in (fx['labels'] as List).cast<Map>()) {
      test('"${c['status']}" reads as ${c['label']}', () => expect(cprLabel('${c['status']}'), c['label']));
    }
  });

  test('${(fx['offered'] as Map)['why']}', () {
    final o = fx['offered'] as Map;
    final terms = (o['terms'] as List).cast<Map>().map(SapPaymentTerm.fromJson).toList();
    expect(cprOfferedTerms(terms, o['current_code'] as int).map((t) => t.code).toList(), o['expect_codes']);
  });

  group('buttons', () {
    test('a button needs the server\'s word and the rule\'s', () {
      final r = CreditPeriodRequest.fromJson({
        'status': 'With Manager', 'requested_days': 35, 'actor': 'manager',
        'can_approve': 1, 'can_escalate': 1, 'can_reject': 1,
      });
      // A server that said approve on 35 days for a manager is out of date;
      // the phone does not offer it.
      expect(r.canApprove, isFalse);
      expect(r.canEscalate, isTrue);
      expect(r.canReject, isTrue);
      expect(r.needsGm, isTrue);
    });

    test('without the server\'s word nothing is offered', () {
      final r = CreditPeriodRequest.fromJson({'status': 'Approved', 'requested_days': 20, 'actor': 'manager'});
      expect(r.canPush, isFalse);
      expect(r.waitingOnMe, isFalse);
    });

    test('a request read with no status offers nothing and reads as with the manager', () {
      final r = CreditPeriodRequest.fromJson({'name': 'CPR-00001', 'can_approve': 1, 'actor': 'gm'});
      expect(r.label, 'With Manager');
      expect(r.canApprove, isFalse);
    });
  });
}
