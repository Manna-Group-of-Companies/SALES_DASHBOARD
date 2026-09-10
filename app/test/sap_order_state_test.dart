// SAP's view of an order, turned into something the screens act on.
//
// Read from the shared fixture the dashboard's suite reads too: a rep and a
// manager looking at the same order must be told the same thing about it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/sap_order_state.dart';

void main() {
  final raw = File('../shared/fixtures/sap_order_state.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;

  group('SAP stage to production status', () {
    for (final c in (fixture['stage_to_status'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        expect(
          productionStatusFromSap(SapOrderState(
            productionStage: c['sap_stage'] as String,
            salesOrder: c['sap_order'] as String,
            deliveryOrder: c['delivery'] as String,
          )),
          c['expect'],
        );
      });
    }
  });

  group('the mistakes this mapping exists to prevent', () {
    test('an unmapped stage is never Ready', () {
      // Ready tells a rep the order is made.
      for (final s in ['Zzz', 'Vulcanising', 'Trimming', 'Stage 7', '???']) {
        expect(
          productionStatusFromSap(
              SapOrderState(salesOrder: 'SO-1', productionStage: s)),
          'In Production',
          reason: s,
        );
      }
    });

    test('a delivery order outranks any stage', () {
      expect(
        productionStatusFromSap(SapOrderState(
            salesOrder: 'SO-1',
            productionStage: 'Curing',
            deliveryOrder: 'DN-9')),
        'Dispatched',
      );
    });

    test("Frappe's string 'null' is not a delivery order", () {
      expect(
        productionStatusFromSap(
            SapOrderState(salesOrder: 'SO-1', deliveryOrder: 'null')),
        'Not Started',
      );
    });

    test('not yet in SAP is not the same as failed', () {
      expect(reachedSap(const SapOrderState()), isFalse);
      expect(reachedSap(const SapOrderState(salesOrder: 'SO-1')), isTrue);
      expect(reachedSap(const SapOrderState(salesOrder: '   ')), isFalse);
    });
  });

  group('reading it off a Sales Order document', () {
    test('every field maps', () {
      final s = SapOrderState.fromOrder({
        'custom_sap_sales_order': 'SO-1001',
        'custom_sap_production_stage': 'Curing',
        'custom_sap_delivery_order': 'DN-500',
        'custom_sap_delivery_date': '2026-09-15',
      });
      expect(s.salesOrder, 'SO-1001');
      expect(s.productionStage, 'Curing');
      expect(productionStatusFromSap(s), 'Dispatched');
      expect(sapSummary(s), 'Delivery DN-500 · due 2026-09-15 · SAP SO-1001');
    });

    test('an order untouched by SAP says nothing', () {
      final s = SapOrderState.fromOrder({'name': 'SAL-ORD-1'});
      expect(reachedSap(s), isFalse);
      expect(sapSummary(s), isNull);
      expect(productionStatusFromSap(s), 'Not Started');
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
}
