// SAP's view of an order, turned into something the screens act on.
//
// Read from the shared fixture the dashboard's suite reads too: a rep and a
// manager looking at the same order must be told the same thing about it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sap_order_state.dart';

List<Map<String, dynamic>> _cases(Map<String, dynamic> f, String key) =>
    (f[key] as List).cast<Map<String, dynamic>>();

void main() {
  final raw = File('../shared/fixtures/sap_order_state.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;

  group('an order', () {
    for (final c in _cases(fixture, 'order_status')) {
      test(c['why'] as String, () {
        expect(
          productionStatusFromSap(SapOrderState(
            salesOrder: c['sap_order'] as String,
            invoice: c['invoice'] as String,
          )),
          c['expect'],
        );
      });
    }
  });

  group('one line of an order', () {
    for (final c in _cases(fixture, 'line_status')) {
      test(c['why'] as String, () {
        expect(
          lineStatusFromSap(
            SapLineState(invoice: c['line_invoice'] as String),
            order: SapOrderState(salesOrder: c['order_sap'] as String),
          ),
          c['expect'],
        );
      });
    }

    test('without its order, an uninvoiced line cannot claim to be in SAP', () {
      expect(lineStatusFromSap(const SapLineState()), kSapNotStarted);
    });
  });

  group('what an order list shows', () {
    for (final c in _cases(fixture, 'order_progress')) {
      test(c['why'] as String, () {
        expect(
          orderProgress(
            SapOrderState(
              salesOrder: c['sap_order'] as String,
              invoice: c['invoice'] as String,
            ),
            c['stored'],
          ),
          c['expect'],
        );
      });
    }

    test('a missing stored status is Not Started, not the string null', () {
      expect(orderProgress(const SapOrderState(), null), kSapNotStarted);
    });
  });

  group('an order rolls up from its lines', () {
    for (final c in _cases(fixture, 'order_rolls_up_from_lines')) {
      test(c['why'] as String, () {
        final lines = (c['line_invoices'] as List)
            .cast<String>()
            .map((i) => SapLineState(invoice: i))
            .toList();
        expect(
          orderStatusFromLines(
            lines,
            SapOrderState(
              salesOrder: c['order_sap'] as String,
              invoice: c['order_invoice'] as String?,
            ),
          ),
          c['expect'],
        );
      });
    }
  });

  group('the one line a rep reads', () {
    for (final c in _cases(fixture, 'summary')) {
      test(c['why'] as String, () {
        final order = (c['order'] as Map).cast<String, dynamic>();
        expect(sapSummary(SapOrderState.fromOrder(order)), c['expect']);
      });
    }
  });

  group('reading it off a Sales Order document', () {
    test('every field maps', () {
      final s = SapOrderState.fromOrder({
        'custom_sap_sales_order': '412',
        'custom_sap_sales_order_status': 'bost_Open',
        'custom_sap_invoice': 'INV-900',
        'custom_sap_invoice_date': '2026-09-24',
        'custom_sap_synced_at': '2026-09-24 10:00:00',
        'custom_sap_sync_error': '',
      });
      expect(s.salesOrder, '412');
      expect(s.salesOrderStatus, 'bost_Open');
      expect(s.invoice, 'INV-900');
      expect(s.invoiceDate, '2026-09-24');
      expect(productionStatusFromSap(s), kSapDispatched);
    });

    test('an old production stage is not read at all', () {
      // Orders from before 24 Sep 2026 can still carry a stage. Nothing may
      // act on it: a stage says nothing about whether the order has gone.
      final s = SapOrderState.fromOrder({
        'custom_sap_sales_order': '412',
        'custom_sap_production_stage': 'Closed',
        'custom_sap_production_order': '4482',
      });
      expect(productionStatusFromSap(s), kSapPushed);
    });

    test('an old delivery is not dispatch', () {
      // The floor delivers before it invoices; only the invoice is dispatch.
      final s = SapOrderState.fromOrder({
        'custom_sap_sales_order': '412',
        'custom_sap_delivery_order': '4',
      });
      expect(productionStatusFromSap(s), kSapPushed);
    });

    test('reading line state off an items row', () {
      final l = SapLineState.fromLine({
        'custom_sap_invoice': 'INV-900',
        'custom_sap_invoice_date': '2026-09-24',
        'custom_sap_production_stage': 'Curing',
      });
      expect(l.hasSap, isTrue);
      expect(l.invoiceDate, '2026-09-24');
    });

    test('an items row with only a stale stage says nothing of its own', () {
      final l = SapLineState.fromLine({'custom_sap_production_stage': 'Curing'});
      expect(l.hasSap, isFalse);
    });
  });

  group('the mistakes this mapping exists to prevent', () {
    test("Frappe's string 'null' is not an invoice", () {
      expect(
          lineStatusFromSap(const SapLineState(invoice: 'null'),
              order: const SapOrderState(salesOrder: '412')),
          kSapPushed);
    });

    test('not yet in SAP is not the same as failed', () {
      // Both have no SAP number; only the sync error means something is wrong.
      const waiting = SapOrderState();
      const failed = SapOrderState(syncError: 'SAP refused the order');
      expect(productionStatusFromSap(waiting), kSapNotStarted);
      expect(productionStatusFromSap(failed), kSapNotStarted);
      expect(waiting.syncError, isNull);
      expect(failed.syncError, isNotEmpty);
    });
  });

  group('staleness', () {
    final now = DateTime.parse('2026-09-12T10:00:00');
    test('an order SAP never took is waiting, not stale', () {
      expect(sapStale(const SapOrderState(), now), isFalse);
    });
    test('in SAP but never reconciled is stale', () {
      expect(sapStale(const SapOrderState(salesOrder: 'SO-1'), now), isTrue);
    });
    test('reconciled this morning is not stale', () {
      expect(
          sapStale(
              const SapOrderState(
                  salesOrder: 'SO-1', syncedAt: '2026-09-12T08:00:00'),
              now),
          isFalse);
    });
  });

  group('An order SAP has cancelled', () {
    // The failure this closes, found 18 September 2026: SAP order 399 had been
    // cancelled and the sync had recorded bost_Cancelled on the ERPNext order
    // correctly, for days. Nothing read it, so it still showed as approved.
    for (final c in _cases(fixture, 'cancelled_orders')) {
      test(c['why'] as String, () {
        final order = (c['order'] as Map).cast<String, dynamic>();
        expect(cancelledInSap(SapOrderState.fromOrder(order)), c['expect_cancelled']);
      });
    }

    test('cancellation outranks the approval status', () {
      const s = SapOrderState(salesOrderStatus: 'bost_Cancelled');
      expect(orderApprovalLabel('PO Approved - Ready for SAP', s), 'Cancelled in SAP');
    });

    test('an open order keeps its approval label', () {
      const s = SapOrderState(salesOrderStatus: 'bost_Open');
      expect(orderApprovalLabel('PO Approved - Ready for SAP', s), 'Approved');
    });
  });
}
