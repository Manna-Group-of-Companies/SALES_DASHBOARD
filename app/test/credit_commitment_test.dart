// The rep's commitment and who may decide an over-limit order, read from the
// shared fixture the dashboard's suite reads too.
//
// The phone raises these orders and the dashboard mostly decides them, so a
// rule that drifted on either side would let an order through the gap between
// them. Both are held to the same cases.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/credit_commitment.dart';

void main() {
  final raw =
      File('../shared/fixtures/credit_commitment.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;
  List<Map<String, dynamic>> cases(String k) =>
      (fixture[k] as List).cast<Map<String, dynamic>>();

  const message = {
    'missing': kCommitmentMissing,
    'too_short': kCommitmentTooShort,
    'condition_required': kConditionRequired,
  };

  group('the words both apps say', () {
    test('match the fixture word for word', () {
      final m = fixture['messages'] as Map<String, dynamic>;
      expect(kCommitmentMissing, m['missing']);
      expect(kCommitmentTooShort, m['too_short']);
      expect(kConditionRequired, m['condition_required']);
      expect(kCommentEmpty, m['comment_empty']);
      expect(kSalesManagerCannotApprove, m['sales_manager_cannot_approve']);
      expect(kGmDoesNotPush, m['gm_does_not_push']);
      expect(kCommitmentMinLength, (fixture['rules'] as Map)['min_length']);
    });
  });

  group('when the rep must write a commitment', () {
    for (final c in cases('required')) {
      test(c['why'] as String, () {
        expect(
          commitmentRequired(
            (c['customer'] as Map).cast<String, dynamic>(),
            (c['order_total'] as num).toDouble(),
            isLead: c['is_lead'] == true,
          ),
          c['expect'],
        );
      });
    }
  });

  group('what counts as a commitment', () {
    for (final c in cases('text')) {
      test(c['why'] as String, () {
        final want = c['expect'] == null ? null : message[c['expect']];
        expect(commitmentProblem(c['text']), want);
      });
    }
  });

  group('who may do what to an order', () {
    for (final c in cases('actions')) {
      test(c['why'] as String, () {
        final got = orderActions(
          role: c['role'] as String,
          poStatus: c['po_status'],
          overLimit: c['over_limit'] as bool,
        );
        final want = c['expect'] as Map<String, dynamic>;
        expect(
          {
            'approve': got.approve,
            'gm_approve': got.gmApprove,
            'escalate': got.escalate,
            'reject': got.reject,
            'comment': got.comment,
          },
          want,
        );
      });
    }

    test('the sales manager cannot approve an over-limit order until the GM '
        'has, whatever the status says', () {
      for (final s in [
        '',
        'No PO Yet',
        'Pending Approval',
        'Pending Rate Approval',
        'Pending GM Approval',
      ]) {
        expect(
          orderActions(role: 'sales_manager', poStatus: s, overLimit: true)
              .approve,
          isFalse,
          reason: 'status=$s',
        );
      }
    });

    test('the GM never pushes to SAP, on any status, over the limit or not',
        () {
      // Asked for 24 Sep 2026: the GM approves the credit and the sales
      // manager pushes. `approve` is the push.
      for (final s in [
        '',
        'No PO Yet',
        'Pending Approval',
        'Pending GM Approval',
        kPoFinalApproval,
        'Rejected',
      ]) {
        for (final over in [true, false]) {
          expect(
            orderActions(role: 'general_manager', poStatus: s, overLimit: over)
                .approve,
            isFalse,
            reason: 'status=$s over=$over',
          );
        }
      }
    });

    test('a login decides as the GM before anything else it may be', () {
      expect(orderRoleOf(isGM: true, isManager: true), 'general_manager');
      expect(orderRoleOf(isGM: false, isManager: true), 'sales_manager');
      expect(orderRoleOf(isGM: false, isManager: false), 'rep');
    });
  });

  group('the condition the GM approval creates', () {
    for (final c in cases('approval')) {
      test(c['why'] as String, () {
        final e = c['expect'] as Map<String, dynamic>;
        expect(conditionRequiredOnApproval(c['commitment']), e['required']);
        final want = e['problem'] == null ? null : message[e['problem']];
        expect(approvalConditionProblem(c['commitment'], c['condition']), want);
      });
    }
  });

  group('the follow-up after the GM has approved', () {
    final fu = fixture['follow_up'] as Map<String, dynamic>;
    for (final c in (fu['comment_roles'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        expect(commentAuthorRole(c['role'] as String), c['expect']);
      });
    }
    for (final c in (fu['note'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        expect(mayAddFollowUpNote(c['role'] as String), c['expect']);
      });
    }
  });

  group('the due date the GM starts from', () {
    for (final c in cases('default_due')) {
      test(c['why'] as String, () {
        expect(
          defaultConditionDue(
              c['commitment_due'], DateTime.parse('${c['today']} 09:00:00')),
          c['expect'],
        );
      });
    }
  });
}
