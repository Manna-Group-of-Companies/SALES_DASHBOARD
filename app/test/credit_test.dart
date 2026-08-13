// The outstanding balance, now that SAP sends it in four age buckets.
//
// Checked against `shared/fixtures/credit.json`, the same file the dashboard's
// `client/src/domain/__tests__/credit.test.ts` reads. A rule that changes on
// one side turns the other side red — which is the only thing that has actually
// stopped these two implementations drifting.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/credit.dart';

Map<String, dynamic> _fixture() {
  // Relative to `app/`, which is where `flutter test` runs from.
  final f = File('../shared/fixtures/credit.json');
  return json.decode(f.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _asMap(dynamic v) =>
    (v as Map).cast<String, dynamic>();

double _d(dynamic v) => (v as num).toDouble();

void main() {
  final fx = _fixture();

  group('shared fixture: the field names', () {
    test('reads the fields the fixture names, and no others', () {
      // If somebody renames a field on the site, this is the test that says so
      // before a screen quietly starts showing zero.
      final f = _asMap(fx['fields']);
      expect(kFieldOutstandingTotal, f['total']);
      expect(kFieldCreditLimit, f['credit_limit']);
      expect([
        kFieldOutstanding0_30,
        kFieldOutstanding30_60,
        kFieldOutstanding60_90,
        kFieldOutstanding90Plus,
      ], f['buckets']);
    });
  });

  group('shared fixture: what the total is', () {
    for (final raw in fx['total'] as List) {
      final c = _asMap(raw);
      test(c['why'] as String, () {
        final a = agingOf(_asMap(c['customer']));
        final e = _asMap(c['expect']);
        if (e['total'] != null) expect(a.total, closeTo(_d(e['total']), 0.01));
        if (e['buckets_known'] != null) expect(a.bucketsKnown, e['buckets_known']);
        if (e['mismatch'] != null) expect(a.mismatch, e['mismatch']);
      });
    }
  });

  group('shared fixture: old debt', () {
    for (final raw in fx['overdue'] as List) {
      final c = _asMap(raw);
      test(c['why'] as String, () {
        final customer = _asMap(c['customer']);
        final e = _asMap(c['expect']);
        final orderTotal = c['order_total'] == null ? 0.0 : _d(c['order_total']);

        if (e['overdue'] != null) {
          expect(overdueAmount(customer), closeTo(_d(e['overdue']), 0.01));
        }
        if (e['has_overdue'] != null) {
          expect(hasOverdue(customer), e['has_overdue']);
        }
        if (e['escalates'] != null) {
          expect(overCreditLimit(customer, orderTotal), e['escalates']);
        }
        if (e['blocks_order'] != null) {
          // The 90+ box is a warning, never a gate. Asserted separately from
          // `escalates` because they are different claims: one is about this
          // order's total, the other about the rule existing at all.
          expect(overCreditLimit(customer, 0), e['blocks_order']);
        }
      });
    }
  });

  // --------------------------------------------------- phone-side detail ---

  group('the credit limit stays one figure', () {
    test('is read whole, never aged', () {
      // SAP gives a single limit. Splitting it here would invent a number that
      // does not exist anywhere upstream.
      expect(agingOf({kFieldCreditLimit: 70000}).creditLimit, 70000);
    });
  });

  group('the four boxes', () {
    test('come out oldest last, with only the last one marked', () {
      final b = agingOf({
        kFieldOutstanding0_30: 1,
        kFieldOutstanding30_60: 2,
        kFieldOutstanding60_90: 3,
        kFieldOutstanding90Plus: 4,
      }).buckets;
      expect(b.map((x) => x.amount).toList(), [1, 2, 3, 4]);
      expect(b.map((x) => x.overdue).toList(), [false, false, false, true]);
    });

    test('does not mark the oldest box when there is nothing in it', () {
      // A red box with zero in it trains people to ignore red boxes.
      expect(agingOf({kFieldOutstanding0_30: 500}).buckets[3].overdue, isFalse);
    });
  });

  group('the numeric strings Frappe sometimes returns', () {
    test('are read as money, not as text', () {
      final a = agingOf({
        kFieldOutstandingTotal: '19000',
        kFieldOutstanding0_30: '19000',
        kFieldCreditLimit: '25000',
      });
      expect(a.total, 19000);
      expect(a.current, 19000);
      expect(a.creditLimit, 25000);
      expect(a.mismatch, isFalse);
    });

    test('treat rubbish as zero rather than NaN, which would poison every sum',
        () {
      final a = agingOf({kFieldOutstandingTotal: 'n/a', kFieldOutstanding0_30: null});
      expect(a.total, 0);
      expect(a.sum, 0);
      expect(a.total.isNaN, isFalse);
    });
  });

  group('the mismatch tolerance', () {
    bool at(double stored) => agingOf({
          kFieldOutstandingTotal: stored,
          kFieldOutstanding0_30: 1000,
        }).mismatch;

    test('forgives rounding and nothing more', () {
      expect(at(1000 + kAgingTolerance), isFalse);
      expect(at(1000 + kAgingTolerance + 0.01), isTrue);
      expect(at(1000 - kAgingTolerance - 0.01), isTrue);
    });

    test('is not raised on a customer nobody has synced', () {
      // No buckets is not a disagreement. It is silence.
      expect(agingOf({kFieldOutstandingTotal: 19000}).mismatch, isFalse);
    });
  });
}
